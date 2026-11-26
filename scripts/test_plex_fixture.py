"""Check the Plex catalog and range contract against a disposable offline server."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.parse
import uuid


IMAGE = "plexinc/pms-docker@sha256:6d778d41daae68f89115aa87a44ae14a96b23e71a2093da173b5a9aac4091336"
BASE_URL = "http://127.0.0.1:32400"


def request(container, path, *, method="GET", headers=(), include_headers=False):
    command = ["docker", "exec", container, "curl", "-sS", "--max-time", "20",
               "-X", method, "-H", "Accept: application/json", "--write-out", "\n%{http_code}"]
    for header in headers:
        command.extend(["-H", header])
    if include_headers:
        command.append("--include")
    response = subprocess.run(command + [BASE_URL + path], capture_output=True, check=True).stdout
    payload, separator, status = response.rpartition(b"\n")
    if not separator or len(status) != 3 or not status.isdigit():
        raise RuntimeError("Plex fixture did not return an HTTP response.")
    return int(status), payload


def create_library(container):
    name = "MediaVault Fixture"
    options = urllib.parse.urlencode({
        "name": name,
        "type": "movie",
        "agent": "tv.plex.agents.movie",
        "scanner": "Plex Movie",
        "language": "en-US",
        "location": "/media",
    }, quote_via=urllib.parse.quote)
    deadline = time.monotonic() + 160
    while time.monotonic() < deadline:
        try:
            status, payload = request(container, "/library/sections")
            if status == 200:
                sections = json.loads(payload)["MediaContainer"].get("Directory", [])
                for row in sections:
                    if row["title"] == name:
                        return row["key"]
                status, payload = request(container, "/library/sections?" + options, method="POST")
                if status in (200, 201):
                    return json.loads(payload)["MediaContainer"]["Directory"][0]["key"]
                if status != 400 or b"server is still starting up" not in payload:
                    raise RuntimeError(f"Plex fixture library creation failed with HTTP {status}.")
        except subprocess.CalledProcessError:
            pass
        time.sleep(2)
    raise TimeoutError("Plex fixture did not finish starting.")

def verify_catalog(container, library, expected):
    status, payload = request(container, "/library/sections")
    if status != 200 or library not in {row["key"] for row in json.loads(payload)["MediaContainer"]["Directory"]}:
        raise RuntimeError("Plex did not return the synthetic movie library.")

    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        status, payload = request(
            container, f"/library/sections/{library}/all",
            headers=("X-Plex-Container-Start: 0", "X-Plex-Container-Size: 100"),
        )
        if status != 200:
            raise RuntimeError(f"Plex fixture catalog request failed with HTTP {status}.")
        items = json.loads(payload)["MediaContainer"].get("Metadata", [])
        if items:
            part = items[0]["Media"][0]["Part"][0]
            break
        time.sleep(1)
    else:
        raise TimeoutError("Plex did not index the synthetic movie.")

    if not part["key"].startswith("/library/parts/") or part["size"] != len(expected):
        raise RuntimeError("Plex returned unexpected file metadata.")
    status, payload = request(
        container, part["key"], headers=("Range: bytes=5-9", "Accept-Encoding: identity"), include_headers=True,
    )
    headers, _, data = payload.partition(b"\r\n\r\n")
    if status != 206 or f"content-range: bytes 5-9/{len(expected)}".encode() not in headers.lower().splitlines():
        raise RuntimeError("Plex did not return the expected HTTP 206 range.")
    if data != expected[5:10]:
        raise RuntimeError("Plex returned the wrong bytes.")
    print("Plex catalog and HTTP 206 byte range verified against a synthetic offline server.")


def main():
    name = "mediavault-plex-" + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix="mediavault-plex-") as temporary:
        fixture = Path(temporary)
        movie = fixture / "movies" / "Fixture Movie (2026)" / "Fixture Movie (2026).mp4"
        movie.parent.mkdir(parents=True)
        subprocess.run(
            ["ffmpeg", "-nostdin", "-y", "-hide_banner", "-loglevel", "error",
             "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=10", "-t", "2",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", str(movie)], check=True,
        )

        try:
            subprocess.run(
                ["docker", "run", "--rm", "--detach", "--network", "none", "--name", name,
                 "--env", f"PLEX_UID={os.getuid()}", "--env", f"PLEX_GID={os.getgid()}",
                 "--mount", "type=tmpfs,dst=/config,tmpfs-size=536870912,tmpfs-mode=1777",
                 "--mount", f"type=bind,src={fixture / 'movies'},dst=/media,readonly", IMAGE],
                stdout=subprocess.DEVNULL, check=True,
            )
            verify_catalog(name, create_library(name), movie.read_bytes())
        finally:
            subprocess.run(["docker", "stop", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
