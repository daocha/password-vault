#!/bin/sh
# Gives the CI emulator a PIN and leaves it unlocked. PassVault's Keystore keys need a secure lock screen and refuse to work while
# the device is locked (setUnlockedDeviceRequired), so a lock screen that comes back before the tests start fails them all.
set -eu
# A rerun on an emulator that already has the PIN only checks it.
adb shell locksettings set-pin 1234 || adb shell locksettings verify --old 1234
# The Keystore's unlocked-device rule follows the trust service's deviceLocked, not the keyguard window.
unlocked() { adb shell dumpsys trust | grep -q 'deviceLocked=0'; }
# Right after set-pin the device can still report unlocked and lock moments later, so start from a known state: screen off, locked.
adb shell input keyevent KEYCODE_SLEEP
sleep 3
for attempt in 1 2 3 4 5; do
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard || true
  sleep 2
  # Clear anything typed by an earlier try, so a retry is never counted as a wrong PIN.
  for _ in 1 2 3 4 5 6; do adb shell input keyevent KEYCODE_DEL; done
  adb shell input text 1234
  adb shell input keyevent KEYCODE_ENTER
  # The first unlock after boot also unlocks the user's storage, which takes a few seconds.
  for _ in 1 2 3 4 5 6 7 8 9 10; do unlocked && break; sleep 1; done
  if unlocked; then
    # Keep the screen on so the device does not lock itself again during the run, and check that it stays unlocked.
    adb shell svc power stayon true
    adb shell settings put system screen_off_timeout 2147483647
    sleep 3
    if unlocked; then echo "Emulator unlocked"; exit 0; fi
  fi
  echo "Still locked (attempt $attempt)"
done
echo "Could not unlock the emulator" >&2
exit 1
