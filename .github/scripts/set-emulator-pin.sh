#!/bin/sh
# Gives the CI emulator a PIN. PassVault refuses to create Keystore keys without a secure lock screen. The emulator does not need to
# be unlocked: the emulator-only qa build leaves off the unlocked-device rule (REQUIRE_UNLOCKED_DEVICE), because unlocking a
# CI emulator through its lock screen proved unreliable.
set -eu
# A rerun on an emulator that already has the PIN only checks it.
adb shell locksettings set-pin 1234 || adb shell locksettings verify --old 1234
