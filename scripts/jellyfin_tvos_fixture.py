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
MOVIE = {"Id": "fixture-movie", "Name": "Fixture Film", "Type": "Movie", "OfficialRating": "G",
         "ImageTags": {"Primary": "fixture-poster"}, "ProviderIds": {"Tmdb": "27182"}}
PHOTO = {"Id": "fixture-photo", "Name": "Fixture Photo", "Type": "Photo"}
SERIES = {"Id": "fixture-series", "Name": "Fixture Series", "Type": "Series", "ProviderIds": {"Tmdb": "31415"}}
EPISODE = {"Id": "fixture-episode", "Name": "Fixture Episode", "Type": "Episode", "SeriesName": "Fixture Series",
           "SeriesId": "fixture-series", "SeasonId": "fixture-season", "ParentIndexNumber": 1, "IndexNumber": 2,
           "ProviderIds": {"Tmdb": "99000"}}
SAMPLES = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures"
MEDIA = SAMPLES / "playback.mp4"
IMAGE = SAMPLES / "Photos" / "01.jpg"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # The fixture intentionally returns a synthetic token in playlist URIs.
        pass

    def send_body(self, status, body=b"", headers=()):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError):
            # AVPlayer may close a canceled segment request before sending TLS close_notify.
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
            source = {"Id": "fixture-media-source", "SupportsDirectPlay": data.get("EnableDirectPlay") is True, "MediaStreams": [
                    {"Type": "Subtitle", "Index": 2, "IsTextSubtitleStream": True, "Language": "en"},
            ]}
            session = "fixture-playback"
            if not source["SupportsDirectPlay"]:
                profiles = data.get("DeviceProfile", {}).get("TranscodingProfiles", [])
                if not any(profile.get("Protocol") == "hls" and profile.get("VideoCodec") == "h264" for profile in profiles):
                    self.send_body(422)
                    return
                session = "fixture-transcode"
                source["TranscodingUrl"] = "/Videos/fixture-movie/master.m3u8?api_key=synthetic-and-removable"
            self.send_json({"PlaySessionId": session, "MediaSources": [source]})
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
        if any(name.lower() == "api_key" for name in query):
            self.send_body(400)
        elif parts.path.startswith("/jellyfin/Videos/fixture-movie/") and parts.path.endswith((".m3u8", ".ts")):
            self.send_hls(parts.path)
        elif parts.path == "/jellyfin/UserViews" and query.get("userId") == ["fixture-user"]:
            self.send_json({"Items": [LIBRARY], "StartIndex": 0, "TotalRecordCount": 1})
        elif (parts.path == "/jellyfin/Items" and query.get("parentId") == ["fixture-library"]
              and query.get("enableUserData") == ["false"]):
            catalog = [MOVIE, EPISODE, PHOTO, SERIES]
            self.send_json({"Items": catalog, "StartIndex": 0, "TotalRecordCount": len(catalog)})
        elif (parts.path == "/jellyfin/Videos/fixture-movie/stream" and query.get("static") == ["true"]
              and query.get("playSessionId") == ["fixture-playback"]):
            self.send_range()
        elif parts.path == "/jellyfin/Items/fixture-photo/Images/Primary" or (
            parts.path == "/jellyfin/Items/fixture-movie/Images/Primary" and query.get("tag") == ["fixture-poster"]
        ):
            self.send_body(200, IMAGE.read_bytes(), [("Content-Type", "image/jpeg")])
        elif parts.path == "/jellyfin/Videos/fixture-movie/fixture-media-source/Subtitles/2/Stream.vtt":
            self.send_body(200, b"WEBVTT\n\n00:00:07.000 --> 00:00:11.000\nFixture Jellyfin caption.\n",
                           [("Content-Type", "text/vtt")])
        else:
            self.send_body(404)

    def do_DELETE(self):
        if not self.authorized():
            return
        parts = urlsplit(self.path)
        if (parts.path == "/jellyfin/Videos/ActiveEncodings"
                and parse_qs(parts.query).get("playSessionId") == ["fixture-transcode"]):
            self.send_body(204)
        else:
            self.send_body(404)

    def send_hls(self, path):
        name = path.rsplit("/", 1)[-1]
        if name == "master.m3u8":
            self.send_body(200, b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.42c00a,mp4a.40.2"\n'
                           b"variant.m3u8?api_key=synthetic-and-removable\n",
                           [("Content-Type", "application/vnd.apple.mpegurl")])
        elif self.server.hls and (name == "variant.m3u8" or re.fullmatch(r"segment\d+\.ts", name)):
            resource = self.server.hls / name
            if resource.is_file():
                content_type = "application/vnd.apple.mpegurl" if name.endswith("m3u8") else "video/mp2t"
                self.send_body(200, resource.read_bytes(), [("Content-Type", content_type)])
            else:
                self.send_body(404)
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
    parser.add_argument("--hls", action="store_true")
    args = parser.parse_args()
    cert, key = certificate(args.directory)
    hls = None
    if args.hls:
        hls = args.directory / "segments"
        hls.mkdir(exist_ok=True)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(MEDIA), "-f", "lavfi",
                        "-i", "anullsrc=channel_layout=stereo:sample_rate=48000", "-map", "0:v:0", "-map", "1:a:0",
                        "-c:v", "copy", "-c:a", "aac", "-shortest",
                        "-hls_time", "2", "-hls_playlist_type", "vod",
                        "-hls_segment_filename", str(hls / "segment%d.ts"), str(hls / "variant.m3u8")], check=True)
    with ThreadingHTTPServer(("127.0.0.1", 18896), Handler) as server:
        server.hls = hls
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
