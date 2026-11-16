#!/usr/bin/env bash
# Run every Android release check without signing: unit tests, release lint (with --play also the Play variant's),
# then the connected device suite (test-android-device.sh; see it for choosing the device).
# Usage: scripts/test-android-release.sh [--play]
# Installs no tools.
set +x
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/_signing-common.sh"
play=0
for arg in "$@"; do
  case "$arg" in
    --play) play=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done
check_sources --release
find_toolchain
tasks=(:app:testDebugUnitTest :app:lintRelease)
[ "$play" = 0 ] || tasks+=(:app:lintPlayRelease)
printf 'Running Android unit tests and release lint.\n'
run_unsigned_gradle --no-daemon "${tasks[@]}"
"$here/test-android-device.sh"
