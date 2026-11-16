#!/usr/bin/env bash
# Run the full connected Android test suite on one test device, without signing or publishing.
# The tests uninstall the app they test afterwards, deleting its data: use an emulator or a dedicated test phone.
# Device choice, in order:
#   ANDROID_AVD=<name>   use that emulator, starting it headless when it is not running (and stopping it afterwards).
#                        ANDROID_AVD_HOME selects the AVD folder, ANDROID_EMULATOR_PORT its port (default: the first
#                        free one from 5554) and ANDROID_EMULATOR_OPTIONS adds emulator flags.
#   ANDROID_SERIAL=<id>  use that connected device; naming a phone here confirms it may be used.
#   otherwise            the only connected device. A phone is used only after confirmation in a terminal.
# Optional, from release-settings.sh:
#   device_test_task      the Gradle task to run (default: :app:connectedDebugAndroidTest)
#   device_test_app       what the tests remove, for the messages (default: the debug app and its projects)
#   prepare_test_device   a function run with the adb path and serial before the tests (e.g. to set a screen lock)
#   restore_test_device   a function run with the same arguments afterwards, also after a failure
# Installs no tools.
set +x
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/_signing-common.sh"
check_sources --release
find_toolchain
adb="$ANDROID_HOME/platform-tools/adb"
[ -x "$adb" ] || die "adb not found at $adb. Install the SDK platform-tools."

online_devices() { "$adb" devices | awk 'NR > 1 && $2 == "device" { print $1 }'; }
prop() { "$adb" -s "$1" shell getprop "$2" 2>/dev/null | tr -d '\r' || true; }
is_emulator() { [ "$(prop "$1" ro.boot.qemu)" = 1 ] || [ "$(prop "$1" ro.kernel.qemu)" = 1 ]; }

test_task="${device_test_task:-:app:connectedDebugAndroidTest}"
test_app="${device_test_app:-the debug app and its projects}"

started_serial=''; emulator_pid=''; emulator_log=''; prepared_serial=''
stop_emulator() {
  [ -n "$started_serial" ] || return 0
  printf 'Stopping emulator %s.\n' "$started_serial"
  "$adb" -s "$started_serial" emu kill >/dev/null 2>&1 || true
  [ -z "$emulator_pid" ] || wait "$emulator_pid" 2>/dev/null || true
  started_serial=''
}
finish() {
  if [ -n "$prepared_serial" ] && declare -F restore_test_device >/dev/null; then
    restore_test_device "$adb" "$prepared_serial" || printf 'warning: could not restore %s after the tests.\n' "$prepared_serial" >&2
  fi
  stop_emulator
}
trap finish EXIT

running_avd() {
  local serial
  for serial in $(online_devices); do
    case "$serial" in emulator-*) ;; *) continue ;; esac
    if [ "$("$adb" -s "$serial" emu avd name 2>/dev/null | head -n 1 | tr -d '\r')" = "$ANDROID_AVD" ]; then
      printf '%s\n' "$serial"; return 0
    fi
  done
}

start_emulator() {
  local emulator="$ANDROID_HOME/emulator/emulator" port='' candidate waited=0 limit="${ANDROID_BOOT_TIMEOUT:-300}"
  [ -x "$emulator" ] || die "Emulator not found at $emulator. Install the SDK emulator package and a system image."
  local busy
  busy="$("$adb" devices | awk 'NR > 1 { print $1 }')"
  if [ -n "${ANDROID_EMULATOR_PORT:-}" ]; then
    [[ "$ANDROID_EMULATOR_PORT" =~ ^[0-9]+$ ]] || die 'ANDROID_EMULATOR_PORT must be a port number.'
    ! printf '%s\n' "$busy" | grep -qx "emulator-$ANDROID_EMULATOR_PORT" \
      || die "Port $ANDROID_EMULATOR_PORT is used by another emulator."
    port="$ANDROID_EMULATOR_PORT"
  else
    for candidate in $(seq 5554 2 5584); do
      if ! printf '%s\n' "$busy" | grep -qx "emulator-$candidate"; then port="$candidate"; break; fi
    done
    [ -n "$port" ] || die 'No free emulator port between 5554 and 5584.'
  fi
  emulator_log="$(mktemp "${TMPDIR:-/tmp}/android-test-emulator.XXXXXX")"
  local options=()
  # Whitespace-delimited flags only, no eval or shell expansion.
  [ -z "${ANDROID_EMULATOR_OPTIONS:-}" ] || read -r -a options <<< "$ANDROID_EMULATOR_OPTIONS"
  printf 'Starting emulator %s on port %s (log: %s).\n' "$ANDROID_AVD" "$port" "$emulator_log"
  "$emulator" -avd "$ANDROID_AVD" -port "$port" -no-window -no-audio -no-boot-anim -no-snapshot-save \
    ${options[@]+"${options[@]}"} > "$emulator_log" 2>&1 &
  emulator_pid=$!
  started_serial="emulator-$port"
  until [ "$(prop "$started_serial" sys.boot_completed)" = 1 ] && "$adb" -s "$started_serial" shell pm path android >/dev/null 2>&1; do
    kill -0 "$emulator_pid" 2>/dev/null || die "The emulator exited before booting. See $emulator_log."
    [ "$waited" -lt "$limit" ] || die "The emulator did not boot within $limit seconds. See $emulator_log."
    sleep 2; waited=$((waited + 2))
  done
}

if [ -n "${ANDROID_AVD:-}" ]; then
  serial="$(running_avd)"
  if [ -z "$serial" ]; then start_emulator; serial="$started_serial"; fi
elif [ -n "${ANDROID_SERIAL:-}" ]; then
  online_devices | grep -qxF "$ANDROID_SERIAL" || die "ANDROID_SERIAL=$ANDROID_SERIAL is not connected."
  serial="$ANDROID_SERIAL"
else
  devices="$(online_devices)"
  count="$(printf '%s' "$devices" | grep -c . || true)"
  case "$count" in
    0) die 'No test device. Start an emulator, set ANDROID_AVD=<name> to start one, or connect a dedicated test phone.' ;;
    1) serial="$devices" ;;
    *) die "Several devices are connected ($(printf '%s' "$devices" | tr '\n' ' ')). Set ANDROID_SERIAL or ANDROID_AVD to choose the test device." ;;
  esac
  if ! is_emulator "$serial"; then
    model="$(prop "$serial" ro.product.model)"
    [ -t 0 ] || die "Only a phone ($model, $serial) is connected. Set ANDROID_SERIAL=$serial to test on it, or use an emulator."
    printf 'The tests will remove %s from the phone %s (%s).\n' "$test_app" "$model" "$serial"
    read -r -p 'Use this phone for the tests? [y/N] ' yn
    [ "$yn" = y ] || [ "$yn" = Y ] || die 'Aborted. Start an emulator or set ANDROID_AVD instead.'
  fi
fi
# The Android Gradle plugin runs connected tests only on ANDROID_SERIAL when it is set.
export ANDROID_SERIAL="$serial"
if declare -F prepare_test_device >/dev/null; then
  # Set first, so that a preparation that stops halfway is still undone.
  prepared_serial="$serial"
  prepare_test_device "$adb" "$serial"
fi
printf 'Running Android device tests on %s. They remove %s afterwards.\n' "$serial" "$test_app"
run_unsigned_gradle --no-daemon "$test_task"
