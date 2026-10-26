# Shared Android build and signing functions, sourced by the scripts in this folder.
# This file, build-android-*.sh, release-github.sh, rotate-signing-key.sh and tests/test_release_workflow.py are the
# same in PassVault and AquaRestore; everything project-specific is in release-settings.sh (see docs/RELEASING.md).
#
# Optional environment (<P> is env_prefix from release-settings.sh, e.g. PASSVAULT):
#   <P>_KEYSTORE            keystore path         (default: default_keystore)
#   <P>_KEY_ALIAS           key alias             (default: default_key_alias)
#   <P>_KEYSTORE_PASSWORD   keystore password; prompted if unset
#   <P>_KEY_PASSWORD        key password; defaults to the keystore password (PKCS12 keystores share one)
#   <P>_LINEAGE             key-rotation lineage  (default: default_lineage)
#   JAVA_HOME, ANDROID_HOME JDK 17 and Android SDK; detected from the usual locations if unset
#   GRADLE_EXTRA_ARGS       extra Gradle flags, whitespace-separated (e.g. --offline)
# One key signs both the GitHub APK and the Google Play bundle; Play App Signing holds the same key.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
android_root="$root/android"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

. "$root/scripts/release-settings.sh"

# The value of the environment variable <env_prefix>_$1, or $2 when it is unset or empty.
setting() { local name="${env_prefix}_$1"; printf '%s' "${!name:-${2:-}}"; }
keystore="$(setting KEYSTORE "$default_keystore")"
alias_name="$(setting KEY_ALIAS "$default_key_alias")"
lineage="$(setting LINEAGE "$default_lineage")"
# Names, not values: keytool, apksigner and Gradle read the passwords from these environment variables.
keystore_password_var="${env_prefix}_KEYSTORE_PASSWORD"
key_password_var="${env_prefix}_KEY_PASSWORD"

find_toolchain() {
  if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then
    JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  fi
  if [ -z "${JAVA_HOME:-}" ]; then
    for candidate in '/Applications/Android Studio.app/Contents/jbr/Contents/Home' /opt/android-studio/jbr /usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-arm64; do
      if [ -x "$candidate/bin/java" ]; then JAVA_HOME="$candidate"; break; fi
    done
  fi
  [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && [ -x "$JAVA_HOME/bin/keytool" ] \
    || die 'JDK 17+ not found. Set JAVA_HOME or run scripts/setup-release-env.sh on macOS.'
  if [ -z "${ANDROID_HOME:-}" ]; then
    ANDROID_HOME="${ANDROID_SDK_ROOT:-}"
    if [ -z "$ANDROID_HOME" ]; then
      for candidate in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
        if [ -d "$candidate" ]; then ANDROID_HOME="$candidate"; break; fi
      done
    fi
  fi
  [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME" ] \
    || die 'Android SDK not found. Set ANDROID_HOME or run scripts/setup-release-env.sh.'
  export JAVA_HOME ANDROID_HOME
  gradle_args=(--console=plain -Pkotlin.compiler.execution.strategy=in-process)
  if [ -n "${GRADLE_EXTRA_ARGS:-}" ]; then
    # Whitespace-delimited flags only, no eval or shell expansion.
    read -r -a extra_gradle_args <<< "$GRADLE_EXTRA_ARGS"
    gradle_args+=(${extra_gradle_args[@]+"${extra_gradle_args[@]}"})
  fi
}

find_signing_tools() {
  local best_major=-1 best_minor=-1 best_patch=-1 candidate version major minor patch
  apksigner=''; aapt=''
  for candidate in "$ANDROID_HOME"/build-tools/*/apksigner; do
    [ -x "$candidate" ] || continue
    version="$(basename "$(dirname "$candidate")")"
    # Stable releases only: a preview such as 36.0.0-rc1 must not win over 36.0.0.
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
    if (( major > best_major || (major == best_major && minor > best_minor) || (major == best_major && minor == best_minor && patch > best_patch) )); then
      best_major="$major"; best_minor="$minor"; best_patch="$patch"
      apksigner="$candidate"; aapt="$(dirname "$candidate")/aapt"
    fi
  done
  [ -n "$apksigner" ] && [ -x "$aapt" ] || die 'Install stable Android SDK Build-Tools (35.0.0 or newer).'
}

read_version() {
  version="$(sed -n 's/^[[:space:]]*versionName = "\([^"]*\)"[[:space:]]*$/\1/p' "$android_root/app/build.gradle.kts")"
  code="$(sed -n 's/^[[:space:]]*versionCode = \([0-9]*\)[[:space:]]*$/\1/p' "$android_root/app/build.gradle.kts")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die 'Cannot read a valid versionName from android/app/build.gradle.kts.'
  [[ "$code" =~ ^[1-9][0-9]*$ ]] || die 'Cannot read versionCode from android/app/build.gradle.kts.'
}

read_min_sdk() {
  min_sdk="$(sed -n 's/^[[:space:]]*minSdk = \([0-9]*\)[[:space:]]*$/\1/p' "$android_root/app/build.gradle.kts")"
  [[ "$min_sdk" =~ ^[1-9][0-9]*$ ]] || die 'Cannot read minSdk from android/app/build.gradle.kts.'
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"
  else die 'Install shasum or sha256sum.'; fi
}

# Debug/test processes never receive signing material, even if the caller exported it.
run_unsigned_gradle() (
  unset "$keystore_password_var" "$key_password_var" "${env_prefix}_KEYSTORE_FILE" "${env_prefix}_KEY_ALIAS"
  cd "$android_root"
  ./gradlew "${gradle_args[@]}" "$@"
)

# Signed builds: a single-use Gradle process and in-process Kotlin compilation, so no daemon keeps the password.
run_signed_gradle() (
  export "${env_prefix}_KEYSTORE_FILE=$keystore" "${env_prefix}_KEY_ALIAS=$alias_name"
  cd "$android_root"
  ./gradlew "${gradle_args[@]}" --no-daemon "$@"
)

forget_passwords() { unset "$keystore_password_var" "$key_password_var"; }

# Creates the keystore on first use (after asking), then makes sure the alias opens with the password.
ensure_keystore() {
  if [ ! -f "$keystore" ]; then
    [ -t 0 ] || die "No signing keystore at $keystore. Run this in a terminal to create one, or set ${env_prefix}_KEYSTORE."
    printf 'No signing keystore at %s.\n' "$keystore"
    printf 'If you already have a %s signing key (for example on another computer), answer no and set %s_KEYSTORE.\n' "$app_name" "$env_prefix"
    read -r -p "Create a new $app_name signing key now? [y/N] " yn
    [ "$yn" = y ] || [ "$yn" = Y ] || die "Aborted. Set ${env_prefix}_KEYSTORE to an existing keystore."
    # Only a directory created here is made private; an existing one (e.g. $HOME) keeps its permissions.
    [ -d "$(dirname "$keystore")" ] || (umask 077; mkdir -p "$(dirname "$keystore")")
    printf 'keytool will ask for a password (choose a long one) and your name/organisation details.\n'
    # umask 077: the keystore is never readable by other users, not even before the chmod.
    (umask 077; "$JAVA_HOME/bin/keytool" -genkeypair -v -storetype PKCS12 -keystore "$keystore" \
      -alias "$alias_name" -keyalg RSA -keysize 4096 -validity 10000) || die 'Key generation failed; nothing was created.'
    chmod 600 "$keystore"
    cat <<MSG

Keystore created: $keystore (alias: $alias_name)
BACK IT UP NOW (with its password) in at least two places, one offline. Every update to an installed
$app_name, from GitHub or Google Play, must be signed with this key; without it, installs cannot update.
MSG
  fi
  keystore="$(cd "$(dirname "$keystore")" && pwd)/$(basename "$keystore")"
  if [ -z "${!keystore_password_var:-}" ]; then
    [ -t 0 ] || die "Set $keystore_password_var when running without a terminal."
    read -r -s -p 'Keystore password: ' "$keystore_password_var"; printf '\n'
  fi
  [ -n "${!keystore_password_var:-}" ] || die 'Keystore password cannot be empty.'
  if [ -z "${!key_password_var:-}" ]; then
    if [ -t 0 ]; then
      read -r -s -p 'Key password [Enter = keystore password]: ' "$key_password_var"; printf '\n'
    fi
    [ -n "${!key_password_var:-}" ] || printf -v "$key_password_var" '%s' "${!keystore_password_var}"
  fi
  export "$keystore_password_var" "$key_password_var"
  "$JAVA_HOME/bin/keytool" -list -keystore "$keystore" -alias "$alias_name" \
    -storepass:env "$keystore_password_var" >/dev/null 2>&1 \
    || die "Cannot open alias '$alias_name' in $keystore. Check the alias and keystore password."
}

# SHA-256 of the key's certificate, lowercase hex without colons (as apksigner prints it).
key_cert_sha256() {
  local cert_file
  cert_file="$(mktemp "${TMPDIR:-/tmp}/signing-cert.XXXXXX")"
  if ! "$JAVA_HOME/bin/keytool" -exportcert -keystore "$keystore" -alias "$alias_name" \
      -storepass:env "$keystore_password_var" -file "$cert_file" >/dev/null 2>&1; then
    rm -f "$cert_file"; die 'Cannot read the public signing certificate.'
  fi
  sha256 "$cert_file" | awk '{print $1}'
  rm -f "$cert_file"
}

# Checks the signature, signer, package, version and that the APK is not debuggable.
verify_release_apk() {
  local artifact="$1" expected_cert actual_cert metadata
  "$apksigner" verify --verbose --print-certs --min-sdk-version "$min_sdk" "$artifact"
  actual_cert="$("$apksigner" verify --print-certs --min-sdk-version "$min_sdk" "$artifact" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
  expected_cert="$(key_cert_sha256)"
  [ -n "$actual_cert" ] && [ "$actual_cert" = "$expected_cert" ] || die "The APK is not signed with '$alias_name' from $keystore."
  metadata="$("$aapt" dump badging "$artifact")"
  case "$metadata" in
    "package: name='$app_id' versionCode='$code' versionName='$version'"*) ;;
    *) die 'APK package/version does not match this source tree.' ;;
  esac
  case "$metadata" in *application-debuggable*) die 'Refusing to publish a debuggable APK.' ;; esac
}
