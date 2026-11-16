"""PassVault's device tests run the qa variant behind a PIN: the emulator gets one when it has none, is unlocked
when its storage is still locked, and loses the PIN afterwards only if the tests set it. Phones are left alone."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]

# A stand-in adb for one device whose lock state lives in TEST_LOCK_STATE:
# {"qemu": "1", "pin": "1234" or null, "unlocked": bool}. Typing the PIN and Enter on the lock screen unlocks it.
ADB = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
path = os.environ['TEST_LOCK_STATE']
state = json.load(open(path))
with open(os.environ['TEST_DEVICE_LOG'], 'a') as log: log.write(json.dumps(['adb'] + args) + '\\n')
if args[:1] == ['-s']: args = args[2:]
def save(): json.dump(state, open(path, 'w'))
if args == ['devices']:
    print('List of devices attached\\nemulator-5554\\tdevice' if state['qemu'] == '1' else 'List of devices attached\\nPHONE1\\tdevice')
elif args[:2] == ['shell', 'getprop']:
    key = args[2]
    if key in ('ro.boot.qemu', 'ro.kernel.qemu'): print(state['qemu'])
    elif key == 'sys.boot_completed': print('1')
elif args[:3] == ['shell', 'locksettings', 'set-pin']:
    if state['pin']: sys.exit(255)
    state['pin'] = args[3]; save()
elif args[:3] == ['shell', 'locksettings', 'verify']:
    old = args[args.index('--old') + 1] if '--old' in args else None
    if old != state['pin']: sys.exit(255)
    if not os.environ.get('TEST_VERIFY_KEEPS_LOCKED'): state['unlocked'] = True; save()
elif args[:3] == ['shell', 'locksettings', 'clear']:
    if args[args.index('--old') + 1] != state['pin']: sys.exit(255)
    state['pin'] = None; save()
elif args[:3] == ['shell', 'am', 'get-started-user-state']:
    print('RUNNING_UNLOCKED' if state['unlocked'] else 'RUNNING_LOCKED')
elif args[:3] == ['shell', 'input', 'text']:
    state['typed'] = args[3]; save()
elif args[:4] == ['shell', 'input', 'keyevent', '66']:
    if state.get('typed') == state['pin'] and not os.environ.get('TEST_STAYS_LOCKED'): state['unlocked'] = True; save()
'''

GRADLE = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_DEVICE_LOG'], 'a') as log: log.write(json.dumps(['gradle'] + sys.argv[1:]) + '\\n')
sys.exit(31 if os.environ.get('TEST_GRADLE_FAIL') else 0)
'''


class DeviceLockTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='device-lock-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'project'
        (self.root / 'scripts').mkdir(parents=True)
        (self.root / 'android').mkdir()
        for name in ('_signing-common.sh', 'test-android-device.sh', 'release-settings.sh'):
            shutil.copy2(PROJECT / 'scripts' / name, self.root / 'scripts' / name)
        java = self.root / 'jdk/bin'
        java.mkdir(parents=True)
        for name in ('java', 'keytool'):
            self.executable(java / name, '#!/bin/sh\nexit 0\n')
        sdk = self.root / 'sdk'
        (sdk / 'platform-tools').mkdir(parents=True)
        self.executable(sdk / 'platform-tools/adb', ADB)
        self.executable(self.root / 'android/gradlew', GRADLE)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        self.executable(bin_dir / 'sleep', '#!/bin/sh\nexit 0\n')  # the unlock wait ends at once
        self.log = self.root / 'calls.jsonl'
        self.state = self.root / 'lock.json'
        self.env = dict(os.environ, JAVA_HOME=str(java.parent), ANDROID_HOME=str(sdk), TEST_DEVICE_LOG=str(self.log),
                        TEST_LOCK_STATE=str(self.state), PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
        for name in ('GRADLE_EXTRA_ARGS', 'ANDROID_SERIAL', 'ANDROID_AVD', 'ANDROID_EMULATOR_OPTIONS',
                     'ANDROID_EMULATOR_PORT', 'TEST_GRADLE_FAIL', 'TEST_STAYS_LOCKED', 'TEST_VERIFY_KEEPS_LOCKED'):
            self.env.pop(name, None)

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def device(self, qemu='1', pin=None, unlocked=True):
        self.state.write_text(json.dumps({'qemu': qemu, 'pin': pin, 'unlocked': unlocked}))

    def run_tests(self):
        return subprocess.run(['bash', str(self.root / 'scripts/test-android-device.sh')], env=self.env,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def shell(self, *words):
        return [c[3:] for c in self.calls() if c[0] == 'adb' and c[3:3 + len(words)] == list(words)]

    def final_state(self):
        return json.loads(self.state.read_text())

    def gradle_index(self):
        return next(i for i, c in enumerate(self.calls()) if c[0] == 'gradle')

    def test_emulator_without_a_lock_gets_the_pin_for_the_qa_tests_and_loses_it_afterwards(self):
        self.device()
        result = self.run_tests()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        calls = self.calls()
        gradle = self.gradle_index()
        self.assertIn(':app:connectedQaAndroidTest', calls[gradle])
        set_pin = calls.index(['adb', '-s', 'emulator-5554', 'shell', 'locksettings', 'set-pin', '1234'])
        clear = calls.index(['adb', '-s', 'emulator-5554', 'shell', 'locksettings', 'clear', '--old', '1234'])
        self.assertLess(set_pin, gradle)
        self.assertLess(gradle, clear)
        self.assertIsNone(self.final_state()['pin'])
        self.assertIn('the PassVault QA app', result.stdout)

    def test_pin_set_by_the_tests_is_removed_after_failed_tests(self):
        self.device()
        self.env['TEST_GRADLE_FAIL'] = '1'
        self.assertEqual(31, self.run_tests().returncode)
        self.assertIsNone(self.final_state()['pin'])

    def test_emulator_that_already_has_the_pin_keeps_it(self):
        self.device(pin='1234')
        result = self.run_tests()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual([], self.shell('locksettings', 'clear'))
        self.assertEqual([], self.shell('input'))
        self.assertEqual('1234', self.final_state()['pin'])

    def test_locked_emulator_is_unlocked_with_the_pin_before_the_tests(self):
        self.device(pin='1234', unlocked=False)
        self.env['TEST_VERIFY_KEEPS_LOCKED'] = '1'
        result = self.run_tests()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        calls = self.calls()
        typed = calls.index(['adb', '-s', 'emulator-5554', 'shell', 'input', 'text', '1234'])
        self.assertLess(typed, self.gradle_index())
        self.assertTrue(self.final_state()['unlocked'])

    def test_emulator_that_stays_locked_stops_before_the_tests(self):
        self.device(pin='1234', unlocked=False)
        self.env.update(TEST_VERIFY_KEEPS_LOCKED='1', TEST_STAYS_LOCKED='1')
        result = self.run_tests()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('stayed locked', result.stderr)
        self.assertEqual([], [c for c in self.calls() if c[0] == 'gradle'])

    def test_emulator_with_another_lock_stops_before_the_tests_and_keeps_it(self):
        self.device(pin='9999')
        result = self.run_tests()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('other than the PIN 1234', result.stderr)
        self.assertEqual([], [c for c in self.calls() if c[0] == 'gradle'])
        self.assertEqual([], self.shell('locksettings', 'clear'))
        self.assertEqual('9999', self.final_state()['pin'])

    def test_a_phone_lock_is_never_changed(self):
        self.device(qemu='0')
        self.env['ANDROID_SERIAL'] = 'PHONE1'
        result = self.run_tests()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual([], self.shell('locksettings'))
        self.assertEqual([], self.shell('input'))
        self.assertIsNone(self.final_state()['pin'])


if __name__ == '__main__':
    unittest.main()
