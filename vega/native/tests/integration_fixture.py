"""Run native tests against synthetic loopback SMB and strict local TLS servers.

Requires scripts/nas-test-requirements.txt, ffmpeg and openssl. No user shares,
credentials or system trust store are used. Generated keys stay in the ignored
build directory and are trusted only by the host integration test executable.
"""
import base64
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse


REPOSITORY = Path(__file__).resolve().parents[3]
PAYLOAD = b"0123456789abcdef"


def prepare(folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    if (folder / "tls-ready").exists():
        return

    def openssl(*args: str) -> None:
        subprocess.run(["openssl", *args], cwd=folder, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-subj", "/CN=MediaVault synthetic test CA", "-keyout", "ca.key", "-out", "ca.pem")
    for name, host in (("server", "localhost"), ("wrong-host", "wrong.fixture.invalid")):
        openssl("req", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={host}",
                "-keyout", f"{name}.key", "-out", f"{name}.csr")
        (folder / f"{name}.ext").write_text(
            f"subjectAltName=DNS:{host}\nbasicConstraints=CA:FALSE\n"
            "keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n", encoding="ascii")
        openssl("x509", "-req", "-in", f"{name}.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                "-CAcreateserial", "-days", "2", "-extfile", f"{name}.ext", "-out", f"{name}.pem")
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", "untrusted.key", "-out", "untrusted.pem")
    (folder / "tls-ready").write_text("synthetic TLS fixture only\n", encoding="ascii")


class FixtureServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve_tls(folder: Path, certificate: str, audit: Path, marker: Path, capture=False):
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def reply(self, status, body=b"", headers=None):
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            self.close_connection = True

        def handle_request(self):
            parsed = urllib.parse.urlsplit(self.path)
            path = urllib.parse.unquote(parsed.path)
            with lock, audit.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"capture": capture, "path": path,
                    "authorization": bool(self.headers.get("Authorization")),
                    "token": bool(self.headers.get("X-Emby-Token"))}) + "\n")
            if capture:
                return self.reply(200, b"redirect capture must never receive credentials")
            basic = "Basic " + base64.b64encode(b"cinevault:fixture-only").decode("ascii")
            if self.headers.get("Authorization") != basic and self.headers.get("X-Emby-Token") != "fixture-token":
                return self.reply(401, b"fixture sign-in required")
            if path.startswith("/media/redirect"):
                scheme = "http" if path.endswith("-http") else "https"
                return self.reply(302, headers={"Location": f"{scheme}://localhost:{self.server.capture_port}/capture"})
            if path == "/media/oversized":
                return self.reply(200, b"a" * 65536)
            if path == "/media/oversized-headers":
                return self.reply(200, b"", {"X-Too-Large": "a" * 40000})
            if path == "/media/conflicting-headers":
                self.send_response(206)
                self.send_header("Content-Length", "2")
                self.send_header("Content-Range", "bytes 0-1/16")
                self.send_header("Content-Range", "bytes 8-9/16")
                self.end_headers()
                self.wfile.write(b"01")
                self.close_connection = True
                return
            if path == "/media/profile-expired":
                marker.write_text("profile changed during request\n", encoding="ascii")
                return self.reply(200, PAYLOAD)
            if path == "/media/bytes.bin":
                value = self.headers.get("Range")
                if value:
                    try:
                        left, right = value.removeprefix("bytes=").split("-")
                        start, end = int(left), min(int(right), len(PAYLOAD) - 1)
                        if not value.startswith("bytes=") or start < 0 or start > end:
                            raise ValueError("invalid range")
                    except ValueError:
                        return self.reply(416, headers={"Content-Range": "bytes */16"})
                    return self.reply(206, PAYLOAD[start:end + 1],
                                      {"Content-Range": f"bytes {start}-{end}/16", "Content-Type": "application/octet-stream"})
                return self.reply(200, PAYLOAD, {"Content-Type": "application/octet-stream"})
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            return self.reply(200, json.dumps({"path": path, "query": urllib.parse.parse_qs(parsed.query),
                "method": self.command, "body": body.decode("utf-8")}).encode("utf-8"), {"Content-Type": "application/json"})

        def do_GET(self):
            try:
                self.handle_request()
            except (ConnectionResetError, BrokenPipeError, ssl.SSLError):
                pass  # Client cancellation/limits deliberately close these fixture responses.

        do_HEAD = do_GET
        do_POST = do_GET
        do_PROPFIND = do_GET

    server = FixtureServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(folder / f"{certificate}.pem", folder / f"{certificate}.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def run(build: Path) -> int:
    folder = build / "fixture"
    prepare(folder)
    root = folder / "nas"
    native = root / "NativeChecks"
    unicode = native / "Été 日本語"
    unicode.mkdir(parents=True, exist_ok=True)
    (unicode / "Amélie #1 & famille.bin").write_bytes(b"unicode-fixture\r\n")
    (native / "pattern.bin").write_bytes(bytes(n % 251 for n in range(1024 * 1024 + 13)))
    audit = folder / "http-audit.jsonl"
    audit.write_text("", encoding="utf-8")
    marker = folder / "profile-expired"
    marker.unlink(missing_ok=True)
    # Fail rather than accidentally testing against an unrelated running NAS.
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 1445))
    servers = []
    with (folder / "nas.log").open("w", encoding="utf-8") as log:
        nas = subprocess.Popen([sys.executable, str(REPOSITORY / "scripts/nas_fixture.py"), str(root)],
                               stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 90
            while True:
                if nas.poll() is not None:
                    raise RuntimeError("Synthetic NAS exited; inspect fixture/nas.log")
                try:
                    with socket.create_connection(("127.0.0.1", 1445), timeout=0.2):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Synthetic NAS did not start")
                    time.sleep(0.1)
            capture = serve_tls(folder, "server", audit, marker, capture=True)
            servers.append(capture)
            for certificate in ("server", "wrong-host", "untrusted"):
                server = serve_tls(folder, certificate, audit, marker)
                server.capture_port = capture.server_port
                servers.append(server)
            environment = dict(os.environ, MEDIAVAULT_TEST_SMB="smb://127.0.0.1:1445/CINEVAULT",
                MEDIAVAULT_TEST_HTTPS=f"https://localhost:{servers[1].server_port}/media",
                MEDIAVAULT_TEST_WRONG_HOST=f"https://localhost:{servers[2].server_port}/media",
                MEDIAVAULT_TEST_UNTRUSTED=f"https://localhost:{servers[3].server_port}/media",
                MEDIAVAULT_TEST_HTTP_AUDIT=str(audit), MEDIAVAULT_TEST_PROFILE_MARKER=str(marker))
            return subprocess.run(["ctest", "--test-dir", str(build), "--parallel", "1", "--output-on-failure",
                "--output-junit", str(build / "integration-results.xml")], env=environment, check=False).returncode
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
            nas.terminate()
            try:
                nas.wait(timeout=10)
            except subprocess.TimeoutExpired:
                nas.kill()
                nas.wait()


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("prepare", "run"):
        raise SystemExit("Usage: integration_fixture.py prepare <fixture-dir> | run <cmake-build-dir>")
    path = Path(sys.argv[2]).resolve()
    if sys.argv[1] == "prepare":
        prepare(path)
    else:
        raise SystemExit(run(path))
