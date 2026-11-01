#!/usr/bin/env bash
# Build a signed App Store IPA without uploading it.
# Usage: scripts/build-ios-app-store.sh [--skip-tests] [--check]
#        scripts/build-ios-app-store.sh --upload-archive PATH
# Needs macOS, Xcode 26+, XcodeGen, Python 3 and DEVELOPMENT_TEAM.
# Upload is explicit and uses an existing archive; it does not submit for review.
set +x
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/_signing-common.sh"
skip_tests=0; check_only=0; upload_archive=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-tests) skip_tests=1; shift ;;
    --check) check_only=1; shift ;;
    --upload-archive)
      [ "$#" -ge 2 ] || die 'Missing archive path.'
      upload_archive="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[ "$(uname)" = Darwin ] || die 'App Store builds need macOS.'
xcodebuild -version >/dev/null 2>&1 || die 'Install full Xcode and select it with xcode-select.'
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
[ "${sdk%%.*}" -ge 26 ] || die 'App Store uploads require the iOS 26 SDK or later.'
command -v python3 >/dev/null 2>&1 || die 'Python 3 is required.'
[[ "${DEVELOPMENT_TEAM:-}" =~ ^[A-Z0-9]{10}$ ]] || die 'Set DEVELOPMENT_TEAM to your 10-character Apple Developer team ID.'
auth=(-allowProvisioningUpdates)
if [ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]; then
  [ -f "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] \
    || die 'Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID together (App Store Connect team API key).'
  auth+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
if [ -z "$upload_archive" ]; then
  command -v xcodegen >/dev/null 2>&1 || die 'Install XcodeGen before building; this script installs nothing.'
  if [ "$check_only" = 0 ]; then
    read_version
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'App Store versions must have three numeric components; prerelease suffixes are unsupported.'
    [ "$code" -le 9999 ] || die 'The single-component iOS build number must be at most 9999.'
  fi
fi
[ "$check_only" = 0 ] || exit 0
mkdir -p "$root/dist"
if [ -n "$upload_archive" ]; then
  [ -d "$upload_archive" ] || die "Archive not found: $upload_archive"
  archive="$(cd "$upload_archive" && pwd)"
  destination=upload
  output="$(mktemp -d "$root/dist/app-store-upload.XXXXXX")"
else
  check_sources --release
  cd "$root/ios"
  if [ "$skip_tests" = 0 ]; then run_ios_tests; fi
  xcodegen generate --quiet
  archive="$root/dist/$app_name-$version-$code.xcarchive"
  output="$root/dist/$app_name-$version-$code-app-store"
  [ ! -e "$archive" ] && [ ! -e "$output" ] || die 'App Store artifacts already exist. Move them aside or use --upload-archive to upload the existing build.'
  xcodebuild archive -project "$ios_scheme.xcodeproj" -scheme "$ios_scheme" \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$root/ios/build/app-store" -archivePath "$archive" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$code" "${auth[@]}"
  destination=export
  mkdir -p "$output"
fi
# Check archive identity before exporting or uploading. Upload uses its recorded version, never current sources.
python3 - "$archive" "$app_id" "$DEVELOPMENT_TEAM" "${version:-}" "${code:-}" <<'PY'
import pathlib, plistlib, sys
archive, bundle, team, version, code = sys.argv[1:]
with open(pathlib.Path(archive) / 'Info.plist', 'rb') as f:
    props = plistlib.load(f)['ApplicationProperties']
if props.get('CFBundleIdentifier') != bundle:
    sys.exit('Archive bundle ID does not match this project.')
if props.get('Team') != team:
    sys.exit('Archive signing team does not match DEVELOPMENT_TEAM.')
if version and (props.get('CFBundleShortVersionString') != version or props.get('CFBundleVersion') != code):
    sys.exit('Archive version/build number does not match release metadata.')
PY
options="$output/ExportOptions.plist"
python3 - "$options" "$DEVELOPMENT_TEAM" "$destination" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(method='app-store-connect', destination=sys.argv[3], teamID=sys.argv[2],
                      signingStyle='automatic', manageAppVersionAndBuildNumber=False,
                      uploadSymbols=True), f)
PY
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
  -exportPath "$output" "${auth[@]}"
if [ "$destination" = export ]; then
  [ -f "$output/$ios_scheme.ipa" ] || die 'Export finished without the expected IPA.'
  printf '\nApp Store IPA: %s\nArchive (keep its dSYMs): %s\n' "$output/$ios_scheme.ipa" "$archive"
  printf 'Upload explicitly: scripts/build-ios-app-store.sh --upload-archive "%s"\n' "$archive"
else
  printf '\nUploaded archive: %s\nWait for processing in App Store Connect; review submission is a separate step.\n' "$archive"
fi
