"""A disposable, loopback-only Jellyfin HTTPS fixture for Apple TV integration tests."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import ssl
import subprocess
from urllib.parse import parse_qs, urlsplit


ACCOUNT = {"AccessToken": "fixture-jellyfin-token", "User": {"Id": "fixture-user", "Name": "Fixture"}}
LIBRARY = {"Id": "fixture-library", "Name": "Fixture Movies", "Type": "CollectionFolder"}
MOVIE = {"Id": "fixture-movie", "Name": "Fixture Film", "Type": "Movie", "OfficialRating": "G"}
MEDIA = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures" / "playback.mp4"


class Handler(BaseHTTPRequestHandler):
    def send_body(self, status, body=b"", headers=()):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # AVPlayer may cancel a request during a seek.
            pass

    def send_json(self, value):
        self.send_body(200, json.dumps(value).encode(), [("Content-Type", "application/json")])

    def authorized(self):
        if 'Token="fixture-jellyfin-token"' in self.headers.get("Authorization", ""):
            return True
        self.send_body(401)
        return False

    def do_POST(self):
        path = urlsplit(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= 65536:
            self.send_body(413)
            return
        data = json.loads(self.rfile.read(length)) if length else {}
        if path == "/jellyfin/Users/AuthenticateByName":
            if data == {"Username": "fixture", "Pw": "fixture-only"}:
                self.send_json(ACCOUNT)
            else:
                self.send_body(401)
            return
        if not self.authorized():
            return
        if path == "/jellyfin/Items/fixture-movie/PlaybackInfo" and data.get("UserId") == "fixture-user":
            self.send_json({"PlaySessionId": "fixture-playback", "MediaSources": [
                {"Id": "fixture-media-source", "SupportsDirectPlay": True},
            ]})
        elif path in {"/jellyfin/Sessions/Playing", "/jellyfin/Sessions/Playing/Progress",
                      "/jellyfin/Sessions/Playing/Stopped", "/jellyfin/Sessions/Logout"}:
            self.send_body(204)
        else:
            self.send_body(404)

    def do_GET(self):
        parts = urlsplit(self.path)
        query = parse_qs(parts.query)
        if parts.path == "/health":
            self.send_body(200, b"ready")
            return
        if not self.authorized():
            return
        if parts.path == "/jellyfin/UserViews" and query.get("userId") == ["fixture-user"]:
            self.send_json({"Items": [LIBRARY], "StartIndex": 0, "TotalRecordCount": 1})
        elif (parts.path == "/jellyfin/Items" and query.get("parentId") == ["fixture-library"]
              and query.get("enableUserData") == ["false"]):
            self.send_json({"Items": [MOVIE], "StartIndex": 0, "TotalRecordCount": 1})
        elif (parts.path == "/jellyfin/Videos/fixture-movie/stream" and query.get("static") == ["true"]
              and query.get("playSessionId") == ["fixture-playback"]):
            self.send_range()
        else:
            self.send_body(404)

    def send_range(self):
        total = MEDIA.stat().st_size
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if match is None:
            self.send_body(416)
            return
        first, last = (int(value) for value in match.groups())
        if not 0 <= first <= last < total or last - first >= 8 * 1024 * 1024:
            self.send_body(416)
            return
        with MEDIA.open("rb") as media:
            media.seek(first)
            body = media.read(last - first + 1)
        self.send_body(206, body, [
            ("Content-Type", "video/mp4"),
            ("Content-Range", f"bytes {first}-{last}/{total}"),
            ("Accept-Ranges", "bytes"),
        ])


def certificate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    configuration = directory / "openssl.cnf"
    configuration.write_text("""
[req]
distinguished_name = subject
prompt = no
x509_extensions = extensions
[subject]
CN = Disposable MediaVault Jellyfin
[extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1
""", encoding="utf-8")
    cert, key = directory / "fixture.pem", directory / "fixture-key.pem"
    subprocess.run(
        ["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-sha256", "-days", "1",
         "-config", str(configuration), "-keyout", str(key), "-out", str(cert)],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["openssl", "x509", "-in", str(cert), "-outform", "DER", "-out", str(directory / "fixture.cer")],
        check=True,
    )
    return cert, key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    cert, key = certificate(args.directory)
    with ThreadingHTTPServer(("127.0.0.1", 18896), Handler) as server:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
