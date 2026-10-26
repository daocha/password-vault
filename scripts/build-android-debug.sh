#!/usr/bin/env bash
# Build the debug APK; unit tests and Android lint run by default. No signing key is needed (Android debug key).
# Usage: scripts/build-android-debug.sh [--skip-tests] [--install]
# JAVA_HOME / ANDROID_HOME are auto-detected where possible.
# GRADLE_EXTRA_ARGS='--offline' is optional. ANDROID_SERIAL selects an adb device.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/_signing-common.sh"
run_tests=1; install=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) run_tests=0 ;;
    --install) install=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done
check_sources
find_toolchain
tasks=(:app:assembleDebug :app:lintDebug)
[ "$run_tests" = 0 ] || tasks+=(:app:testDebugUnitTest)
run_unsigned_gradle "${tasks[@]}"
apk="$android_root/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$apk" ] || die 'Gradle finished without creating the debug APK.'
mkdir -p "$root/dist"
cp "$apk" "$root/dist/$app_name-debug.apk"
if [ "$install" = 1 ]; then
  adb="$ANDROID_HOME/platform-tools/adb"
  [ -x "$adb" ] || die 'Install Android SDK platform-tools to use --install.'
  "$adb" install -r "$apk"
fi
printf '\nDebug APK: %s\n' "$root/dist/$app_name-debug.apk"
