#!/usr/bin/env bash
# Serves android/dist/dev-update (written by every debug build when .env sets PASSVAULT_DEV_UPDATE_HOST) to debug
# builds on the LAN. Binds to that address only, so nothing listens on other interfaces.
#
#   scripts/serve-dev-update.sh               start in the background, or do nothing if it is already running.
#                                             Run it after any build; a running server picks up the new build by itself.
#   scripts/serve-dev-update.sh --status      say whether it is running
#   scripts/serve-dev-update.sh --stop        stop it
#   scripts/serve-dev-update.sh --foreground  run in this terminal until Ctrl-C
#   scripts/serve-dev-update.sh --migrate     also answer builds from before the update secret, once. Run the plain
#                                             command again after the phone has updated: that also stops any server
#                                             from before the secret, which has no secret path, on any port.
#
# The files are served only under a secret path, which the build also puts in the app. It is made once and kept next
# to the debug key, in ~/.android/passvault-dev-update-secret, so it stays the same across builds and new clones.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
die() { printf 'serve-dev-update: %s\n' "$*" >&2; exit 1; }
setting() {
  local value="${!1:-}"
  [ -n "$value" ] || [ ! -f "$root/.env" ] || value="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1[[:space:]]*=[[:space:]]*//p" "$root/.env" | tail -n 1 | tr -d "\"'")"
  printf '%s' "$value"
}
action=start; foreground=0; migrate=0
for arg in "$@"; do
  case "$arg" in
    --status) action=status ;;
    --stop) action=stop ;;
    --foreground) foreground=1 ;;
    --migrate) migrate=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done
host="$(setting PASSVAULT_DEV_UPDATE_HOST)"
port="$(setting PASSVAULT_DEV_UPDATE_PORT)"; port="${port:-8766}"
[ -n "$host" ] || die 'set PASSVAULT_DEV_UPDATE_HOST in .env (see .env.example).'
[[ "$port" =~ ^[0-9]+$ ]] || die 'PASSVAULT_DEV_UPDATE_PORT must be a port number.'
dir="$root/android/dist/dev-update"
server="$root/scripts/dev-update-server.py"
pid_file="$root/android/dist/dev-update-server.pid"
log_file="$root/android/dist/dev-update-server.log"
secret_file="${PASSVAULT_DEV_UPDATE_SECRET_FILE:-$HOME/.android/passvault-dev-update-secret}"

command_of() { ps -o command= -p "$1" 2>/dev/null || true; }

# The PID of this repository's server. Checks the command, because a stale PID may now belong to something else.
running_pid() {
  local pid
  [ -f "$pid_file" ] || return 1
  pid="$(cat "$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  case "$(command_of "$pid")" in
    *"$server"*"--directory $dir"*) printf '%s' "$pid" ;;
    *) return 1 ;;
  esac
}

# Servers from before the secret: plain http.server processes for this folder, on any port.
old_servers() {
  local pid
  for pid in $(pgrep -f http.server 2>/dev/null || true); do
    case "$(command_of "$pid")" in *http.server*"--directory $dir "*) printf '%s\n' "$pid" ;; esac
  done
}

stop_old_servers() {
  local pid
  for pid in $(old_servers); do
    stop_pid "$pid"
    printf 'Stopped an old server that had no secret path.\n'
  done
}

port_owner() { { lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true; } | head -n 1; }

stop_pid() {
  local pid="$1" i
  kill "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    # A process that has exited but not been collected by its parent still answers kill -0.
    case "$(ps -o stat= -p "$pid" 2>/dev/null || true)" in ''|Z*) return 0 ;; esac
    sleep 0.5
  done
  die "process $pid did not stop."
}

case "$action" in
  status)
    if pid="$(running_pid)"; then
      printf 'Running on port %s (process %s)%s\n' "$port" "$pid" \
        "$(case "$(command_of "$pid")" in *--migrate*) printf ', also answering builds from before the secret' ;; esac)"
      [ -z "$(old_servers)" ] || printf 'An old server with no secret path is also running. The plain command stops it.\n'
      exit 0
    fi
    printf 'Not running.\n'
    [ -z "$(old_servers)" ] || printf 'An old server with no secret path is running. The plain command stops it.\n'
    exit 3 ;;
  stop)
    if pid="$(running_pid)"; then stop_pid "$pid"; rm -f "$pid_file"; printf 'Stopped.\n'
    else printf 'Not running.\n'; fi
    stop_old_servers
    exit 0 ;;
esac

# --migrate leaves them, because the installed build may be asking one of them for its last update.
[ "$migrate" = 1 ] || stop_old_servers

if pid="$(running_pid)"; then
  has_migrate=0
  case "$(command_of "$pid")" in *--migrate*) has_migrate=1 ;; esac
  if [ "$foreground" = 0 ] && [ "$has_migrate" = "$migrate" ]; then
    printf 'Already running on port %s; it serves new builds by itself.\n' "$port"
    exit 0
  fi
  stop_pid "$pid"
  rm -f "$pid_file"
fi

[ -f "$dir/latest.json" ] || die "no $dir/latest.json yet: build the debug APK first."
[ -f "$secret_file" ] || die "no $secret_file yet: build the debug APK first."

owner="$(port_owner)"
if [ -n "$owner" ]; then
  case "$(command_of "$owner")" in
    # The plain http.server this script used to start for this folder. Replacing it changes nothing else.
    *http.server*"--directory $dir"*) stop_pid "$owner" ;;
    *) die "port $port is in use by another program (process $owner). Stop it, or set PASSVAULT_DEV_UPDATE_PORT." ;;
  esac
fi

arguments=(--host "$host" --port "$port" --directory "$dir" --secret-file "$secret_file")
[ "$migrate" = 0 ] || arguments+=(--migrate)
if [ "$foreground" = 1 ]; then
  printf 'Serving on port %s (Ctrl-C to stop)\n' "$port"
  exec python3 "$server" "${arguments[@]}"
fi

nohup python3 "$server" "${arguments[@]}" >"$log_file" 2>&1 &
pid=$!
disown "$pid" 2>/dev/null || true
printf '%s\n' "$pid" > "$pid_file"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "$pid" 2>/dev/null || { rm -f "$pid_file"; die "the server stopped at once: $(tail -n 1 "$log_file")"; }
  if [ "$(port_owner)" = "$pid" ]; then
    # Read through the real route, so "started" means a phone would get an answer.
    if printf 'url = "http://%s:%s/%s/latest.json"\n' "$host" "$port" "$(cat "$secret_file")" \
        | curl -fsS -m 3 -o /dev/null --config - 2>/dev/null; then
      printf 'Serving on port %s in the background%s. Stop it with: scripts/serve-dev-update.sh --stop\n' "$port" \
        "$([ "$migrate" = 0 ] || printf ', also answering builds from before the secret')"
      exit 0
    fi
  fi
  sleep 0.25
done
stop_pid "$pid"
rm -f "$pid_file"
die "the server did not answer. See $log_file."
