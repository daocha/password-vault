#!/bin/sh
# Installs a pinned XcodeGen for CI, checked against its known hash. Homebrew would run whatever version is newest.
# To update, take the version and hash from the GitHub release.
set -eu
version=2.46.0
sha256=ef6d0a23bfb7393387f98e321ffd78a487231172e2e78c48d3c26275c263fd0c
folder="${RUNNER_TEMP:?RUNNER_TEMP is set by GitHub Actions}/xcodegen"
mkdir -p "$folder"
curl -fsSL -o "$folder/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.artifactbundle.zip"
printf '%s  %s\n' "$sha256" "$folder/xcodegen.zip" | shasum -a 256 -c -
unzip -q -o "$folder/xcodegen.zip" -d "$folder"
printf '%s\n' "$folder/xcodegen.artifactbundle/xcodegen-$version-macosx/bin" >> "$GITHUB_PATH"
