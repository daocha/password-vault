#!/bin/sh
# Gives the CI emulator a PIN and leaves it unlocked. PassVault's Keystore keys need a secure lock screen and refuse to work while
# the device is locked (setUnlockedDeviceRequired), so a lock screen that comes back before the tests start fails them all.
set -eu
adb shell locksettings set-pin 1234
# Keep the screen on so the device does not lock itself again during the run.
adb shell svc power stayon true
adb shell settings put system screen_off_timeout 2147483647
for attempt in 1 2 3 4 5; do
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard || true
  sleep 1
  adb shell input text 1234
  adb shell input keyevent KEYCODE_ENTER
  sleep 2
  if adb shell dumpsys window | grep -q 'isKeyguardShowing=false'; then echo "Emulator unlocked"; exit 0; fi
  echo "Lock screen still showing (attempt $attempt)"
done
echo "Could not unlock the emulator" >&2
exit 1
