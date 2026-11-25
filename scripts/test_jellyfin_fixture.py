"""Run Android Jellyfin API tests against a disposable, loopback-only server."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import ssl
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
base = "http://127.0.0.1:18096"
authorization = 'MediaBrowser Client="MediaVault fixture", Device="Cloud fixture", DeviceId="mediavault-setup", Version="1.0"'
password = secrets.token_urlsafe(24)

def request(path, body=None, *, method=None, token=None):
    headers = {"Accept": "application/json", "Authorization": authorization}
    if token:
        headers["Authorization"] += ', Token="' + token + '"'
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    try:
        with opener.open(urllib.request.Request(base + path, headers=headers, data=data, method=method), timeout=15) as response:
            payload = response.read()
            return json.loads(payload) if payload else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{path.split('?')[0]} returned HTTP {e.code}") from None

def configure():
    for _ in range(45):
        try:
            request("/Startup/Configuration")
            break
        except (urllib.error.URLError, RuntimeError, ConnectionError):
            time.sleep(1)
    else:
        raise RuntimeError("The fixture did not start.")
    request("/Startup/Configuration", {"UICulture": "en-US", "MetadataCountryCode": "US",
                                       "PreferredMetadataLanguage": "en"})
    request("/Startup/FirstUser")
    request("/Startup/User", {"Name": "fixture", "Password": password})
    request("/Startup/RemoteAccess", {"EnableRemoteAccess": False, "EnableAutomaticPortMapping": False})
    request("/Startup/Complete", method="POST")

    session = request("/Users/AuthenticateByName", {"Username": "fixture", "Pw": password})
    token = session["AccessToken"]
    try:
        for name, kind, path in (("Fixture Movies", "movies", "/movies"),
                                 ("Fixture Photos", "homevideos", "/photos")):
            query = urllib.parse.urlencode({"name": name, "collectionType": kind,
                                            "paths": path, "refreshLibrary": "false"})
            request("/Library/VirtualFolders?" + query, {
                "LibraryOptions": {"EnableRealtimeMonitor": False, "DisabledMetadataFetchers":
                                   ["TheMovieDb", "The Open Movie Database"]},
            }, token=token)
        wait_for_catalog(token)
    finally:
        request("/Sessions/Logout", method="POST", token=token)


def wait_for_catalog(token):
    request("/Library/Refresh", method="POST", token=token)
    expected = {"Fixture Movies": "Movie", "Fixture Photos": "Photo"}
    for _ in range(45):
        views = request("/UserViews", token=token)["Items"]
        for library in views:
            item_type = expected.get(library["Name"])
            if item_type:
                query = urllib.parse.urlencode(
                    {"parentId": library["Id"], "recursive": "true", "includeItemTypes": item_type})
                if request("/Items?" + query, token=token)["Items"]:
                    del expected[library["Name"]]
        if not expected:
            return
        time.sleep(1)
    raise RuntimeError("The fixture did not index each synthetic library.")



class AndroidFixtureProxy(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Paths from HLS manifests can include synthetic tokens.
        pass

    def forward(self):
        if not self.path.startswith("/") or self.path.startswith("//"):
            self.send_error(400)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= 1024 * 1024:
            self.send_error(413)
            return
        body = self.rfile.read(length) if length else None
        omit = {"host", "connection", "transfer-encoding", "content-length", "accept-encoding"}
        headers = {name: value for name, value in self.headers.items() if name.lower() not in omit}
        headers["Accept-Encoding"] = "identity"
        try:
            response = opener.open(urllib.request.Request(
                base + self.path, data=body, headers=headers, method=self.command), timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        except urllib.error.URLError:
            self.send_error(502)
            return
        with response:
            length = response.headers.get("Content-Length")
            buffered = None
            if length is None:
                limit = 8 * 1024 * 1024
                buffered = response.read(limit + 1)
                if len(buffered) > limit:
                    self.send_error(502)
                    return
                length = str(len(buffered))
            self.send_response(response.code)
            for name, value in response.headers.items():
                if name.lower() not in {"connection", "content-length", "transfer-encoding"}:
                    self.send_header(name, value)
            self.send_header("Content-Length", length)
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                if buffered is not None:
                    self.wfile.write(buffered)
                else:
                    while block := response.read(64 * 1024):
                        self.wfile.write(block)
            except (BrokenPipeError, ConnectionResetError):
                # The player can intentionally cancel a read before seeking.
                pass

    do_GET = do_POST = do_DELETE = forward


def publish_android_fixture(directory):
    directory.mkdir(parents=True, exist_ok=True)
    certificate, key = directory / "jellyfin.pem", directory / "jellyfin-key.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-sha256", "-days", "1",
        "-subj", "/CN=Disposable MediaVault Jellyfin",
        "-addext", "subjectAltName=IP:127.0.0.1,IP:10.0.2.2",
        "-addext", "extendedKeyUsage=serverAuth",
        "-keyout", str(key), "-out", str(certificate),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    temporary = directory / "jellyfin.tmp"
    subprocess.run(["openssl", "x509", "-in", str(certificate), "-outform", "DER", "-out", str(temporary)], check=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(certificate, key)
    with ThreadingHTTPServer(("127.0.0.1", 18443), AndroidFixtureProxy) as proxy:
        proxy.socket = tls.wrap_socket(proxy.socket, server_side=True)
        temporary.rename(directory / "jellyfin.cer")
        proxy.serve_forever()


def stop_fixture(_signal, _frame):
    raise KeyboardInterrupt

def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gradle", default=str(root / "android" / "gradlew"))
    parser.add_argument("--serve-android", type=Path, help="Serve the disposable fixture over TLS for a hosted TV test")
    args = parser.parse_args()
    if args.serve_android:
        global password
        password = "fixture-only"
        signal.signal(signal.SIGTERM, stop_fixture)
    image = "jellyfin/jellyfin@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771"
    name = "mediavault-jellyfin-fixture-" + secrets.token_hex(4)
    with tempfile.TemporaryDirectory() as temp:
        movies = Path(temp) / "movies"
        movie = movies / "Fixture Film (2026)" / "Fixture Film (2026).mp4"
        movie.parent.mkdir(parents=True)
        movie.with_suffix(".nfo").write_text("<movie><title>Fixture Film</title><year>2026</year></movie>", encoding="utf-8")
        fixture_photos = root / "CineVaultTests" / "Fixtures" / "Photos"
        photos = Path(temp) / "photos"
        photos.mkdir()
        shutil.copyfile(fixture_photos / "01.jpg", movie.parent / "poster.jpg")
        shutil.copyfile(fixture_photos / "02.png", photos / "Fixture Photo.png")
        if args.serve_android:
            shutil.copyfile(root / "CineVaultTests" / "Fixtures" / "playback.mp4", movie)
        else:
            subprocess.run([
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3", "-c:v", "libx264",
                "-c:a", "aac", "-movflags", "+faststart", str(movie),
            ], check=True)
        subprocess.run(["docker", "run", "--rm", "-d", "--name", name, "--publish", "127.0.0.1:18096:8096", image],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            subprocess.run(["docker", "cp", str(movies), name + ":/movies"], check=True)
            subprocess.run(["docker", "cp", str(photos), name + ":/photos"], check=True)
            print("Waiting for Jellyfin to index the synthetic movie and photo.", flush=True)
            configure()
            if args.serve_android:
                publish_android_fixture(args.serve_android)
            else:
                test_env = {**os.environ, "MEDIAVAULT_JELLYFIN_FIXTURE_PASSWORD": password}
                subprocess.run([args.gradle, ":app:testDebugUnitTest", "--rerun", "--tests", "*Jellyfin*"], check=True,
                               cwd=root / "android", env=test_env)
        except KeyboardInterrupt:
            if not args.serve_android:
                raise
        finally:
            subprocess.run(["docker", "stop", name], check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
