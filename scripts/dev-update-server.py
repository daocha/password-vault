#!/usr/bin/env python3
"""Serves the debug update files to debug builds on the LAN. scripts/serve-dev-update.sh starts it.

Only GET and HEAD of the update files under /<secret>/ are answered, so anyone else on the network gets the same 404
for everything and cannot list or find the APK. The traffic is plain HTTP: the secret stops strangers finding the
files, not someone watching the network. A tampered update still fails, because Android checks its signature.
"""
import argparse
import hmac
import http.server
import os
import re
import shutil
import sys

FILES = re.compile(r"(?:latest\.json|PassVault-debug-[0-9]+\.(?:apk|SHA256SUMS))")
TYPES = {".json": "application/json", ".apk": "application/vnd.android.package-archive"}


def requested_file(path, secret, migrate):
    """The update file a request path names, or None. The path is compared as sent: nothing is decoded or joined."""
    path = path.split("?", 1)[0]
    parts = path.split("/")
    if len(parts) == 3 and parts[0] == "" and hmac.compare_digest(parts[1].encode(), secret.encode()):
        name = parts[2]
    elif migrate and len(parts) == 2 and parts[0] == "":
        # An installed build from before the secret asks here. It stops once that build has updated itself.
        name = parts[1]
    else:
        return None
    return name if FILES.fullmatch(name) else None


def handler(directory, secret, migrate):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "dev-update"
        sys_version = ""
        timeout = 30

        def answer(self, send_body):
            name = requested_file(self.path, secret, migrate)
            # Only a name found by listing the folder can open a file, so request text never becomes a path.
            with os.scandir(directory) as entries:
                path = next((entry.path for entry in entries if entry.name == name and entry.is_file()), None)
            try:
                source = open(path, "rb") if path else None
            except OSError:
                source = None
            if source is None:
                self.send_error(404)
                return
            with source:
                self.send_response(200)
                self.send_header("Content-Type", TYPES.get(os.path.splitext(name)[1], "text/plain"))
                self.send_header("Content-Length", str(os.fstat(source.fileno()).st_size))
                self.end_headers()
                if send_body:
                    shutil.copyfileobj(source, self.wfile, 64 * 1024)

        def do_GET(self):
            self.answer(True)

        def do_HEAD(self):
            self.answer(False)

        def log_request(self, code="-", size="-"):
            # Never the path: it holds the secret, and this log is a file on disk.
            name = requested_file(self.path, secret, migrate) or "-"
            sys.stderr.write(f"{self.client_address[0]} {self.command} {code} {name}\n")

        def log_error(self, format, *args):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--secret-file", required=True)
    parser.add_argument("--migrate", action="store_true")
    options = parser.parse_args()
    with open(options.secret_file) as file:
        secret = file.read().strip()
    if not re.fullmatch(r"[0-9a-f]{32}", secret):
        parser.error("the secret file does not hold a 32-digit hex secret")
    address = (options.host, options.port)
    http.server.ThreadingHTTPServer(address, handler(options.directory, secret, options.migrate)).serve_forever()


if __name__ == "__main__":
    main()
