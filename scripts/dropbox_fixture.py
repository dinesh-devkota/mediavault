"""Disposable HTTPS Dropbox API fixture for hosted simulators."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import ssl
from urllib.parse import parse_qs

from webdav_fixture import SAMPLE_DIR, create_certificate


def folder(name, path, item_id):
    return {".tag": "folder", "name": name, "id": "id:" + item_id, "path_display": path}


def file(name, path, item_id, revision, data):
    return ({".tag": "file", "name": name, "path_display": path, "id": "id:" + item_id,
             "rev": revision, "size": len(data), "is_downloadable": True}, data)


MEDIA = folder("Media", "/Media", "fixture-media")
FILMS = folder("Films", "/Media/Films", "fixture-films")
PHOTOS = folder("Photos", "/Media/Photos", "fixture-photos")
PRIVATE = folder("Private", "/MediaPrivate", "fixture-private")
MOVIE = file("Film.mp4", "/Media/Films/Film.mp4", "fixture-movie", "112233445566",
             (SAMPLE_DIR / "playback.mp4").read_bytes())
CAPTION = file("film.en.srt", "/Media/Films/film.en.srt", "fixture-caption", "223344556677",
               b"1\n00:00:00,500 --> 00:00:05,000\nDropbox fixture caption.\n")
OTHER = file("Other.en.srt", "/Media/Films/Other.en.srt", "fixture-other", "334455667788",
             b"1\n00:00:00,500 --> 00:00:05,000\nUnrelated caption.\n")
PHOTO = file("Family.jpg", "/Media/Photos/Family.jpg", "fixture-photo", "445566778899",
             (SAMPLE_DIR / "Photos" / "01.jpg").read_bytes())
ITEMS = {item["path_display"].lower(): item
         for item in (MEDIA, FILMS, PHOTOS, PRIVATE, MOVIE[0], CAPTION[0], OTHER[0], PHOTO[0])}
DOWNLOADS = {meta["path_display"].lower(): (meta, data) for meta, data in (MOVIE, CAPTION, OTHER, PHOTO)}
DOWNLOADS.update({meta["id"]: (meta, data) for meta, data in (MOVIE, CAPTION, OTHER, PHOTO)})


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body=b"", **headers):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def payload(self, body):
        self.reply(200, json.dumps(body).encode(), Content_Type="application/json")

    def do_GET(self):
        self.reply(200 if self.path == "/health" else 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 16384:
            self.reply(413)
            return
        body = self.rfile.read(length)
        if self.path == "/oauth2/token":
            values = parse_qs(body.decode())
            if values.get("client_id") != ["fixture-app"] or "client_secret" in values or "redirect_uri" in values:
                self.reply(400)
                return
            if (values.get("grant_type") == ["authorization_code"] and values.get("code") == ["fixture-code"]
                    and re.fullmatch(r"[A-Za-z0-9_-]{43}", values.get("code_verifier", [""])[0])):
                self.payload({"account_id": "dbid:fixture", "access_token": "fixture-approval",
                              "refresh_token": "fixture-refresh", "expires_in": 14400})
            elif values.get("grant_type") == ["refresh_token"] and values.get("refresh_token") == ["fixture-refresh"]:
                self.payload({"access_token": "fixture-renewed", "expires_in": 14400})
            else:
                self.reply(400)
            return
        token = self.headers.get("Authorization")
        if token not in ("Bearer fixture-renewed", "Bearer fixture-approval"):
            self.reply(401)
            return
        if self.path == "/2/auth/token/revoke":
            self.reply(200)
        elif self.path == "/2/files/download":
            self.download()
        elif self.path == "/2/files/get_metadata":
            arguments = json.loads(body)
            item = ITEMS.get(arguments.get("path", "").lower())
            self.payload(item) if item else self.reply(409)
        elif self.path == "/2/files/list_folder":
            path = json.loads(body).get("path")
            if path == "":
                self.payload({"entries": [MEDIA, PRIVATE], "cursor": "root-done", "has_more": False})
            elif path in ("/Media", MEDIA["id"]):
                self.payload({"entries": [FILMS], "cursor": "media-next", "has_more": True})
            elif path in ("/Media/Films", FILMS["id"]):
                self.payload({"entries": [MOVIE[0], CAPTION[0], OTHER[0]], "cursor": "films-done", "has_more": False})
            elif path in ("/Media/Photos", PHOTOS["id"]):
                self.payload({"entries": [PHOTO[0]], "cursor": "photos-done", "has_more": False})
            else:
                self.reply(409)
        elif self.path == "/2/files/list_folder/continue" and json.loads(body).get("cursor") == "media-next":
            self.payload({"entries": [PHOTOS], "cursor": "media-done", "has_more": False})
        else:
            self.reply(404)

    def download(self):
        reference = json.loads(self.headers.get("Dropbox-API-Arg", "{}")).get("path")
        item = DOWNLOADS.get(reference.lower()) if isinstance(reference, str) else None
        requested = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        if not item or not requested or self.headers.get("Accept-Encoding") != "identity":
            self.reply(400)
            return
        metadata, data = item
        start, end = (int(value) for value in requested.groups())
        if not 0 <= start <= end < len(data):
            self.reply(416)
            return
        # files/download returns a concrete FileMetadata value without a union discriminator.
        result = {name: value for name, value in metadata.items() if name != ".tag"}
        self.reply(206, data[start:end + 1], Content_Range=f"bytes {start}-{end}/{len(data)}",
                   Dropbox_API_Result=json.dumps(result, separators=(",", ":")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    certificate, key = create_certificate(directory, "Dropbox")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    with ThreadingHTTPServer(("127.0.0.1", 18444), Handler) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
