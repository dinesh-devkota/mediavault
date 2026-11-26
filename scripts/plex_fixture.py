"""Disposable Plex account and Media Server HTTPS fixture for simulator tests."""

import argparse
from http.server import BaseHTTPRequestHandler
import itertools
import json
from pathlib import Path
import re
import ssl
import subprocess
import threading
from urllib.parse import parse_qs, urlsplit

from webdav_fixture import TLSFixtureServer


PORT = 18777
SERVER_ID = "fixture-plex-server"
ACCOUNT_TOKEN = "fixture-plex-account-token"
SERVER_TOKEN = "fixture-plex-server-token"
SAMPLES = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures"
MOVIE_BYTES = SAMPLES / "playback.mp4"
JPEG_BYTES = SAMPLES / "Photos" / "01.jpg"
SUBTITLE = b"1\n00:00:07,000 --> 00:00:11,000\nFixture Plex caption.\n"
RANGE = re.compile(r"bytes=(\d{1,19})-(\d{1,19})")

LIBRARIES = [
    {"key": "10", "title": "Fixture Movies", "type": "movie"},
    {"key": "20", "title": "Fixture Shows", "type": "show"},
    {"key": "30", "title": "Fixture Photos", "type": "photo"},
]


def media_item(key, title, kind, section, **details):
    return {
        "ratingKey": key, "key": f"/library/metadata/{key}", "type": kind, "title": title,
        "librarySectionID": section, "summary": f"Description of {title}.",
        "thumb": f"/library/metadata/{key}/thumb/1", **details,
    }


def video_part(key):
    return [{
        "id": int(key), "container": "mp4", "videoCodec": "h264", "duration": 12000,
        "Part": [{"id": int(key), "key": f"/library/parts/{key}/1/file.mp4", "container": "mp4",
                  "size": MOVIE_BYTES.stat().st_size, "Stream": [
                      {"id": 1, "streamType": 3, "codec": "srt", "languageCode": "eng", "language": "English",
                       "title": "Fixture Plex caption", "key": "/library/streams/1"},
                  ]}],
    }]


def catalog():
    movie = media_item("101", "Fixture Movie", "movie", 10, year=2026, contentRating="G",
                       Media=video_part("101"))
    second_movie = media_item("102", "Second Fixture Movie", "movie", 10, year=2026,
                              contentRating="R", Media=video_part("102"))
    show = media_item("201", "Fixture Show", "show", 20, year=2026, contentRating="TV-G")
    season = media_item("202", "Fixture Season", "season", 20, index=1, parentRatingKey="201",
                        parentTitle=show["title"])
    episode = media_item("203", "Fixture Episode", "episode", 20, index=2, parentIndex=1,
                         contentRating="TV-G", parentRatingKey="202", grandparentRatingKey="201",
                         grandparentTitle=show["title"], Media=video_part("203"))
    photo = media_item("301", "Fixture Photo", "photo", 30, year=2026)
    return {
        "/library/sections/10/all": [movie, second_movie],
        "/library/sections/20/all": [show],
        "/library/sections/30/all": [photo],
        "/library/metadata/201/children": [season],
        "/library/metadata/202/children": [episode],
    }, {item["ratingKey"]: item for item in [movie, second_movie, show, season, episode, photo]}


class FixtureServer(TLSFixtureServer):
    handshake_log_tag = "plex-tls"

    def __init__(self, port, advertised_host, *, ssl_context):
        super().__init__(("127.0.0.1", port), Handler, ssl_context=ssl_context)
        self.origin = f"https://{advertised_host}:{self.server_address[1]}"
        self.pages, self.items = catalog()
        self.pins = {}
        self.pin_ids = itertools.count(1)
        self.lock = threading.Lock()
        self.events = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Do not print URLs, headers, or test PINs to the CI log.
        pass

    def send_body(self, status, body=b"", headers=()):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # A cancelled player range during scrubbing can close the socket.
            pass

    def send_json(self, value, status=200):
        self.send_body(status, json.dumps(value).encode("utf-8"), [
            ("Content-Type", "application/json"),
            ("Cache-Control", "no-store"),
        ])

    def do_POST(self):
        parts = urlsplit(self.path)
        query = parse_qs(parts.query)
        if parts.path != "/api/v2/pins" or query != {"strong": ["false"]}:
            self.send_body(404)
            return
        device = self.headers.get("X-Plex-Client-Identifier")
        if (not device or self.headers.get("X-Plex-Token") is not None or
                self.headers.get("Content-Length", "0") != "0"):
            self.send_body(400)
            return
        with self.server.lock:
            pin_id = next(self.server.pin_ids)
            code = f"{pin_id % 10000:04d}"
            self.server.pins[pin_id] = (device, code, False)
        print("Plex fixture created a link code.", flush=True)
        self.send_json({"id": pin_id, "code": code, "expiresIn": 300}, status=201)

    def do_GET(self):
        parts = urlsplit(self.path)
        path = parts.path
        query = parse_qs(parts.query, keep_blank_values=True)
        credential = self.headers.get("X-Plex-Token")
        device = self.headers.get("X-Plex-Client-Identifier")
        if path == "/health":
            self.send_body(200, b"ready")
            return
        if any(name.lower() == "x-plex-token" for name in query):
            self.send_body(400)
            return
        if path == "/identity":
            self.send_json({"MediaContainer": {"machineIdentifier": SERVER_ID, "version": "1.42.2"}})
            return
        if not device:
            self.send_body(401)
            return
        pin = re.fullmatch(r"/api/v2/pins/(\d{1,12})", path)
        if pin:
            self.send_pin(int(pin[1]), device, credential, query)
        elif path == "/api/v2/resources":
            if credential != ACCOUNT_TOKEN or query.get("includeHttps") != ["1"]:
                self.send_body(401)
                return
            print("Plex fixture returned its advertised server.", flush=True)
            self.send_json([{
                "name": "Fixture Plex", "clientIdentifier": SERVER_ID, "provides": "server",
                "accessToken": SERVER_TOKEN,
                "connections": [{"uri": self.server.origin, "local": True, "relay": False}],
            }])
        elif credential != SERVER_TOKEN:
            self.send_body(401)
        else:
            self.send_media_resource(path, query, device)

    def send_pin(self, pin, device, token, query):
        with self.server.lock:
            entry = self.server.pins.get(pin)
            if entry and entry[:2] == (device, (query.get("code") or [""])[0]) and token is None:
                self.server.pins[pin] = (device, entry[1], True)
            else:
                entry = None
        if entry:
            print("Plex fixture returned an approved link." if entry[2]
                  else "Plex fixture returned a pending link.", flush=True)
            self.send_json({"authToken": ACCOUNT_TOKEN if entry[2] else None})
        else:
            self.send_body(404)

    def send_media_resource(self, path, query, device):
        detail = re.fullmatch(r"/library/metadata/(\d+)(/thumb/1)?", path)
        part = re.fullmatch(r"/library/parts/(101|102|203)/1/file\.mp4", path)
        if path == "/library/sections":
            self.send_json({"MediaContainer": {"size": len(LIBRARIES), "Directory": LIBRARIES}})
        elif path in self.server.pages:
            self.send_page(path, query)
        elif detail and detail[1] in self.server.items:
            if detail[2]:
                self.send_body(200, JPEG_BYTES.read_bytes(), [("Content-Type", "image/jpeg")])
            else:
                item = self.server.items[detail[1]]
                self.send_json({"MediaContainer": {
                    "size": 1, "librarySectionID": item["librarySectionID"], "Metadata": [item],
                }})
        elif part:
            self.send_range()
        elif path == "/library/streams/1":
            self.send_body(200, SUBTITLE, [("Content-Type", "application/x-subrip")])
        elif path == "/:/timeline":
            self.record_timeline(query, device)
        elif path == "/fixture/timeline":
            with self.server.lock:
                events = [event.copy() for event in self.server.events.get(device, [])]
            self.send_json(events)
        else:
            self.send_body(404)

    def send_page(self, path, query):
        try:
            offset = int(self.headers.get("X-Plex-Container-Start", query.get("X-Plex-Container-Start", ["0"])[0]))
            size = int(self.headers.get("X-Plex-Container-Size", query.get("X-Plex-Container-Size", ["100"])[0]))
        except ValueError:
            self.send_body(400)
            return
        if offset < 0 or size <= 0:
            self.send_body(400)
            return
        # A smaller server-side page cap exercises follow-up requests in the clients.
        items = self.server.pages[path]
        page = items[offset:offset + 1]
        self.send_json({"MediaContainer": {
            "size": len(page), "offset": offset, "totalSize": len(items), "Metadata": page,
        }})

    def send_range(self):
        total = MOVIE_BYTES.stat().st_size
        match = RANGE.fullmatch(self.headers.get("Range", ""))
        if not match:
            self.send_body(416, headers=[("Content-Range", f"bytes */{total}")])
            return
        first, last = (int(value) for value in match.groups())
        if not 0 <= first <= last < total or last - first >= 8 * 1024 * 1024:
            self.send_body(416, headers=[("Content-Range", f"bytes */{total}")])
            return
        with MOVIE_BYTES.open("rb") as movie:
            movie.seek(first)
            body = movie.read(last - first + 1)
        self.send_body(206, body, [("Content-Type", "video/mp4"),
                                  ("Content-Range", f"bytes {first}-{last}/{total}"),
                                  ("Accept-Ranges", "bytes")])

    def record_timeline(self, query, device):
        key = query.get("ratingKey", [""])[0]
        position = query.get("time", [""])[0]
        state = query.get("state", [""])[0]
        if key not in self.server.items or state not in {"playing", "paused", "stopped", "buffering"} or not position.isdecimal():
            self.send_body(400)
            return
        with self.server.lock:
            self.server.events.setdefault(device, []).append({"ratingKey": key, "time": int(position), "state": state})
        self.send_body(200)


def certificate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    configuration = directory / "openssl.cnf"
    configuration.write_text("""
[req]
distinguished_name = subject
prompt = no
x509_extensions = extensions
[subject]
CN = Disposable MediaVault Plex
[extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1,IP:10.0.2.2,DNS:localhost
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
    parser.add_argument("--advertised-host", choices=("127.0.0.1", "10.0.2.2"), default="127.0.0.1")
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()
    cert, key = certificate(args.directory)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    with FixtureServer(args.port, args.advertised_host, ssl_context=tls) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
