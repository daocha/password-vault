#!/usr/bin/env bash
# Builds the signed release and publishes it as a GitHub Release: tag vX.Y.Z, the sideload APK and its SHA-256 file attached.
# The signing key stays on your machine; only the finished APK and checksums are uploaded.
#
#   scripts/release-github.sh                build, then tag and publish after you confirm
#   scripts/release-github.sh --draft        create the release as a draft to review on GitHub first
#   scripts/release-github.sh --skip-build   reuse the APK already in dist/ for the current version
#   scripts/release-github.sh --skip-tests   passed through to build-android-release.sh
#
# Needs the GitHub CLI (`gh auth login` once), a clean git tree, and the versionName/versionCode in android/app/build.gradle.kts.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }
draft=(); build=1; build_args=()
for arg in "$@"; do case "$arg" in
  --draft) draft=(--draft) ;; --skip-build) build=0 ;; --skip-tests) build_args+=(--skip-tests) ;;
  -h|--help) sed -n '2,10p' "$0"; exit 0 ;; *) die "Unknown option: $arg" ;; esac; done

command -v gh >/dev/null || die "GitHub CLI not found. Install it (brew install gh) and run 'gh auth login'."
gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub. Run 'gh auth login'."
cd "$root"
[ -z "$(git status --porcelain)" ] || die "Uncommitted changes. Commit them first so the tag matches what was built."

gradle="android/app/build.gradle.kts"
version="$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' "$gradle" | head -1)"
code="$(sed -n 's/.*versionCode = \([0-9]*\).*/\1/p' "$gradle" | head -1)"
[ -n "$version" ] && [ -n "$code" ] || die "Could not read versionName/versionCode from $gradle."
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "Tag $tag already exists. Raise versionName/versionCode in $gradle for a new release."
gh release view "$tag" >/dev/null 2>&1 && die "GitHub already has a release for $tag."

[ "$build" = 1 ] && "$here/build-android-release.sh" ${build_args[@]+"${build_args[@]}"}
apk="dist/PassVault-$version-$code.apk"; sums="dist/PassVault-$version-$code.SHA256SUMS"
[ -f "$apk" ] && [ -f "$sums" ] || die "Missing $apk or $sums. Run without --skip-build."

echo; echo "About to publish $tag${draft[*]:+ (draft)} from commit $(git rev-parse --short HEAD) with:"; ls -l "$apk" "$sums"
read -r -p "Tag, push and upload now? [y/N] " yn
[ "$yn" = "y" ] || [ "$yn" = "Y" ] || die "Aborted. Nothing was pushed."

git tag -a "$tag" -m "PassVault $version"
git push origin "$tag"
gh release create "$tag" "$apk" "$sums" --verify-tag --title "PassVault $version" ${draft[@]+"${draft[@]}"} --notes "Android sideload APK (Android 11+). Verify the download against the SHA256SUMS file.

**Development build, not security-audited. Don't rely on it for valuable credentials yet.**"
echo "Done: $(gh release view "$tag" --json url -q .url)"
