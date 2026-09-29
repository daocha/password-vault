#!/usr/bin/env bash
# Builds a signed PassVault release locally: an AAB for Google Play and an APK for sideloading.
# The signing key never leaves your machine and its password is never written to disk or passed on a command line.
# If scripts/rotate-signing-key.sh has created a key-rotation lineage, it is attached to the APK automatically so
# phones running a build signed by the old key update in place. The AAB is unaffected (Google re-signs it).
#
#   scripts/build-android-release.sh                 build (creates the upload keystore on first run)
#   scripts/build-android-release.sh --skip-tests    skip unit tests
#
# Signing configuration (keystore, alias, password, lineage, JAVA_HOME/ANDROID_HOME): see _signing-common.sh.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"; . "$here/_signing-common.sh"
run_tests=1
for arg in "$@"; do case "$arg" in --skip-tests) run_tests=0 ;; -h|--help) sed -n '2,10p' "$0"; exit 0 ;; *) echo "Unknown option: $arg" >&2; exit 2 ;; esac; done

find_toolchain
ensure_keystore

# --- Build ---------------------------------------------------------------------------------------
# Passed to Gradle through the environment only; --no-daemon so no long-lived process keeps it.
export QV_KEYSTORE_FILE="$keystore" QV_KEYSTORE_PASSWORD="$PASSVAULT_KEYSTORE_PASSWORD" QV_KEY_PASSWORD="$PASSVAULT_KEYSTORE_PASSWORD" QV_KEY_ALIAS="$alias_name"
cd "$root/android"
tasks=(:app:assembleRelease :app:bundleRelease)
[ "$run_tests" = 1 ] && tasks=(:app:testDebugUnitTest "${tasks[@]}")
# GRADLE_EXTRA_ARGS (e.g. --offline) is optional.
./gradlew --no-daemon ${GRADLE_EXTRA_ARGS:-} clean "${tasks[@]}"

# --- Collect and verify --------------------------------------------------------------------------
version="$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' app/build.gradle.kts | head -1)"
code="$(sed -n 's/.*versionCode = \([0-9]*\).*/\1/p' app/build.gradle.kts | head -1)"
out="$root/dist"; mkdir -p "$out"
apk="$out/PassVault-$version-$code.apk"; aab="$out/PassVault-$version-$code.aab"
cp app/build/outputs/apk/release/app-release.apk "$apk"
if [ -f "$lineage" ]; then
  # Re-sign with the lineage (APK Signature Scheme v3 only; every supported Android version verifies it).
  min_sdk="$(sed -n 's/.*minSdk = \([0-9]*\).*/\1/p' app/build.gradle.kts | head -1)"
  mv "$apk" "$apk.unrotated"
  "$apksigner" sign --ks "$keystore" --ks-key-alias "$alias_name" --ks-pass env:PASSVAULT_KEYSTORE_PASSWORD --lineage "$lineage" \
    --min-sdk-version "$min_sdk" --rotation-min-sdk-version "$min_sdk" --v1-signing-enabled false --v2-signing-enabled false --v3-signing-enabled true \
    --out "$apk" "$apk.unrotated" || { rm -f "$apk.unrotated"; die "Signing with the lineage failed. Does $lineage end with the key in $keystore? (Re-run scripts/rotate-signing-key.sh --force.)"; }
  rm -f "$apk.unrotated" "$apk.idsig"
  echo "Key-rotation lineage attached: $lineage"
fi
cp app/build/outputs/bundle/release/app-release.aab "$aab"

"$apksigner" verify --print-certs -v --min-sdk-version "${min_sdk:-30}" "$apk" | sed -n '1,8p'
"$JAVA_HOME/bin/jarsigner" -verify "$aab" >/dev/null || die "AAB signature verification failed."
(cd "$out" && shasum -a 256 "$(basename "$apk")" "$(basename "$aab")" | tee "PassVault-$version-$code.SHA256SUMS")
cat <<MSG

Done.
  Play Store upload : $aab
  Sideload APK      : $apk$([ -f "$lineage" ] && echo '  (with key-rotation lineage)')
Before the next release, increase versionCode in android/app/build.gradle.kts (Play rejects a repeated code).
MSG
