"""Disposable HTTPS companion for local Apple TV pairing and playback tests."""

import argparse
from dataclasses import dataclass
import hmac
from http.server import BaseHTTPRequestHandler
import json
from pathlib import Path
import re
import secrets
import ssl
import threading
import time
from urllib.parse import urlsplit

from webdav_fixture import TLSFixtureServer, create_certificate

PORT = 18477
PAIRING_CODE = "AB23-CD45"
PAIRING_LIFETIME = 120
PAIRING_PATH = re.compile(r"/v1/pairings/([A-Za-z0-9_-]{24})")
FILE_PATH = re.compile(r"/v1/files/([A-Za-z0-9_-]{1,256})")
BYTE_RANGE = re.compile(r"bytes=([0-9]{1,19})-([0-9]{1,19})")
FIXTURES = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures"


@dataclass
class Pairing:
    secret: str
    expires_at: float
    polls: int = 0
    connection: str | None = None


@dataclass(frozen=True)
class SelectedFile:
    name: str
    mime_type: str
    data: bytes


class FixtureServer(TLSFixtureServer):
    handshake_log_tag = "drive-companion-tls"

    def __init__(self, port, *, ssl_context):
        self.lock = threading.Lock()
        self.pairings: dict[str, Pairing] = {}
        self.connections: set[str] = set()
        self.files = {
            "fixture-drive-clip": SelectedFile(
                "Drive Fixture Clip.mp4", "video/mp4", (FIXTURES / "playback.mp4").read_bytes(),
            ),
            "fixture-drive-caption": SelectedFile(
                "Drive Fixture Clip.en.srt", "application/x-subrip",
                b"1\n00:00:00,500 --> 00:00:05,000\nGoogle Drive fixture caption.\n",
            ),
        }
        super().__init__(("127.0.0.1", port), Handler, ssl_context=ssl_context)
        self.origin = f"https://127.0.0.1:{self.server_port}"

    def catalog(self):
        return [
            {"id": key, "name": file.name, "size": len(file.data), "mimeType": file.mime_type,
             "parentId": "fixture-drive-folder"}
            for key, file in self.files.items()
        ]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        # Never retain URLs, request bodies, or Authorization headers.
        return

    def send_body(self, status, data=b"", headers=()):
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            # AVPlayer can cancel an outstanding request during a seek.
            pass

    def send_json(self, status, value):
        self.send_body(status, json.dumps(value).encode("utf-8"), [("Content-Type", "application/json")])

    def bearer(self):
        authorization = self.headers.get("Authorization", "")
        return authorization.removeprefix("Bearer ") if authorization.startswith("Bearer ") else ""

    def do_POST(self):
        if self.path != "/v1/pairings":
            self.send_body(404)
            return
        length = self.headers.get("Content-Length", "")
        if not length.isascii() or not length.isdecimal() or len(length) > 3 or not 0 < int(length) <= 128:
            self.send_body(400)
            return
        try:
            body = json.loads(self.rfile.read(int(length)))
        except (ValueError, UnicodeError):
            self.send_body(400)
            return
        if body != {}:
            self.send_body(400)
            return
        identifier = secrets.token_urlsafe(18)
        pairing = Pairing(secrets.token_urlsafe(32), time.monotonic() + PAIRING_LIFETIME)
        with self.server.lock:
            self.server.pairings[identifier] = pairing
        self.send_json(201, {
            "id": identifier, "secret": pairing.secret, "verificationUrl": self.server.origin + "/pair",
            "code": PAIRING_CODE, "expiresIn": PAIRING_LIFETIME,
        })

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/health":
            self.send_body(204)
        elif path == "/pair":
            self.send_body(200, b"Disposable fixture. Test pairing approves automatically.",
                           [("Content-Type", "text/plain; charset=utf-8")])
        elif match := PAIRING_PATH.fullmatch(path):
            self.poll_pairing(match[1])
        elif path == "/v1/connection":
            if self.connection_is_active():
                self.send_json(200, {"files": self.server.catalog()})
        elif match := FILE_PATH.fullmatch(path):
            if self.connection_is_active():
                self.read_file(match[1])
        else:
            self.send_body(404)

    def do_DELETE(self):
        token = self.bearer()
        match = PAIRING_PATH.fullmatch(self.path)
        status = 404
        with self.server.lock:
            if self.path == "/v1/connection":
                status = 401
                if token in self.server.connections:
                    self.server.connections.remove(token)
                    status = 204
            elif match:
                pairing = self.server.pairings.get(match[1])
                if pairing and hmac.compare_digest(token.encode(), pairing.secret.encode()):
                    del self.server.pairings[match[1]]
                    status = 204
        self.send_body(status)

    def poll_pairing(self, identifier):
        token = self.bearer()
        response = {"status": "pending"}
        status = 200
        with self.server.lock:
            pairing = self.server.pairings.get(identifier)
            if not pairing or not hmac.compare_digest(token.encode(), pairing.secret.encode()):
                status = 404
            elif time.monotonic() >= pairing.expires_at:
                del self.server.pairings[identifier]
                status = 410
            else:
                pairing.polls += 1
                # Give the remote test time to observe the real code before approval.
                if pairing.polls > 2:
                    if pairing.connection is None:
                        pairing.connection = secrets.token_urlsafe(32)
                        self.server.connections.add(pairing.connection)
                    response = {"status": "approved", "connection": {
                        "token": pairing.connection, "files": self.server.catalog(),
                    }}
        if status == 200:
            self.send_json(status, response)
        else:
            self.send_body(status)

    def connection_is_active(self):
        with self.server.lock:
            if self.bearer() in self.server.connections:
                return True
        self.send_body(401)
        return False

    def read_file(self, identifier):
        selected = self.server.files.get(identifier)
        if selected is None:
            self.send_body(404)
            return
        headers = [("Content-Type", selected.mime_type), ("Accept-Ranges", "bytes")]
        requested = self.headers.get("Range")
        if requested is None:
            self.send_body(200, selected.data, headers)
            return
        bounds = BYTE_RANGE.fullmatch(requested)
        size = len(selected.data)
        if bounds:
            start, end = map(int, bounds.groups())
            if start <= end < size:
                headers.append(("Content-Range", f"bytes {start}-{end}/{size}"))
                self.send_body(206, selected.data[start:end + 1], headers)
                return
        self.send_body(416, headers=[("Content-Range", f"bytes */{size}")])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()
    certificate, key = create_certificate(args.directory, "Drive Companion")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    with FixtureServer(args.port, ssl_context=context) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
