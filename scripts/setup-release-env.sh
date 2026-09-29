#!/usr/bin/env bash
# Installs what scripts/release-github.sh and build-android-release.sh need on a fresh macOS: JDK 17, the GitHub CLI
# and the Android SDK (platform 36, build-tools with apksigner) in ~/Library/Android/sdk, where the scripts look for it.
# Safe to re-run: anything already installed is skipped. Needs Homebrew (https://brew.sh).
#
#   scripts/setup-release-env.sh
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[ "$(uname)" = Darwin ] || die "This script is for macOS."
command -v brew >/dev/null || die "Homebrew not found. Install it from https://brew.sh, then re-run."

have_cask() { brew list --cask "$1" >/dev/null 2>&1; }
have_jdk17() { [ -x /usr/libexec/java_home ] && /usr/libexec/java_home -v 17 >/dev/null 2>&1; }

have_jdk17 || brew install --cask temurin@17
command -v gh >/dev/null || brew install gh
command -v git >/dev/null || brew install git
have_cask android-commandlinetools || command -v sdkmanager >/dev/null || brew install --cask android-commandlinetools

JAVA_HOME="$(/usr/libexec/java_home -v 17)"; export JAVA_HOME
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
sdkmanager="$(command -v sdkmanager || true)"
[ -n "$sdkmanager" ] || sdkmanager="$(ls "$(brew --prefix)"/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager 2>/dev/null || true)"
[ -n "$sdkmanager" ] || die "sdkmanager not found after installing android-commandlinetools."

mkdir -p "$ANDROID_HOME"
echo "Accepting Android SDK licenses and installing packages into $ANDROID_HOME ..."
yes | "$sdkmanager" --sdk_root="$ANDROID_HOME" --licenses >/dev/null || true
"$sdkmanager" --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-36" "build-tools;36.0.0"

cat <<MSG

Done.
  JDK 17      : $JAVA_HOME
  Android SDK : $ANDROID_HOME
  GitHub CLI  : $(command -v gh)

Next:
  gh auth login                     (once; needed by scripts/release-github.sh)
  copy ~/.passvault-signing/ from your other Mac (keystore + lineage.bin), or the script will offer to create a NEW key.
  scripts/release-github.sh
MSG
