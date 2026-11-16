# PassVault's settings for the build and release scripts (sourced by _signing-common.sh).

app_name=PassVault
app_id=app.passvault.mobile
# Environment variables are named <env_prefix>_KEYSTORE, <env_prefix>_KEY_ALIAS and so on (see _signing-common.sh).
env_prefix=PASSVAULT
default_keystore="$HOME/.passvault-signing/passvault-upload.jks"
default_key_alias=upload
default_lineage="$HOME/.passvault-signing/lineage.bin"
# Directories whose untracked files could end up in a release build.
build_dirs=(android ios scripts)
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

# Connected device tests (test-android-device.sh, run by release-github.sh before anything is signed). They use the
# emulator-only qa variant (app.passvault.mobile.qa), which accepts an emulator's software-backed keys, so they never
# touch the debug or release app and their vaults.
device_test_task=:app:connectedQaAndroidTest
device_test_app='the PassVault QA app and its test vaults'

# PassVault creates Keystore keys only behind a secure lock screen. An emulator without one gets the PIN 1234 for the
# tests and loses it afterwards; one that already has 1234 keeps it. With a PIN, the emulator's storage stays locked
# after a boot until the first unlock, and the tests hang, so the emulator is unlocked with the PIN. A phone must have
# a screen lock of its own and be unlocked.
test_device_pin=1234
test_device_pin_set=0
prepare_test_device() {
  local adb="$1" serial="$2" waited=0
  local qemu
  qemu="$("$adb" -s "$serial" shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r')$("$adb" -s "$serial" shell getprop ro.boot.qemu 2>/dev/null | tr -d '\r')"
  case "$qemu" in *1*) ;; *) return 0 ;; esac
  if "$adb" -s "$serial" shell locksettings set-pin "$test_device_pin" >/dev/null 2>&1; then
    test_device_pin_set=1
  elif ! "$adb" -s "$serial" shell locksettings verify --old "$test_device_pin" >/dev/null 2>&1; then
    die "The emulator $serial has a screen lock other than the PIN $test_device_pin. Remove it or change it to $test_device_pin."
  fi
  test_device_unlocked() { "$adb" -s "$serial" shell am get-started-user-state 0 2>/dev/null | grep -q RUNNING_UNLOCKED; }
  test_device_unlocked && return 0
  printf 'Unlocking the emulator %s with its PIN so that its storage opens.\n' "$serial"
  "$adb" -s "$serial" shell input keyevent 82 >/dev/null 2>&1 || true
  "$adb" -s "$serial" shell input swipe 500 1500 500 300 >/dev/null 2>&1 || true
  "$adb" -s "$serial" shell input text "$test_device_pin" >/dev/null 2>&1 || true
  "$adb" -s "$serial" shell input keyevent 66 >/dev/null 2>&1 || true
  until test_device_unlocked; do
    [ "$waited" -lt 60 ] || die "The emulator $serial stayed locked. Unlock it with the PIN $test_device_pin, then run again."
    sleep 2; waited=$((waited + 2))
  done
}
restore_test_device() {
  [ "$test_device_pin_set" = 1 ] || return 0
  "$1" -s "$2" shell locksettings clear --old "$test_device_pin" >/dev/null
}

# iOS App Store release configuration. Versions come from Android release metadata.
ios_scheme=PassVault
run_ios_tests() { swift test; swift run vault-security-checks; }
