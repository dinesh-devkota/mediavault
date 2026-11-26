"""Loopback Microsoft device-code and Graph contract fixture for iPhone tests."""

import argparse
from http.server import BaseHTTPRequestHandler
from itertools import count
import json
from pathlib import Path
import re
import ssl
from threading import Lock
from urllib.parse import parse_qs, urlsplit

from webdav_fixture import TLSFixtureServer


PORT = 18897
CLIENT_ID = "15cf518d-e2a1-46b0-b260-34bb4dd6c758"
ACCESS = "iphone-fixture-onedrive-authorization"
REFRESH = "iphone-fixture-onedrive-refresh"
SAMPLE = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures" / "playback.mp4"
FILES = {
    "video": ("OneDrive Journey.mp4", SAMPLE.read_bytes()),
    "subtitle": ("OneDrive Journey.en.srt", b"1\n00:00:05,000 --> 00:00:11,000\nOneDrive fixture subtitle.\n"),
}


class Handler(BaseHTTPRequestHandler):
    codes = count(1)
    pending_codes = {}
    lock = Lock()

    def log_message(self, format, *args):
        # Request paths may contain synthetic signed-download parameters.
        pass

    def send_body(self, status, data=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, value, status=200):
        self.send_body(status, json.dumps(value).encode(), [("Content-Type", "application/json")])

    def do_POST(self):
        path = urlsplit(self.path).path
        size = int(self.headers.get("Content-Length", "0"))
        if not 1 <= size <= 4096 or self.headers.get("Authorization") is not None:
            self.send_body(400)
            return
        fields = parse_qs(self.rfile.read(size).decode())
        if fields.get("client_id") != [CLIENT_ID]:
            self.send_json({"error": "invalid_client"}, 400)
        elif path == "/auth/consumers/oauth2/v2.0/devicecode":
            if fields.get("scope") != ["https://graph.microsoft.com/Files.Read offline_access"]:
                self.send_json({"error": "invalid_scope"}, 400)
                return
            with self.lock:
                code = f"fixture-device-{next(self.codes)}"
                self.pending_codes[code] = True
            self.send_json({"user_code": "OD-PHONE", "verification_uri": "https://www.microsoft.com/link",
                            "device_code": code, "expires_in": 90, "interval": 3})
        elif path == "/auth/consumers/oauth2/v2.0/token":
            self.send_token(fields)
        else:
            self.send_body(404)

    def send_token(self, fields):
        grant = fields.get("grant_type")
        if grant == ["urn:ietf:params:oauth:grant-type:device_code"]:
            code = (fields.get("device_code") or [""])[0]
            with self.lock:
                pending = self.pending_codes.get(code)
                if pending is True:
                    self.pending_codes[code] = False
                elif pending is False:
                    del self.pending_codes[code]
            if pending is None or pending:
                self.send_json({"error": "authorization_pending" if pending else "expired_token"}, 400)
                return
        elif grant != ["refresh_token"] or fields.get("refresh_token") != [REFRESH]:
            self.send_json({"error": "invalid_grant"}, 400)
            return
        self.send_json({"access_token": ACCESS, "refresh_token": REFRESH, "expires_in": 3600})

    def do_GET(self):
        parts = urlsplit(self.path)
        path = parts.path
        if path == "/health":
            self.send_body(200, b"ready")
        elif path.startswith("/download/"):
            self.send_range(parts)
        elif self.headers.get("Authorization") != "Bearer " + ACCESS:
            self.send_body(401)
        elif path == "/graph/v1.0/me/drive":
            self.send_json({"id": "fixture-drive"})
        elif path == "/graph/v1.0/me/drive/root":
            self.send_json({"id": "fixture-root", "name": "OneDrive", "folder": {}})
        elif path == "/graph/v1.0/me/drive/items/fixture-root/children":
            self.send_json({"value": [
                {"id": "fixture-movies", "name": "Movies", "folder": {}},
                {"id": "fixture-empty", "name": "Empty", "folder": {}},
            ]})
        elif path == "/graph/v1.0/me/drive/items/fixture-movies/children":
            self.send_json({"value": [{"id": key, "name": name, "size": len(data), "file": {}}
                                      for key, (name, data) in FILES.items()]})
        elif path == "/graph/v1.0/me/drive/items/fixture-empty/children":
            self.send_json({"value": []})
        else:
            file = re.fullmatch(r"/graph/v1\.0/me/drive/items/(video|subtitle)", path)
            if file:
                self.send_json({"id": file[1], "@microsoft.graph.downloadUrl":
                                f"https://download.onedrive.invalid/{file[1]}?sig=fixture"})
            else:
                self.send_body(404)

    def send_range(self, parts):
        file_id = parts.path.removeprefix("/download/")
        if (file_id not in FILES or parse_qs(parts.query) != {"sig": ["fixture"]} or
                self.headers.get("Authorization") is not None):
            self.send_body(400)
            return
        name, data = FILES[file_id]
        request = re.fullmatch(r"bytes=(\d{1,19})-(\d{1,19})", self.headers.get("Range", ""))
        if not request or not self.headers.get("Accept-Encoding") == "identity":
            self.send_body(416)
            return
        start, end = map(int, request.groups())
        if not 0 <= start <= end < len(data):
            self.send_body(416, headers=[("Content-Range", f"bytes */{len(data)}")])
            return
        content_type = "video/mp4" if name.endswith(".mp4") else "application/x-subrip"
        self.send_body(206, data[start:end + 1], [
            ("Content-Type", content_type),
            ("Content-Range", f"bytes {start}-{end}/{len(data)}"),
            ("Accept-Ranges", "bytes"),
        ])


class OneDriveFixtureServer(TLSFixtureServer):
    handshake_log_tag = "onedrive-tls"


def main():
    arguments = argparse.ArgumentParser(description=__doc__)
    arguments.add_argument("certificates", type=Path, help="Disposable WebDAV fixture certificate directory")
    options = arguments.parse_args()
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(options.certificates / "fixture.pem", options.certificates / "fixture-key.pem")
    with OneDriveFixtureServer(("127.0.0.1", PORT), Handler, ssl_context=tls) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
