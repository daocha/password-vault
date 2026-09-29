#!/usr/bin/env bash
# One-time key rotation: makes your signing key (PASSVAULT_KEYSTORE) the successor of an OLD key, by creating the
# rotation lineage that build-android-release.sh then attaches to every sideload APK automatically.
# Phones with a build signed by the old key can then update in place and keep their vault.
#
#   scripts/rotate-signing-key.sh            create the lineage (does nothing if one already exists)
#   scripts/rotate-signing-key.sh --force    replace an existing lineage (the old file is kept as a timestamped backup)
#
# The NEW key is the one from _signing-common.sh (created here if it doesn't exist yet).
# Optional environment for the OLD key (defaults to the Android debug key, i.e. builds made by ./gradlew assembleDebug):
#   OLD_KEYSTORE (~/.android/debug.keystore)   OLD_KEY_ALIAS (androiddebugkey)   OLD_KEYSTORE_PASSWORD (android; prompted for other keystores)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; . "$here/_signing-common.sh"
force=0
for arg in "$@"; do case "$arg" in --force) force=1 ;; -h|--help) sed -n '2,12p' "$0"; exit 0 ;; *) echo "Unknown option: $arg" >&2; exit 2 ;; esac; done

find_toolchain
if [ -f "$lineage" ] && [ "$force" = 0 ]; then
  echo "A lineage already exists: $lineage"; echo "Nothing to do. Builds made with build-android-release.sh already use it (--force to replace)."; exit 0
fi

old_ks="${OLD_KEYSTORE:-$HOME/.android/debug.keystore}"; old_alias="${OLD_KEY_ALIAS:-androiddebugkey}"
[ -f "$old_ks" ] || die "Old keystore not found: $old_ks (set OLD_KEYSTORE / OLD_KEY_ALIAS)."
if [ -z "${OLD_KEYSTORE_PASSWORD:-}" ]; then
  if [ -z "${OLD_KEYSTORE:-}" ]; then OLD_KEYSTORE_PASSWORD=android; else read -r -s -p "Old keystore password: " OLD_KEYSTORE_PASSWORD; echo; fi
fi
export OLD_KEYSTORE_PASSWORD
ensure_keystore
[ "$old_ks" != "$keystore" ] || die "The old and new keystore are the same file."

mkdir -p "$(dirname "$lineage")"
[ -f "$lineage" ] && mv "$lineage" "$lineage.bak-$(date +%Y%m%d-%H%M%S)"
"$apksigner" rotate --out "$lineage" \
  --old-signer --ks "$old_ks" --ks-key-alias "$old_alias" --ks-pass env:OLD_KEYSTORE_PASSWORD \
  --new-signer --ks "$keystore" --ks-key-alias "$alias_name" --ks-pass env:PASSVAULT_KEYSTORE_PASSWORD
chmod 600 "$lineage"
cat <<MSG

Lineage created: $lineage
  old key: $old_ks ($old_alias)
  new key: $keystore ($alias_name)
Back it up together with both keystores. From now on run scripts/build-android-release.sh as usual: it detects the
lineage and attaches it to the sideload APK. Never distribute a build signed with only the old key.
MSG
