"""Exercise the Android Emby client with a disposable Emby server and synthetic media."""

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

IMAGE = "emby/embyserver@sha256:7082c63b10a2fcb3805a7eaebba407d5723bc57c085c9f0b29b7d0a702765cc1"
PORT = 18097
ENDPOINT = f"http://127.0.0.1:{PORT}/emby/"
IDENTITY = 'Emby Client="MediaVault fixture", Device="Cloud fixture", DeviceId="mediavault-setup", Version="1.0"'
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(path, data=None, *, method=None, token=None):
    headers = {"Accept": "application/json", "Authorization": IDENTITY}
    if token:
        headers["X-Emby-Token"] = token
    body = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()
    try:
        target = urllib.request.Request(ENDPOINT + path, data=body, headers=headers, method=method)
        with OPENER.open(target, timeout=15) as response:
            payload = response.read()
            return json.loads(payload) if payload else None
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"{path.split('?')[0]} returned HTTP {error.code}") from None


def wait_until_ready():
    for _ in range(45):
        try:
            request("Startup/Configuration")
            return
        except (OSError, RuntimeError):
            time.sleep(1)
    raise RuntimeError("The Emby fixture did not start.")


def configure(password):
    wait_until_ready()
    request("Startup/Configuration", {"UICulture": "en-US", "MetadataCountryCode": "US",
                                       "PreferredMetadataLanguage": "en"})
    request("Startup/User", {"Name": "fixture", "Password": password})
    request("Startup/Complete", method="POST")
    session = request("Users/AuthenticateByName", {"Username": "fixture", "Pw": password})
    token = session["AccessToken"]
    user = session["User"]["Id"]
    try:
        library_options = {
            "EnableRealtimeMonitor": False,
            "DisabledMetadataFetchers": ["TheMovieDb", "The Open Movie Database"],
        }
        selection = urllib.parse.urlencode({
            "Name": "Fixture Movies", "CollectionType": "movies", "Paths": "/movies", "RefreshLibrary": "true",
        })
        request("Library/VirtualFolders?" + selection, {"LibraryOptions": library_options}, token=token)
        for _ in range(40):
            views = request(f"Users/{user}/Views", token=token)["Items"]
            library = next((item for item in views if item["Name"] == "Fixture Movies"), None)
            if library:
                query = urllib.parse.urlencode({
                    "ParentId": library["Id"], "Recursive": "true", "IncludeItemTypes": "Movie", "Limit": 100,
                })
                if request(f"Users/{user}/Items?{query}", token=token)["Items"]:
                    return
            time.sleep(1)
        raise RuntimeError("Emby did not index the synthetic movie.")
    finally:
        request("Sessions/Logout", method="POST", token=token)


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gradle", default=str(root / "android" / "gradlew"))
    args = parser.parse_args()
    name = "mediavault-emby-fixture-" + secrets.token_hex(4)
    password = secrets.token_urlsafe(24)
    with tempfile.TemporaryDirectory() as temp:
        movies = Path(temp) / "movies"
        movie = movies / "Fixture Movie (2026)" / "Fixture Movie (2026).mp4"
        movie.parent.mkdir(parents=True)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "4", "-c:v", "libx264",
            "-c:a", "aac", "-movflags", "+faststart", str(movie),
        ], check=True)
        subprocess.run([
            "docker", "run", "-d", "--rm", "--name", name, "--publish", f"127.0.0.1:{PORT}:8096",
            "--env", f"UID={os.getuid()}", "--env", f"GID={os.getgid()}",
            "--mount", f"type=bind,src={movies},dst=/movies,readonly", IMAGE,
        ], check=True, stdout=subprocess.DEVNULL)
        try:
            configure(password)
            env = {**os.environ, "MEDIAVAULT_EMBY_FIXTURE_PASSWORD": password}
            subprocess.run([
                args.gradle, ":app:testDebugUnitTest", "--rerun", "--tests", "*EmbyLiveServerTest",
            ], cwd=root / "android", check=True, env=env)
        finally:
            subprocess.run(["docker", "stop", name], check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
