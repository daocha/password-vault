"""Exercise archive/export/upload with fake Apple tools; no signing or network."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class IOSAppStoreTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ios-store-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo with spaces'
        (self.root / 'scripts').mkdir(parents=True)
        (self.root / 'ios').mkdir()
        (self.root / 'android/app').mkdir(parents=True)
        for name in ('build-ios-app-store.sh', '_signing-common.sh'):
            shutil.copy(PROJECT / 'scripts' / name, self.root / 'scripts' / name)
        (self.root / 'scripts/release-settings.sh').write_text('''app_name=Fixture
app_id=example.fixture
env_prefix=FIXTURE
default_keystore=unused
default_key_alias=unused
default_lineage=unused
ios_scheme=Fixture
check_sources() { :; }
run_ios_tests() { swift test; }
''')
        (self.root / 'android/app/build.gradle.kts').write_text('versionName = "2026.11.1"\nversionCode = 8\n')
        self.bin = Path(self.temp.name) / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        DEVELOPMENT_TEAM='TEAM123456', TEST_IOS_LOG=str(self.log))
        for key in ('ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID'):
            self.env.pop(key, None)
        for name, body in [('uname', 'echo Darwin'), ('xcrun', 'echo "${TEST_SDK:-26.0}"'),
                           ('xcodegen', 'exit 0'), ('swift', 'exit 0')]:
            self.executable(self.bin / name, '#!/bin/bash\n' + body + '\n')
        self.executable(self.bin / 'xcodebuild', '''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
args = sys.argv[1:]
if args == ['-version']: print('Xcode 26.0'); sys.exit(0)
with open(os.environ['TEST_IOS_LOG'], 'a') as f: f.write(json.dumps(args) + '\\n')
def value(key): return args[args.index(key) + 1]
if args[0] == 'archive':
    archive = pathlib.Path(value('-archivePath')); archive.mkdir(parents=True)
    with open(archive / 'Info.plist', 'wb') as f:
        plistlib.dump({'ApplicationProperties': {'CFBundleIdentifier': 'example.fixture', 'Team': 'TEAM123456', 'CFBundleShortVersionString': '2026.11.1', 'CFBundleVersion': os.environ.get('TEST_ARCHIVE_CODE', '8')}}, f)
else:
    with open(value('-exportOptionsPlist'), 'rb') as f: options = plistlib.load(f)
    if options['destination'] == 'export':
        (pathlib.Path(value('-exportPath')) / 'Fixture.ipa').write_bytes(b'fixture')
''')

    @staticmethod
    def executable(path, source):
        path.write_text(source)
        path.chmod(0o755)

    def run_script(self, *args):
        return subprocess.run(['bash', 'scripts/build-ios-app-store.sh', *args], cwd=self.root,
                              env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def archive(self, bundle='example.fixture', team='TEAM123456'):
        path = self.root / 'existing archive.xcarchive'
        path.mkdir()
        with (path / 'Info.plist').open('wb') as f:
            plistlib.dump({'ApplicationProperties': {'CFBundleIdentifier': bundle, 'Team': team}}, f)
        return path

    def test_build_uses_shared_version_and_exports_without_upload(self):
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn('MARKETING_VERSION=2026.11.1', calls[0])
        self.assertIn('CURRENT_PROJECT_VERSION=8', calls[0])
        options = self.root / 'dist/Fixture-2026.11.1-8-app-store/ExportOptions.plist'
        with options.open('rb') as f: plist = plistlib.load(f)
        self.assertEqual('export', plist['destination'])
        self.assertEqual('app-store-connect', plist['method'])
        self.assertFalse(plist['manageAppVersionAndBuildNumber'])
        self.assertTrue((options.parent / 'Fixture.ipa').exists())

    def test_archive_version_mismatch_prevents_export(self):
        self.env['TEST_ARCHIVE_CODE'] = '1'
        result = self.run_script()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('version/build number', result.stderr)
        self.assertEqual(1, len(self.calls()))

    def test_upload_uses_existing_archive_without_building(self):
        archive = self.archive()
        result = self.run_script('--upload-archive', str(archive))
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        calls = self.calls()
        self.assertEqual(1, len(calls))
        self.assertEqual('-exportArchive', calls[0][0])
        self.assertIn(str(archive), calls[0])
        with open(calls[0][calls[0].index('-exportOptionsPlist') + 1], 'rb') as f:
            self.assertEqual('upload', plistlib.load(f)['destination'])

    def test_wrong_archive_identity_is_rejected_before_upload(self):
        for bundle, team in [('another.app', 'TEAM123456'), ('example.fixture', 'OTHER12345')]:
            with self.subTest(bundle=bundle, team=team):
                archive = self.archive(bundle, team)
                result = self.run_script('--upload-archive', str(archive))
                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], self.calls())
                shutil.rmtree(archive)

    def test_old_sdk_missing_team_and_partial_api_key_stop_early(self):
        for changes in ({'TEST_SDK': '18.0'}, {'DEVELOPMENT_TEAM': ''}, {'ASC_KEY_ID': 'incomplete'}):
            with self.subTest(changes=changes):
                previous = self.env.copy()
                self.env.update(changes)
                self.assertNotEqual(0, self.run_script().returncode)
                self.assertEqual([], self.calls())
                self.env = previous

    def test_team_api_key_is_passed_to_archive_and_export(self):
        key = self.root / 'test key.p8'
        key.write_text('test fixture only')
        self.env.update(ASC_KEY_PATH=str(key), ASC_KEY_ID='KEY123', ASC_ISSUER_ID='test-issuer')
        result = self.run_script('--skip-tests')
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        for call in self.calls():
            self.assertEqual(str(key), call[call.index('-authenticationKeyPath') + 1])
            self.assertEqual('KEY123', call[call.index('-authenticationKeyID') + 1])
            self.assertEqual('test-issuer', call[call.index('-authenticationKeyIssuerID') + 1])

    def test_preflight_does_not_archive_or_export(self):
        result = self.run_script('--check')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse((self.root / 'dist').exists())
        self.assertEqual([], self.calls())


if __name__ == '__main__':
    unittest.main()
