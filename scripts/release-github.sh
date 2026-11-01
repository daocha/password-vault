#!/usr/bin/env bash
# Build, sign, tag, push and publish an Android APK + SHA256SUMS to GitHub.
# Usage: scripts/release-github.sh [--version 1.0.1] [--version-code 2]
#        [--draft] [--prerelease] [--notes-file FILE] [--skip-tests] [--dry-run] [--play] [--app-store]
# --dry-run builds/verifies locally only; no commits, tags, pushes or GitHub writes.
# --play also builds the Google Play bundle from the same source and versionCode (not uploaded anywhere).
# --app-store also exports a signed iOS IPA locally; upload it separately with build-ios-app-store.sh.
# Uses the current branch and origin GitHub repository. Requires committed sources to publish, and asks before
# publishing when run in a terminal. New version names automatically increment versionCode unless explicitly provided.
# Signing configuration: see _signing-common.sh.
set +x
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/_signing-common.sh"
draft=0; prerelease=0; dry_run=0; skip_tests=0; play=0; app_store=0
requested_version=''; requested_code=''; notes_file=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--version-code|--notes-file)
      [ "$#" -ge 2 ] || die "Missing value for $1"
      case "$1" in
        --version) requested_version="${2#v}" ;;
        --version-code) requested_code="$2" ;;
        --notes-file) notes_file="$2" ;;
      esac
      shift 2 ;;
    --draft) draft=1; shift ;;
    --prerelease) prerelease=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --skip-tests) skip_tests=1; shift ;;
    --play) play=1; shift ;;
    --app-store) app_store=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
if [ -n "$notes_file" ]; then
  [ -f "$notes_file" ] || die "Release notes file not found: $notes_file"
  notes_file="$(cd "$(dirname "$notes_file")" && pwd)/$(basename "$notes_file")"
fi
cd "$root"
# Untracked files outside build_dirs (e.g. release notes at the root) cannot change the build, so they are allowed.
untracked_in_build() { git ls-files --others --exclude-standard -- "${build_dirs[@]}"; }
read_version
current_version="$version"; current_code="$code"
if [ "$dry_run" = 0 ]; then
  command -v gh >/dev/null 2>&1 || die "Install GitHub CLI and run 'gh auth login' first."
  gh auth status --hostname github.com >/dev/null 2>&1 || die "Run 'gh auth login --hostname github.com' first."
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die 'Commit your changes first so the release corresponds to committed source.'
  [ -z "$(untracked_in_build)" ] || die "Untracked files could end up in the build; commit or remove them: $(untracked_in_build | tr '\n' ' ')"
  branch="$(git symbolic-ref --quiet --short HEAD)" || die 'Check out a branch before publishing.'
  origin="$(git remote get-url origin)"
  case "$origin" in
    git@github.com:*) repo="${origin#git@github.com:}" ;;
    https://github.com/*) repo="${origin#https://github.com/}" ;;
    ssh://git@github.com/*) repo="${origin#ssh://git@github.com/}" ;;
    *) die 'origin must point to a github.com repository via SSH or HTTPS.' ;;
  esac
  repo="${repo%.git}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die 'Cannot parse the origin repository.'
  gh api "repos/$repo" --silent || die "Cannot access $repo."
fi
if [ -z "$requested_version" ] && [ -t 0 ] && [ "$dry_run" = 0 ]; then
  read -r -p "Version to release [current: $version, code $code]: " requested_version
  requested_version="${requested_version#v}"
fi
version="${requested_version:-$current_version}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die 'Version must look like 1.0.0 or 1.0.0-beta.1.'
if [ -n "$requested_code" ]; then
  [[ "$requested_code" =~ ^[1-9][0-9]*$ ]] || die 'versionCode must be a positive integer.'
  [ "${#requested_code}" -le 10 ] || die 'versionCode is too large.'
  code="$requested_code"
elif [ "$version" != "$current_version" ]; then code=$((current_code + 1)); fi
[ "$code" -le 2100000000 ] || die 'versionCode must be at most 2100000000.'
[ "$code" -ge "$current_code" ] || die 'versionCode cannot decrease.'
if [ "$version" != "$current_version" ] && [ "$code" -le "$current_code" ]; then die 'A new version needs a higher versionCode.'; fi
if [ "$app_store" = 1 ]; then
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'App Store versions must have three numeric components.'
  [ "$code" -le 9999 ] || die 'The single-component iOS build number must be at most 9999.'
  "$here/build-ios-app-store.sh" --check
fi
tag="v$version"
git check-ref-format "refs/tags/$tag" >/dev/null || die "Invalid version tag: $tag"
if [ "$dry_run" = 0 ]; then
  if git show-ref --verify --quiet "refs/tags/$tag"; then die "Local tag $tag already exists. Choose a new version."; fi
  remote_refs="$(gh api "repos/$repo/git/matching-refs/tags/$tag" --jq '.[].ref')"
  while IFS= read -r ref; do
    [ "$ref" != "refs/tags/$tag" ] || die "Remote tag $tag already exists. Existing releases are never overwritten."
  done <<< "$remote_refs"
fi
# Version metadata is part of the tagged source; no unrecorded -P overrides.
if [ "$version" != "$current_version" ] || [ "$code" != "$current_code" ]; then
  temp_gradle="$(mktemp "$android_root/app/.release-version.XXXXXX")"
  awk -v version="$version" -v code="$code" '
    /^[[:space:]]*versionName = "/ { $0 = "        versionName = \"" version "\"" }
    /^[[:space:]]*versionCode = [0-9]/ { $0 = "        versionCode = " code }
    { print }
  ' "$android_root/app/build.gradle.kts" > "$temp_gradle"
  mv "$temp_gradle" "$android_root/app/build.gradle.kts"
fi
built_head="$(git rev-parse HEAD)"
expected_diff="$(git diff --binary HEAD -- | sha256 | awk '{print $1}')"
# --play signs twice with the same key: ask for the password once, here, instead of in each build.
trap forget_passwords EXIT
if [ "$play" = 1 ] && [ -t 0 ]; then find_toolchain; ensure_keystore; fi
printf 'Building %s %s (%s)%s\n' "$app_name" "$version" "$code" "$([ "$dry_run" = 1 ] && printf ' — local dry run' || true)"
if [ "$skip_tests" = 1 ]; then "$here/build-android-release.sh" --skip-tests
else "$here/build-android-release.sh"; fi
apk="$root/dist/$app_name-$version-$code.apk"
sums="$root/dist/$app_name-$version-$code.SHA256SUMS"
[ -f "$apk" ] && [ -f "$sums" ] || die 'Missing release artifacts.'
aab="$root/dist/$app_name-$version-$code-play.aab"
if [ "$play" = 1 ]; then
  # Tests and release Lint already ran for the APK; the Play script still lints its own variant unless skipped.
  if [ "$skip_tests" = 1 ]; then "$here/build-android-play.sh" --skip-tests
  else "$here/build-android-play.sh"; fi
  [ -f "$aab" ] || die 'Missing Play bundle.'
fi
forget_passwords
if [ "$app_store" = 1 ]; then
  if [ "$skip_tests" = 1 ]; then "$here/build-ios-app-store.sh" --skip-tests
  else "$here/build-ios-app-store.sh"; fi
  ipa="$root/dist/$app_name-$version-$code-app-store/$ios_scheme.ipa"
  [ -f "$ipa" ] || die 'Missing App Store IPA.'
fi
if [ "$dry_run" = 1 ]; then
  printf '\nDry run complete. No Git/GitHub writes. Version edits, if any, remain for review.\n'
  exit 0
fi
[ "$(git rev-parse HEAD)" = "$built_head" ] && \
  [ "$(git diff --binary HEAD -- | sha256 | awk '{print $1}')" = "$expected_diff" ] && \
  [ -z "$(untracked_in_build)" ] || die 'Source changed during the build. Nothing was published; build again.'
if [ -t 0 ]; then
  printf '\nAbout to publish %s%s from branch %s:\n' "$tag" "$([ "$draft" = 1 ] && printf ' (draft)' || true)" "$branch"
  ls -l "$apk" "$sums"
  read -r -p 'Commit the version, tag, push and publish now? [y/N] ' yn
  [ "$yn" = y ] || [ "$yn" = Y ] || die 'Aborted. Nothing was committed or pushed; version edits, if any, remain for review.'
fi
if ! git diff --quiet HEAD -- android/app/build.gradle.kts; then
  git add android/app/build.gradle.kts
  git commit -m "Release $version"
fi
commit="$(git rev-parse HEAD)"
git tag -a "$tag" -m "$app_name $version"
# Atomic: if the branch is refused (e.g. a protected main), the tag is not pushed either.
if ! git push --atomic origin "HEAD:refs/heads/$branch" "refs/tags/$tag"; then
  git tag -d "$tag" >/dev/null
  die "Push refused; nothing was pushed or published, and the local tag $tag was removed. If $branch is protected, merge the version commit through a pull request, then run this again from the merged branch with the same --version."
fi
if [ -z "$notes_file" ]; then
  notes_file="$root/dist/$app_name-$version-notes.md"
  default_release_notes "$version" "$code" "$commit" > "$notes_file"
fi
release_args=(release create "$tag" "$apk" "$sums" --repo "$repo" --verify-tag --draft
  --title "$app_name $version" --notes-file "$notes_file")
[ "$prerelease" = 0 ] || release_args+=(--prerelease)
# Upload into a draft first. A failed upload must not expose an incomplete public release.
if ! gh "${release_args[@]}"; then
  die "Tag was pushed; upload failed. Inspect 'gh release view $tag --repo $repo' for a draft before retrying."
fi
if [ "$draft" = 0 ]; then
  gh release edit "$tag" --repo "$repo" --draft=false || die 'Assets uploaded, but publishing failed. The release remains a draft.'
fi
printf '\nRelease: %s\n' "$(gh release view "$tag" --repo "$repo" --json url --jq .url)"
[ "$play" = 0 ] || printf 'Play bundle (upload it in Play Console with its mapping file): %s\n' "$aab"
[ "$app_store" = 0 ] || printf 'App Store IPA (upload separately to App Store Connect): %s\n' "$ipa"
