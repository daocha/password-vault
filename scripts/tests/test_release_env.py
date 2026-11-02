"""Apple release dotenv loading without executing configuration or exposing secrets."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
KEYS = ('DEVELOPMENT_TEAM', 'ASC_KEY_PATH', 'ASC_KEY_ID', 'ASC_ISSUER_ID')


class ReleaseEnvTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='release-env-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo with spaces'
        (self.root / 'scripts').mkdir(parents=True)
        shutil.copy(PROJECT / 'scripts/_signing-common.sh', self.root / 'scripts')
        (self.root / 'scripts/release-settings.sh').write_text('''env_prefix=FIXTURE
default_keystore=unused
default_key_alias=unused
default_lineage=unused
''')
        self.env = os.environ.copy()
        for key in KEYS:
            self.env.pop(key, None)

    def run_loader(self):
        command = '''set -eu
. "$1"
load_app_store_env
python3 -c 'import json, os; print(json.dumps({k: os.environ.get(k) for k in ("DEVELOPMENT_TEAM", "ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")}))'
'''
        return subprocess.run(['bash', '-c', command, 'test', str(self.root / 'scripts/_signing-common.sh')],
                              cwd=self.temp.name, env=self.env, capture_output=True, text=True)

    def values(self):
        result = self.run_loader()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('', result.stderr)
        return json.loads(result.stdout)

    def test_missing_files_are_optional(self):
        self.assertEqual(dict.fromkeys(KEYS), self.values())
        self.env['DEVELOPMENT_TEAM'] = 'TEAM123456'
        self.assertEqual('TEAM123456', self.values()['DEVELOPMENT_TEAM'])

    def test_root_file_supports_quotes_export_comments_crlf_and_no_final_newline(self):
        (self.root / '.env').write_bytes(b'# local settings\r\n\r\n export DEVELOPMENT_TEAM = "TEAM123456" # comment\r\nASC_KEY_ID=KEY123 # comment\r\nASC_ISSUER_ID=\'test issuer\'\r\nASC_KEY_PATH="/tmp/key with spaces.p8"')
        self.assertEqual(dict(DEVELOPMENT_TEAM='TEAM123456', ASC_KEY_ID='KEY123',
                              ASC_ISSUER_ID='test issuer', ASC_KEY_PATH='/tmp/key with spaces.p8'), self.values())

    def test_exported_environment_then_scripts_file_then_root_file(self):
        (self.root / '.env').write_text('DEVELOPMENT_TEAM=ROOT123456\nASC_KEY_ID=root-key\nASC_ISSUER_ID=root-issuer\n')
        (self.root / 'scripts/.env').write_text('DEVELOPMENT_TEAM=FILE123456\nASC_KEY_ID=scripts-key\n')
        self.env['DEVELOPMENT_TEAM'] = 'TEAM123456'
        values = self.values()
        self.assertEqual('TEAM123456', values['DEVELOPMENT_TEAM'])
        self.assertEqual('scripts-key', values['ASC_KEY_ID'])
        self.assertEqual('root-issuer', values['ASC_ISSUER_ID'])

    def test_explicit_empty_environment_is_preserved(self):
        (self.root / '.env').write_text('DEVELOPMENT_TEAM=TEAM123456\n')
        self.env['DEVELOPMENT_TEAM'] = ''
        self.assertEqual('', self.values()['DEVELOPMENT_TEAM'])

    def test_home_prefixes_expand_without_general_interpolation(self):
        for value in ('~/key.p8', '"$HOME/key.p8"', '"${HOME}/key.p8"'):
            with self.subTest(value=value):
                (self.root / '.env').write_text('ASC_KEY_PATH=' + value + '\n')
                self.assertEqual(str(Path(self.env['HOME']) / 'key.p8'), self.values()['ASC_KEY_PATH'])
        (self.root / '.env').write_text("ASC_KEY_PATH='$HOME/key.p8'\n")
        self.assertEqual('$HOME/key.p8', self.values()['ASC_KEY_PATH'])

    def test_configuration_is_not_executed(self):
        marker = Path(self.temp.name) / 'must-not-exist'
        for value in (f'$(touch {marker})', f'`touch {marker}`'):
            with self.subTest(value=value):
                (self.root / '.env').write_text('ASC_KEY_PATH=' + value + '\n')
                self.assertEqual(value, self.values()['ASC_KEY_PATH'])
                self.assertFalse(marker.exists())

    def test_unrelated_keys_are_ignored(self):
        (self.root / '.env').write_text('PATH=/does-not-exist\nLAN_HOST=example.invalid\nDEVELOPMENT_TEAM=TEAM123456\n')
        self.assertEqual('TEAM123456', self.values()['DEVELOPMENT_TEAM'])

    def test_invalid_line_reports_location_without_its_secret(self):
        (self.root / '.env').write_text('# comment\nprivate-secret-without-assignment\n')
        result = self.run_loader()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('line 2', result.stderr)
        self.assertNotIn('private-secret', result.stderr + result.stdout)

    def test_unclosed_quote_does_not_disclose_value(self):
        (self.root / '.env').write_text('ASC_KEY_ID="private-secret\n')
        result = self.run_loader()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('line 1', result.stderr)
        self.assertNotIn('private-secret', result.stderr + result.stdout)

    def test_directory_in_place_of_env_is_reported(self):
        (self.root / '.env').mkdir()
        result = self.run_loader()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('Cannot read Apple release settings', result.stderr)


if __name__ == '__main__':
    unittest.main()
