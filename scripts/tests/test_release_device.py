"""Release Android checks pick one safe test device, fail closed and keep signing credentials out of Gradle."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]

# A stand-in adb. Devices come from TEST_ADB_DEVICES ({serial: {"qemu": "1", "avd": name, "model": ...}}) plus any
# emulator the stand-in emulator started (listed in TEST_ADB_STATE).
ADB = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
devices = json.loads(os.environ.get('TEST_ADB_DEVICES', '{}'))
state = os.environ['TEST_ADB_STATE']
if os.path.exists(state):
    devices.update(json.load(open(state)))
with open(os.environ['TEST_DEVICE_LOG'], 'a') as log: log.write(json.dumps(['adb'] + args) + '\\n')
serial = None
if args[:1] == ['-s']:
    serial, args = args[1], args[2:]
if args == ['devices']:
    print('List of devices attached')
    for name in devices: print(name + '\\tdevice')
    sys.exit(0)
device = devices.get(serial)
if device is None: sys.exit(1)
if args[:2] == ['shell', 'getprop']:
    key = args[2]
    if key in ('ro.boot.qemu', 'ro.kernel.qemu'): print(device.get('qemu', '0'))
    elif key == 'sys.boot_completed': print('1')
    elif key == 'ro.product.model': print(device.get('model', 'Pixel'))
elif args[:2] == ['emu', 'avd']: print(device.get('avd', '')); print('OK')
elif args == ['emu', 'kill'] and os.path.exists(state) and serial in json.load(open(state)): os.remove(state)
'''

# A stand-in emulator. Like the real one, it keeps running until `adb emu kill` stops it (which removes TEST_ADB_STATE):
# test-android-device.sh treats an emulator process that exits by itself as a failed boot. A stand-in that exited at
# once made the tests depend on whether the script's first boot check came before or after that exit.
EMULATOR = '''#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
with open(os.environ['TEST_DEVICE_LOG'], 'a') as log: log.write(json.dumps(['emulator'] + args) + '\\n')
serial = 'emulator-' + args[args.index('-port') + 1]
state = os.environ['TEST_ADB_STATE']
with open(state + '.tmp', 'w') as f: json.dump({serial: {'qemu': '1', 'avd': args[args.index('-avd') + 1]}}, f)
os.replace(state + '.tmp', state)  # adb never reads a half-written file
deadline = time.monotonic() + 60  # never outlive a test whose script forgot to stop it
while os.path.exists(state) and time.monotonic() < deadline:
    time.sleep(0.05)
'''

GRADLE = '''#!/usr/bin/env python3
import json, os, sys
keys = ['FIXTURE_KEYSTORE_PASSWORD', 'FIXTURE_KEY_PASSWORD', 'FIXTURE_KEYSTORE_FILE', 'FIXTURE_KEY_ALIAS']
with open(os.environ['TEST_DEVICE_LOG'], 'a') as log:
    log.write(json.dumps(['gradle', os.environ.get('ANDROID_SERIAL'), [key for key in keys if key in os.environ]]
                         + sys.argv[1:]) + '\\n')
failing = os.environ.get('TEST_GRADLE_FAIL_TASK')
sys.exit(31 if failing and failing in sys.argv else 0)
'''


class ReleaseDeviceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='release-device-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'project with spaces'
        (self.root / 'scripts').mkdir(parents=True)
        (self.root / 'android').mkdir()
        for name in ('_signing-common.sh', 'test-android-device.sh', 'test-android-release.sh'):
            shutil.copy2(PROJECT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'scripts/release-settings.sh').write_text('''env_prefix=FIXTURE
default_keystore=unused
default_key_alias=unused
default_lineage=unused
check_sources() { :; }
''')
        java = self.root / 'jdk/bin'
        java.mkdir(parents=True)
        for name in ('java', 'keytool'):
            self.executable(java / name, '#!/bin/sh\nexit 0\n')
        sdk = self.root / 'sdk'
        (sdk / 'platform-tools').mkdir(parents=True)
        (sdk / 'emulator').mkdir()
        self.executable(sdk / 'platform-tools/adb', ADB)
        self.executable(sdk / 'emulator/emulator', EMULATOR)
        self.executable(self.root / 'android/gradlew', GRADLE)
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, JAVA_HOME=str(java.parent), ANDROID_HOME=str(sdk),
                        TEST_DEVICE_LOG=str(self.log), TEST_ADB_STATE=str(self.root / 'adb-state.json'),
                        TEST_ADB_DEVICES=json.dumps({'emulator-5554': {'qemu': '1', 'avd': 'other'}}),
                        FIXTURE_KEYSTORE_PASSWORD='fixture', FIXTURE_KEY_PASSWORD='fixture',
                        FIXTURE_KEYSTORE_FILE='fixture', FIXTURE_KEY_ALIAS='fixture')
        for name in ('GRADLE_EXTRA_ARGS', 'ANDROID_SERIAL', 'ANDROID_AVD', 'ANDROID_EMULATOR_OPTIONS',
                     'ANDROID_EMULATOR_PORT', 'ANDROID_AVD_HOME'):
            self.env.pop(name, None)

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def devices(self, devices):
        self.env['TEST_ADB_DEVICES'] = json.dumps(devices)

    def run_script(self, name='test-android-device.sh', *args):
        return subprocess.run(['bash', str(self.root / 'scripts' / name), *args], env=self.env,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def calls(self, kind=None):
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [c for c in calls if kind is None or c[0] == kind]

    def test_full_device_suite_runs_on_the_only_emulator_without_signing_credentials(self):
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        [call] = self.calls('gradle')
        self.assertEqual('emulator-5554', call[1])
        self.assertEqual([], call[2])
        self.assertIn(':app:connectedDebugAndroidTest', call)
        self.assertIn('--no-daemon', call)

    def test_device_failure_is_not_hidden(self):
        self.env['TEST_GRADLE_FAIL_TASK'] = ':app:connectedDebugAndroidTest'
        self.assertEqual(31, self.run_script().returncode)

    def test_no_device_stops_without_tests(self):
        self.devices({})
        result = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('ANDROID_AVD', result.stderr)
        self.assertEqual([], self.calls('gradle'))

    def test_several_devices_need_a_choice(self):
        self.devices({'emulator-5554': {'qemu': '1'}, 'PHONE1': {}})
        result = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('ANDROID_SERIAL', result.stderr)
        self.assertEqual([], self.calls('gradle'))

    def test_a_lone_phone_is_not_used_without_confirmation(self):
        self.devices({'PHONE1': {'model': 'Test Phone'}})
        result = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('ANDROID_SERIAL=PHONE1', result.stderr)
        self.assertEqual([], self.calls('gradle'))

    def test_a_phone_named_in_android_serial_is_used(self):
        self.devices({'emulator-5554': {'qemu': '1'}, 'PHONE1': {}})
        self.env['ANDROID_SERIAL'] = 'PHONE1'
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual('PHONE1', self.calls('gradle')[0][1])

    def test_android_serial_must_be_connected(self):
        self.env['ANDROID_SERIAL'] = 'MISSING'
        result = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], self.calls('gradle'))

    def test_android_avd_starts_a_headless_emulator_beside_a_phone_and_stops_it(self):
        self.devices({'emulator-5554': {'qemu': '1', 'avd': 'other'}, 'PHONE1': {}})
        self.env['ANDROID_AVD'] = 'framenova'
        self.env['ANDROID_EMULATOR_OPTIONS'] = '-gpu swiftshader_indirect'
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        [start] = self.calls('emulator')
        self.assertEqual('framenova', start[start.index('-avd') + 1])
        self.assertEqual('5556', start[start.index('-port') + 1])  # 5554 is taken
        self.assertIn('-no-window', start)
        self.assertIn('swiftshader_indirect', start)
        self.assertEqual('emulator-5556', self.calls('gradle')[0][1])
        calls = self.calls()
        kill = calls.index(['adb', '-s', 'emulator-5556', 'emu', 'kill'])
        self.assertLess(next(i for i, c in enumerate(calls) if c[0] == 'gradle'), kill)

    def test_android_emulator_port_selects_the_port(self):
        self.devices({})
        self.env.update(ANDROID_AVD='framenova', ANDROID_EMULATOR_PORT='5560')
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual('emulator-5560', self.calls('gradle')[0][1])

    def test_busy_android_emulator_port_stops_before_starting(self):
        self.env.update(ANDROID_AVD='framenova', ANDROID_EMULATOR_PORT='5554')
        result = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], self.calls('emulator'))

    def test_started_emulator_is_stopped_after_failed_tests(self):
        self.devices({})
        self.env['ANDROID_AVD'] = 'framenova'
        self.env['TEST_GRADLE_FAIL_TASK'] = ':app:connectedDebugAndroidTest'
        self.assertEqual(31, self.run_script().returncode)
        self.assertIn(['adb', '-s', 'emulator-5554', 'emu', 'kill'], self.calls())

    def test_running_android_avd_is_reused_and_left_running(self):
        self.devices({'emulator-5554': {'qemu': '1', 'avd': 'other'}, 'emulator-5556': {'qemu': '1', 'avd': 'framenova'}})
        self.env['ANDROID_AVD'] = 'framenova'
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual([], self.calls('emulator'))
        self.assertEqual('emulator-5556', self.calls('gradle')[0][1])
        self.assertFalse(any('kill' in c for c in self.calls('adb')))

    def settings(self, text):
        with (self.root / 'scripts/release-settings.sh').open('a') as f:
            f.write(text)

    def test_settings_choose_the_device_task_and_name_what_it_removes(self):
        self.settings("device_test_task=:app:connectedQaAndroidTest\ndevice_test_app='the QA app'\n")
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        [call] = self.calls('gradle')
        self.assertIn(':app:connectedQaAndroidTest', call)
        self.assertNotIn(':app:connectedDebugAndroidTest', call)
        self.assertIn('They remove the QA app afterwards.', result.stdout)

    HOOKS = """prepare_test_device() { "$1" -s "$2" shell hook-prepare; [ -z "${TEST_PREPARE_FAIL:-}" ]; }
restore_test_device() { "$1" -s "$2" shell hook-restore; }
"""

    def hook_order(self):
        return [c[-1] if c[0] == 'adb' else 'gradle' for c in self.calls()
                if c[0] == 'gradle' or c[-1] in ('hook-prepare', 'hook-restore') or c[-1] == 'kill']

    def test_device_is_prepared_before_the_tests_and_restored_before_the_emulator_stops(self):
        self.settings(self.HOOKS)
        self.devices({})
        self.env['ANDROID_AVD'] = 'framenova'
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(['hook-prepare', 'gradle', 'hook-restore', 'kill'], self.hook_order())
        self.assertIn(['adb', '-s', 'emulator-5554', 'shell', 'hook-prepare'], self.calls())

    def test_device_is_restored_after_failed_tests(self):
        self.settings(self.HOOKS)
        self.env['TEST_GRADLE_FAIL_TASK'] = ':app:connectedDebugAndroidTest'
        self.assertEqual(31, self.run_script().returncode)
        self.assertEqual(['hook-prepare', 'gradle', 'hook-restore'], self.hook_order())

    def test_failed_preparation_stops_before_the_tests_and_is_still_undone(self):
        self.settings(self.HOOKS)
        self.env['TEST_PREPARE_FAIL'] = '1'
        result = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(['hook-prepare', 'hook-restore'], self.hook_order())

    def test_no_device_means_nothing_to_restore(self):
        self.settings(self.HOOKS)
        self.devices({})
        self.assertNotEqual(0, self.run_script().returncode)
        self.assertEqual([], self.hook_order())

    def test_release_checks_run_unit_tests_and_lint_before_device_tests(self):
        result = self.run_script('test-android-release.sh')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        first, device = self.calls('gradle')
        self.assertIn(':app:testDebugUnitTest', first)
        self.assertIn(':app:lintRelease', first)
        self.assertNotIn(':app:lintPlayRelease', first)
        self.assertEqual([], first[2])
        self.assertIn(':app:connectedDebugAndroidTest', device)

    def test_release_checks_lint_the_play_variant_with_play(self):
        result = self.run_script('test-android-release.sh', '--play')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn(':app:lintPlayRelease', self.calls('gradle')[0])

    def test_unit_test_failure_stops_before_device_tests(self):
        self.env['TEST_GRADLE_FAIL_TASK'] = ':app:testDebugUnitTest'
        self.assertEqual(31, self.run_script('test-android-release.sh').returncode)
        self.assertEqual(1, len(self.calls('gradle')))


if __name__ == '__main__':
    unittest.main()
