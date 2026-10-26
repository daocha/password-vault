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
# Tests run in a separate Gradle process that never receives the signing secrets.
tasks=(clean)
[ "$run_tests" = 0 ] || tasks+=(:app:testDebugUnitTest :app:lintRelease)
run_unsigned_gradle --no-daemon "${tasks[@]}"
run_signed_gradle :app:assembleRelease
source_apk="$android_root/app/build/outputs/apk/release/app-release.apk"
[ -f "$source_apk" ] || die 'Signed release APK was not produced.'
if [ -f "$lineage" ]; then
  # Re-sign with the lineage (APK Signature Scheme v3 only; every supported Android version verifies it).
  rotated="$android_root/app/build/outputs/apk/release/app-release-rotated.apk"
  "$apksigner" sign --ks "$keystore" --ks-key-alias "$alias_name" \
    --ks-pass "env:$keystore_password_var" --key-pass "env:$key_password_var" --lineage "$lineage" \
    --min-sdk-version "$min_sdk" --rotation-min-sdk-version "$min_sdk" \
    --v1-signing-enabled false --v2-signing-enabled false --v3-signing-enabled true \
    --out "$rotated" "$source_apk" \
    || die "Signing with the lineage failed. Does $lineage end with the key in $keystore? (Re-run scripts/rotate-signing-key.sh --force.)"
  rm -f "$rotated.idsig"
  source_apk="$rotated"
  printf 'Key-rotation lineage attached: %s\n' "$lineage"
fi
verify_release_apk "$source_apk"
mkdir -p "$root/dist"
apk="$root/dist/$app_name-$version-$code.apk"
cp "$source_apk" "$apk"
(cd "$root/dist" && sha256 "$(basename "$apk")" > "$app_name-$version-$code.SHA256SUMS")
printf '\nSigned APK: %s%s\nChecksums: %s\n' "$apk" "$([ -f "$lineage" ] && printf ' (with key-rotation lineage)')" \
  "$root/dist/$app_name-$version-$code.SHA256SUMS"
