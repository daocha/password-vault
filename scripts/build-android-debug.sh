#!/usr/bin/env bash
# Builds the debug APK for sideloading or testing. No signing key is needed: Gradle signs it with the Android debug key.
#
#   scripts/build-android-debug.sh                 run unit tests, then build
#   scripts/build-android-debug.sh --skip-tests    skip unit tests
#   scripts/build-android-debug.sh --install       also install on the connected device or emulator (adb)
#
# Toolchain (JAVA_HOME, ANDROID_HOME) is detected as in _signing-common.sh. GRADLE_EXTRA_ARGS (e.g. --offline) is optional.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"; . "$here/_signing-common.sh"
run_tests=1; install=0
for arg in "$@"; do case "$arg" in --skip-tests) run_tests=0 ;; --install) install=1 ;; -h|--help) sed -n '2,8p' "$0"; exit 0 ;; *) echo "Unknown option: $arg" >&2; exit 2 ;; esac; done

find_toolchain
cd "$root/android"
gradle_args=(-Pkotlin.compiler.execution.strategy=in-process ${GRADLE_EXTRA_ARGS:-})
tasks=(:app:assembleDebug); [ "$run_tests" = 1 ] && tasks+=(:app:testDebugUnitTest)
./gradlew "${gradle_args[@]}" "${tasks[@]}"

apk="$root/android/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$apk" ] || die "Build finished but $apk was not found."
if [ "$install" = 1 ]; then
  adb="$ANDROID_HOME/platform-tools/adb"; [ -x "$adb" ] || adb="$(command -v adb || true)"
  [ -n "$adb" ] || die "adb not found. Install platform-tools or add adb to PATH."
  "$adb" install -r "$apk"
fi
echo
echo "Debug APK: $apk"
