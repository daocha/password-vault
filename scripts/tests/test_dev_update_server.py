"""The LAN update server: strangers find nothing, the app gets its files, and one command is safe to repeat.
Run: python3 -m unittest discover -s scripts/tests -v
"""
import http.client
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATH_TOKEN = "0123456789abcdef0123456789abcdef"
APK = "PassVault-debug-7.apk"


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Project:
    """A copy of the scripts with its own .env, secret and update files. Nothing touches the real ones."""

    def __init__(self, base):
        self.root = Path(base)
        (self.root / "scripts").mkdir()
        for name in ("serve-dev-update.sh", "dev-update-server.py"):
            shutil.copy(PROJECT / "scripts" / name, self.root / "scripts")
        self.updates = self.root / "android/dist/dev-update"
        self.updates.mkdir(parents=True)
        (self.updates / "latest.json").write_text('{"versionCode":7}\n')
        (self.updates / APK).write_bytes(b"apk-bytes")
        (self.updates / "PassVault-debug-7.SHA256SUMS").write_text("sum\n")
        (self.updates / "notes.txt").write_text("not an update file\n")
        (self.root / "android/dist/private.txt").write_text("outside the folder\n")
        self.port = free_port()
        (self.root / ".env").write_text(
            f"PASSVAULT_DEV_UPDATE_HOST=127.0.0.1\nPASSVAULT_DEV_UPDATE_PORT={self.port}\n")
        self.token_file = self.root / "secret"
        self.token_file.write_text(PATH_TOKEN + "\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("PASSVAULT_")}
        self.env["PASSVAULT_DEV_UPDATE_SECRET_FILE"] = str(self.token_file)

    def run(self, *arguments):
        return subprocess.run([self.root / "scripts/serve-dev-update.sh", *arguments], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def get(self, path, method="GET"):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.putrequest(method, path, skip_host=False)
            connection.endheaders()
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def pid(self):
        return int((self.root / "android/dist/dev-update-server.pid").read_text())


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dev-update-test-")
        self.addCleanup(self.temp.cleanup)
        self.project = Project(self.temp.name)
        self.addCleanup(self.project.run, "--stop")

    def start(self, *arguments):
        result = self.project.run(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_the_app_gets_its_files_under_the_secret_path(self):
        self.start()
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json"), (200, b'{"versionCode":7}\n'))
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/{APK}"), (200, b"apk-bytes"))
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/PassVault-debug-7.SHA256SUMS")[0], 200)
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/{APK}", "HEAD"), (200, b""))

    def test_strangers_find_nothing(self):
        self.start()
        for path in ("/", "/latest.json", f"/{APK}", f"/{PATH_TOKEN}", f"/{PATH_TOKEN}/", f"/{PATH_TOKEN[:-1]}0/latest.json",
                     f"/{PATH_TOKEN}/notes.txt", f"/{PATH_TOKEN}/../private.txt", f"/{PATH_TOKEN}/%2e%2e/private.txt",
                     f"/{PATH_TOKEN}//latest.json", f"/{PATH_TOKEN}/latest.json/x", "/../../etc/passwd"):
            status, body = self.project.get(path)
            self.assertEqual(status, 404, path)
            self.assertNotIn(PATH_TOKEN.encode(), body, path)
            self.assertNotIn(b"PassVault-debug", body, path)
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json", "POST")[0], 501)

    def test_the_secret_stays_out_of_output_log_and_command_line(self):
        result = self.start()
        self.project.get(f"/{PATH_TOKEN}/latest.json")
        self.project.get("/not-the-secret")
        time.sleep(0.2)
        log = (self.project.root / "android/dist/dev-update-server.log").read_text()
        command = subprocess.run(["ps", "-o", "command=", "-p", str(self.project.pid())],
                                 capture_output=True, text=True).stdout
        self.assertIn("latest.json", log)
        for text in (result.stdout, result.stderr, log, command, self.project.run("--status").stdout):
            self.assertNotIn(PATH_TOKEN, text)

    def test_running_it_again_is_safe(self):
        self.start()
        first = self.project.pid()
        again = self.start()
        self.assertIn("Already running", again.stdout)
        self.assertEqual(self.project.pid(), first)
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json")[0], 200)

    def test_a_new_build_is_served_without_a_restart(self):
        self.start()
        (self.project.updates / "latest.json").write_text('{"versionCode":8}\n')
        (self.project.updates / "PassVault-debug-8.apk").write_bytes(b"newer")
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json")[1], b'{"versionCode":8}\n')
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/PassVault-debug-8.apk")[1], b"newer")

    def test_status_and_stop(self):
        self.assertEqual(self.project.run("--status").returncode, 3)
        self.start()
        self.assertEqual(self.project.run("--status").returncode, 0)
        pid = self.project.pid()
        self.assertEqual(self.project.run("--stop").returncode, 0)
        self.assertEqual(self.project.run("--status").returncode, 3)
        with self.assertRaises(OSError):
            os.kill(pid, 0)
        self.assertEqual(self.project.run("--stop").returncode, 0)

    def test_migrate_answers_old_builds_until_the_plain_command_runs(self):
        self.start("--migrate")
        self.assertEqual(self.project.get("/latest.json")[0], 200)
        self.assertEqual(self.project.get(f"/{APK}")[1], b"apk-bytes")
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json")[0], 200)
        self.assertEqual(self.project.get("/")[0], 404)
        self.assertEqual(self.project.get("/notes.txt")[0], 404)
        self.start()
        self.assertEqual(self.project.get("/latest.json")[0], 404)
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json")[0], 200)

    def test_it_replaces_the_old_plain_server_for_this_folder(self):
        # Started by hand, so the command is what the old script ran: python3 -m http.server --bind ... --directory ...
        old = subprocess.Popen([sys.executable, "-m", "http.server", "--bind", "127.0.0.1", "--directory",
                                str(self.project.updates), str(self.project.port)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(old.wait)
        self.addCleanup(old.kill)
        self.wait_for_port()
        self.assertEqual(self.project.get("/latest.json")[0], 200)
        self.start()
        self.assertEqual(old.wait(timeout=5), old.returncode)
        self.assertEqual(self.project.get("/latest.json")[0], 404)
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json")[0], 200)

    def old_server(self, port):
        old = subprocess.Popen([sys.executable, "-m", "http.server", "--bind", "127.0.0.1", "--directory",
                                str(self.project.updates), str(port)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(old.wait)
        self.addCleanup(old.kill)
        for _ in range(40):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    return old
            time.sleep(0.1)
        self.fail("the old server did not start")

    def test_migrate_leaves_old_servers_on_other_ports_and_the_plain_command_stops_them(self):
        other_port = free_port()
        old = self.old_server(other_port)
        self.start("--migrate")
        self.assertIsNone(old.poll())
        self.assertIn("old server", self.project.run("--status").stdout)
        result = self.start()
        self.assertIn("Stopped an old server", result.stdout)
        self.assertEqual(old.wait(timeout=5), old.returncode)
        self.assertEqual(self.project.get(f"/{PATH_TOKEN}/latest.json")[0], 200)

    def test_stop_also_stops_old_servers(self):
        old = self.old_server(free_port())
        self.assertEqual(self.project.run("--stop").returncode, 0)
        self.assertEqual(old.wait(timeout=5), old.returncode)

    def test_a_server_for_another_folder_is_left_alone(self):
        other_folder = self.project.root / "other"
        other_folder.mkdir()
        other = subprocess.Popen([sys.executable, "-m", "http.server", "--bind", "127.0.0.1", "--directory",
                                  str(other_folder), str(free_port())],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        time.sleep(0.5)
        self.start()
        self.assertIsNone(other.poll())

    def test_it_never_stops_another_program_on_the_port(self):
        other = subprocess.Popen([sys.executable, "-m", "http.server", "--bind", "127.0.0.1", str(self.project.port)],
                                 cwd=self.temp.name, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        self.wait_for_port()
        result = self.project.run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("in use by another program", result.stderr)
        self.assertIsNone(other.poll())

    def test_a_stale_pid_file_cannot_stop_another_process(self):
        other = subprocess.Popen(["sleep", "30"])
        self.addCleanup(other.wait)
        self.addCleanup(other.kill)
        (self.project.root / "android/dist/dev-update-server.pid").write_text(f"{other.pid}\n")
        self.assertEqual(self.project.run("--stop").stdout, "Not running.\n")
        self.assertIsNone(other.poll())

    def test_it_explains_what_is_missing(self):
        (self.project.updates / "latest.json").unlink()
        self.assertIn("build the debug APK first", self.project.run().stderr)
        (self.project.updates / "latest.json").write_text("{}\n")
        self.project.token_file.unlink()
        self.assertIn("build the debug APK first", self.project.run().stderr)
        self.project.token_file.write_text("too short\n")
        result = self.project.run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("32-digit", result.stderr)

    def wait_for_port(self):
        for _ in range(40):
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", self.project.port)) == 0:
                    return
            time.sleep(0.1)
        self.fail("the server did not start")


if __name__ == "__main__":
    unittest.main()
