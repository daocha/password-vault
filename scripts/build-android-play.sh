#!/usr/bin/env bash
# Build and verify the Google Play bundle (playRelease) locally. Does not upload.
# It is signed with the same key as the GitHub APK. Register that key in Play App Signing before the first upload,
# so what Play installs and what GitHub installs update each other (docs/RELEASING.md).
# Usage: scripts/build-android-play.sh [--skip-tests]
# Signing configuration (keystore, alias, passwords): see _signing-common.sh.
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
ensure_keystore
trap forget_passwords EXIT
tasks=(clean)
[ "$run_tests" = 0 ] || tasks+=(:app:testDebugUnitTest :app:lintPlayRelease)
run_unsigned_gradle --no-daemon "${tasks[@]}"
# The APK of the same variant is built only to check the merged manifest; the bundle is what goes to Play.
run_signed_gradle :app:bundlePlayRelease :app:assemblePlayRelease
source_aab="$android_root/app/build/outputs/bundle/playRelease/app-playRelease.aab"
check_apk="$android_root/app/build/outputs/apk/playRelease/app-playRelease.apk"
source_mapping="$android_root/app/build/outputs/mapping/playRelease/mapping.txt"
[ -f "$source_aab" ] && [ -f "$check_apk" ] || die 'The playRelease bundle was not produced.'
[ -f "$source_mapping" ] || die 'The playRelease R8 mapping file was not produced.'
verify_release_apk "$check_apk"
permissions="$("$aapt" dump permissions "$check_apk")"
for permission in ${play_forbidden_permissions[@]+"${play_forbidden_permissions[@]}"}; do
  case "$permissions" in *"name='$permission'"*) die "The Play build requests $permission." ;; esac
done
# jarsigner -verify exits 0 even for an unsigned file, so check its verdict, then that the signer is our key.
case "$("$JAVA_HOME/bin/jarsigner" -verify "$source_aab" 2>&1 || true)" in
  *"jar verified."*) ;;
  *) die 'The bundle signature does not verify.' ;;
esac
expected_cert="$(key_cert_sha256)"
actual_cert="$("$JAVA_HOME/bin/keytool" -printcert -jarfile "$source_aab" | sed -n 's/^[[:space:]]*SHA256: //p' | head -n1 | tr -d ':' | tr 'A-F' 'a-f')"
[ -n "$actual_cert" ] && [ "$actual_cert" = "$expected_cert" ] || die "The bundle is not signed with '$alias_name' from $keystore."
mkdir -p "$root/dist"
aab="$root/dist/$app_name-$version-$code-play.aab"
mapping="$root/dist/$app_name-$version-$code-play-mapping.txt"
cp "$source_aab" "$aab"
cp "$source_mapping" "$mapping"
# Play Console shows certificate fingerprints in this form (Test and release > App integrity).
fingerprint="$(printf '%s' "$expected_cert" | tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//')"
printf '\nPlay bundle: %s\nR8 mapping:  %s (upload it with the bundle)\nSigning key: %s, SHA-256 %s\n' "$aab" "$mapping" "$alias_name" "$fingerprint"
printf 'Play App Signing must show this same SHA-256 as its app signing key.\n'
