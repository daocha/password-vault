"""Exercise release orchestration in isolated repos; network/signing are stubbed.
The real signing path is validated separately with release-github.sh --dry-run.
The same file runs in PassVault and AquaRestore; the app name comes from scripts/release-settings.sh.
Run: python3 -m unittest discover -s scripts/tests -v
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
REAL_GIT = shutil.which("git")
APP = re.search(r"^app_name=(\w+)$", (PROJECT / "scripts/release-settings.sh").read_text(), re.M).group(1)

# Stand-ins for the build scripts: they write the artifacts the real ones would, named from the version in Gradle.
STUB_BUILD = '''#!/usr/bin/env python3
import pathlib, re
root = pathlib.Path(__file__).resolve().parents[1]
s = (root / 'android/app/build.gradle.kts').read_text()
v = re.search(r'versionName = "([^"]+)"', s).group(1)
c = re.search(r'versionCode = (\\d+)', s).group(1)
(root / 'dist').mkdir(exist_ok=True)
for suffix in SUFFIXES:
    (root / 'dist' / f'APP-{v}-{c}{suffix}').write_bytes(b'workflow test only')
'''.replace('APP', APP)


class ReleaseWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-workflow-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo with spaces"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "android/app").mkdir(parents=True)
        for name in ("release-github.sh", "_signing-common.sh", "release-settings.sh"):
            shutil.copy(PROJECT / "scripts" / name, self.repo / "scripts" / name)
        (self.repo / ".gitignore").write_text("dist/\n")
        (self.repo / "android/app/build.gradle.kts").write_text('        versionCode = 1\n        versionName = "1.0.0"\n')
        self.log = self.base / "calls.jsonl"
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.executable(self.bin / "gh", '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['TEST_RELEASE_LOG'], 'a') as f: f.write(json.dumps(['gh'] + args) + '\\n')
if args[:1] == ['api'] and 'matching-refs' in args[1]:
    if os.environ.get('TEST_EXISTING_TAG'): print('refs/tags/' + os.environ['TEST_EXISTING_TAG'])
if args[:2] == ['release', 'create'] and os.environ.get('TEST_UPLOAD_FAIL'): sys.exit(1)
if args[:2] == ['release', 'view']: print('https://github.com/example/app/releases/tag/v1.0.0')
''')
        self.executable(self.bin / "git", '''#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] == ['push']:
    with open(os.environ['TEST_RELEASE_LOG'], 'a') as f: f.write(json.dumps(['git'] + sys.argv[1:]) + '\\n')
    sys.exit(1 if os.environ.get('TEST_PUSH_FAIL') else 0)
os.execv(os.environ['TEST_REAL_GIT'], [os.environ['TEST_REAL_GIT']] + sys.argv[1:])
''')
        self.executable(self.repo / "scripts/build-android-release.sh",
                        STUB_BUILD.replace('SUFFIXES', "['.apk', '.SHA256SUMS']"))
        self.executable(self.repo / "scripts/build-android-play.sh",
                        STUB_BUILD.replace('SUFFIXES', "['-play.aab', '-play-mapping.txt']"))
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"], TEST_RELEASE_LOG=str(self.log), TEST_REAL_GIT=REAL_GIT)
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial fixture")
        self.git("remote", "add", "origin", "git@github.com:example/app.git")

    @staticmethod
    def executable(path, source):
        path.write_text(source)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output([REAL_GIT, *args], cwd=self.repo, text=True).strip()

    def run_release(self, *args):
        return subprocess.run(["bash", "scripts/release-github.sh", *args], cwd=self.repo,
                              env=self.env, capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_version_bump_sign_publish_order_and_assets(self):
        result = self.run_release("--version", "1.1.0")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertIn('versionCode = 2', (self.repo / 'android/app/build.gradle.kts').read_text())
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.git('rev-list', '-n1', 'v1.1.0'))
        calls = self.calls()
        push = next(i for i, c in enumerate(calls) if c[:2] == ['git', 'push'])
        create = next(i for i, c in enumerate(calls) if c[:3] == ['gh', 'release', 'create'])
        publish = next(i for i, c in enumerate(calls) if c[:3] == ['gh', 'release', 'edit'])
        self.assertLess(push, create)
        self.assertLess(create, publish)
        self.assertIn('--atomic', calls[push])
        self.assertIn('--draft', calls[create])
        self.assertTrue(any(x.endswith(f'{APP}-1.1.0-2.apk') for x in calls[create]))
        self.assertTrue(any(x.endswith('.SHA256SUMS') for x in calls[create]))
        self.assertIn('--draft=false', calls[publish])

    def test_play_bundle_matches_the_release_and_stays_off_github(self):
        result = self.run_release("--version", "1.1.0", "--play")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue((self.repo / f'dist/{APP}-1.1.0-2-play.aab').exists())
        self.assertIn(f'{APP}-1.1.0-2-play.aab', result.stdout)
        create = next(c for c in self.calls() if c[:3] == ['gh', 'release', 'create'])
        self.assertFalse(any(x.endswith('.aab') or x.endswith('mapping.txt') for x in create))

    def test_dry_run_never_writes_git_or_calls_github(self):
        before = self.git('rev-parse', 'HEAD')
        result = self.run_release('--dry-run')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(before, self.git('rev-parse', 'HEAD'))
        self.assertEqual('', self.git('tag'))
        self.assertEqual([], self.calls())

    def test_uncommitted_change_stops_before_build_or_push(self):
        (self.repo / '.gitignore').write_text('dist/\nwork in progress\n')
        result = self.run_release()
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.repo / 'dist').exists())
        self.assertFalse(any(c[:2] == ['git', 'push'] for c in self.calls()))

    def test_untracked_file_in_the_build_stops_the_release(self):
        (self.repo / 'android/app/Extra.kt').write_text('// not committed')
        result = self.run_release()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('android/app/Extra.kt', result.stderr)
        self.assertFalse((self.repo / 'dist').exists())

    def test_untracked_file_outside_the_build_is_allowed(self):
        (self.repo / 'release-notes-draft.md').write_text('notes')
        result = self.run_release()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue(any(c[:3] == ['gh', 'release', 'create'] for c in self.calls()))

    def test_existing_remote_tag_is_never_overwritten(self):
        self.env['TEST_EXISTING_TAG'] = 'v1.0.0'
        result = self.run_release()
        self.assertNotEqual(0, result.returncode)
        self.assertIn('never overwritten', result.stderr)
        self.assertFalse((self.repo / 'dist').exists())

    def test_refused_push_removes_the_tag_and_publishes_nothing(self):
        self.env['TEST_PUSH_FAIL'] = '1'
        result = self.run_release("--version", "1.1.0")
        self.assertNotEqual(0, result.returncode)
        self.assertIn('pull request', result.stderr)
        self.assertEqual('', self.git('tag'))
        self.assertFalse(any(c[:2] == ['gh', 'release'] for c in self.calls()))

    def test_upload_failure_does_not_publish(self):
        self.env['TEST_UPLOAD_FAIL'] = '1'
        result = self.run_release()
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(any(c[:3] == ['gh', 'release', 'edit'] for c in self.calls()))

    def test_draft_stays_unpublished(self):
        result = self.run_release('--draft')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(any(c[:3] == ['gh', 'release', 'edit'] for c in self.calls()))


if __name__ == '__main__':
    unittest.main()
