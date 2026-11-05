#!/usr/bin/env bash
# Build and verify the signed release APK (the GitHub sideload build) locally. Does not publish.
# Creates the signing key on first run (after asking). If scripts/rotate-signing-key.sh created a key-rotation
# lineage, it is attached so installs signed with the old key update in place.
# Usage: scripts/build-android-release.sh [--skip-tests]
# Signing configuration (keystore, alias, passwords, lineage): see _signing-common.sh.
set +x
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/_signing-common.sh"
run_tests=1
for arg in "$@"; do
  case "$arg" in
    --skip-tests) run_tests=0 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done
check_sources --release
find_toolchain
find_signing_tools
read_version
read_min_sdk
# Open (or create) the key before the expensive build, so a wrong password fails fast.
ensure_keystore
trap forget_passwords EXIT
# A lineage backup without a lineage means a rotation was lost: shipping without it would break in-place updates.
if [ ! -f "$lineage" ] && ls "$lineage".bak-* >/dev/null 2>&1; then
  die "Found $lineage.bak-* but no $lineage. Restore it or re-run scripts/rotate-signing-key.sh."
fi
tasks=(clean)
[ "$run_tests" = 0 ] || tasks+=(:app:testDebugUnitTest :app:lintRelease)
run_unsigned_gradle --no-daemon "${tasks[@]}" :app:assembleRelease
unsigned_apk="$android_root/app/build/outputs/apk/release/app-release-unsigned.apk"
[ -f "$unsigned_apk" ] || die 'The release APK was not produced.'
source_apk="$android_root/app/build/outputs/apk/release/app-release.apk"
if [ -f "$lineage" ]; then
  # APK Signature Scheme v3 only with a lineage; every supported Android version verifies it.
  sign_apk "$unsigned_apk" "$source_apk" --lineage "$lineage" --rotation-min-sdk-version "$min_sdk" \
    --v2-signing-enabled false --v3-signing-enabled true \
    || die "Signing with the lineage failed. Does $lineage end with the key in $keystore? (Re-run scripts/rotate-signing-key.sh --force.)"
  printf 'Key-rotation lineage attached: %s\n' "$lineage"
else
  sign_apk "$unsigned_apk" "$source_apk" --v2-signing-enabled true --v3-signing-enabled false || die 'Signing the APK failed.'
fi
verify_release_apk "$source_apk"
mkdir -p "$root/dist"
apk="$root/dist/$app_name-$version-$code.apk"
cp "$source_apk" "$apk"
(cd "$root/dist" && sha256 "$(basename "$apk")" > "$app_name-$version-$code.SHA256SUMS")
printf '\nSigned APK: %s%s\nChecksums: %s\n' "$apk" "$([ -f "$lineage" ] && printf ' (with key-rotation lineage)')" \
  "$root/dist/$app_name-$version-$code.SHA256SUMS"
