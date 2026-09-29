# Shared by build-android-release.sh and rotate-signing-key.sh (sourced, not run directly).
# Defines the signing configuration, finds the toolchain, and creates/opens the signing keystore.
#
# Optional environment:
#   PASSVAULT_KEYSTORE           keystore path         (default: ~/.passvault-signing/passvault-upload.jks)
#   PASSVAULT_KEY_ALIAS          key alias             (default: upload)
#   PASSVAULT_KEYSTORE_PASSWORD  password; prompted if unset (PKCS12: store and key share it)
#   PASSVAULT_LINEAGE            key-rotation lineage  (default: ~/.passvault-signing/lineage.bin)
#   JAVA_HOME, ANDROID_HOME      JDK 17 and Android SDK; detected from the usual macOS locations if unset

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
keystore="${PASSVAULT_KEYSTORE:-$HOME/.passvault-signing/passvault-upload.jks}"
alias_name="${PASSVAULT_KEY_ALIAS:-upload}"
lineage="${PASSVAULT_LINEAGE:-$HOME/.passvault-signing/lineage.bin}"

die() { echo "error: $*" >&2; exit 1; }

find_toolchain() {
  if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; fi
  [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/keytool" ] || die "JDK 17 not found. Install it (e.g. 'brew install --cask temurin@17') or set JAVA_HOME."
  if [ -z "${ANDROID_HOME:-}" ]; then for d in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do [ -d "$d" ] && ANDROID_HOME="$d" && break; done; fi
  [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME" ] || die "Android SDK not found. Install Android Studio or set ANDROID_HOME."
  export JAVA_HOME ANDROID_HOME
  # Skip preview build-tools (e.g. 36.0.0-rc1), which sort -V would rank above the matching stable release.
  apksigner="$(ls -d "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | grep -v -- '-rc' | sort -V | tail -1 || true)"
  [ -n "$apksigner" ] || die "Android build-tools (apksigner) not found in $ANDROID_HOME/build-tools."
}

# Creates the keystore on first use, then makes sure the alias opens with PASSVAULT_KEYSTORE_PASSWORD (prompting if unset).
ensure_keystore() {
  if [ ! -f "$keystore" ]; then
    echo "No signing keystore at $keystore."
    read -r -p "Create it now? [y/N] " yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || die "Aborted. Set PASSVAULT_KEYSTORE to an existing keystore."
    # Only a directory created here is made private; an existing one (e.g. \$HOME) keeps its permissions.
    [ -d "$(dirname "$keystore")" ] || (umask 077; mkdir -p "$(dirname "$keystore")")
    echo "keytool will ask for a password (choose a long one) and your name/organisation details."
    # umask 077: the keystore is never readable by other users, not even before the chmod.
    (umask 077; "$JAVA_HOME/bin/keytool" -genkeypair -v -storetype PKCS12 -keystore "$keystore" -alias "$alias_name" -keyalg RSA -keysize 4096 -validity 10000)
    chmod 600 "$keystore"
    cat <<MSG

Keystore created: $keystore
BACK IT UP NOW (with its password) in at least two places, one offline. If you enrol in Play App Signing
this is only the *upload* key and Google can reset it, but losing it still delays every release.
MSG
  fi
  if [ -z "${PASSVAULT_KEYSTORE_PASSWORD:-}" ]; then read -r -s -p "Keystore password: " PASSVAULT_KEYSTORE_PASSWORD; echo; fi
  export PASSVAULT_KEYSTORE_PASSWORD
  "$JAVA_HOME/bin/keytool" -list -keystore "$keystore" -alias "$alias_name" -storepass:env PASSVAULT_KEYSTORE_PASSWORD >/dev/null 2>&1 \
    || die "Could not open alias '$alias_name' in $keystore (wrong password or alias?)."
}
