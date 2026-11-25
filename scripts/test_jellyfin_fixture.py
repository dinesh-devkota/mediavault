"""Run Android Jellyfin API tests against a disposable, loopback-only server."""

import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
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
        query = urllib.parse.urlencode({"name": "Fixture Movies", "collectionType": "movies",
                                        "paths": "/movies", "refreshLibrary": "false"})
        request("/Library/VirtualFolders?" + query, {
            "LibraryOptions": {"EnableRealtimeMonitor": False, "DisabledMetadataFetchers":
                               ["TheMovieDb", "The Open Movie Database"]},
        }, token=token)
        wait_for_movie(token)
    finally:
        request("/Sessions/Logout", method="POST", token=token)


def wait_for_movie(token):
    scanned = False
    for _ in range(45):
        views = request("/UserViews", token=token)["Items"]
        library = next((item for item in views if item["Name"] == "Fixture Movies"), None)
        if library:
            if not scanned:
                request("/Library/Refresh", method="POST", token=token)
                scanned = True
            query = urllib.parse.urlencode({"parentId": library["Id"], "recursive": "true", "includeItemTypes": "Movie"})
            if request("/Items?" + query, token=token)["Items"]:
                return
        time.sleep(1)
    raise RuntimeError("The fixture did not finish indexing.")


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gradle", default=str(root / "android" / "gradlew"))
    args = parser.parse_args()
    image = "jellyfin/jellyfin@sha256:fea863d0cd9ec445985d9c75fc6ed64e38a1d2766cf0c250a33d553f4fc1b771"
    name = "mediavault-jellyfin-fixture-" + secrets.token_hex(4)
    with tempfile.TemporaryDirectory() as temp:
        movies = Path(temp) / "movies"
        movie = movies / "Fixture Film (2026)" / "Fixture Film (2026).mp4"
        movie.parent.mkdir(parents=True)
        movie.with_suffix(".nfo").write_text("<movie><title>Fixture Film</title><year>2026</year></movie>", encoding="utf-8")
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3", "-c:v", "libx264",
            "-c:a", "aac", "-movflags", "+faststart", str(movie),
        ], check=True)
        subprocess.run(["docker", "run", "--rm", "-d", "--name", name, "--publish", "127.0.0.1:18096:8096", image],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            subprocess.run(["docker", "cp", str(movies), name + ":/movies"], check=True)
            print("Waiting for Jellyfin to index the synthetic movie.", flush=True)
            configure()
            test_env = {**os.environ, "MEDIAVAULT_JELLYFIN_FIXTURE_PASSWORD": password}
            subprocess.run([args.gradle, ":app:testDebugUnitTest", "--rerun", "--tests", "*Jellyfin*"], check=True,
                           cwd=root / "android", env=test_env)
        finally:
            subprocess.run(["docker", "stop", name], check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
