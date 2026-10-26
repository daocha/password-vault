# PassVault's settings for the shared Android build/release scripts (sourced by _signing-common.sh).
# Every other release script is the same file in PassVault and AquaRestore; only this one differs between them.

app_name=PassVault
app_id=app.passvault.mobile
# Environment variables are named <env_prefix>_KEYSTORE, <env_prefix>_KEY_ALIAS and so on (see _signing-common.sh).
env_prefix=PASSVAULT
default_keystore="$HOME/.passvault-signing/passvault-upload.jks"
default_key_alias=upload
default_lineage="$HOME/.passvault-signing/lineage.bin"
# Directories whose untracked files could end up in a release build.
build_dirs=(android scripts)
# The Play build must not update itself (Play policy) and, like every PassVault build but the sideload APK, stays offline.
play_forbidden_permissions=(android.permission.REQUEST_INSTALL_PACKAGES android.permission.INTERNET)

# Checks the sources before a build (--release: before a signed build). PassVault has nothing to fetch or check.
check_sources() { :; }

# Release notes for GitHub when --notes-file is not given. Arguments: version, versionCode, source commit.
default_release_notes() {
  cat <<NOTES
PassVault $1 ($2): Android sideload APK (Android 11+). Verify the download against the SHA256SUMS file.

**Open source, not independently audited.** Everything stays on your device. Keep a separate backup of anything important.

Source commit: $3
NOTES
}
