"""Disposable TLS WebDAV fixture for hosted TV tests."""

import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import ssl
import subprocess
from urllib.parse import quote, urlsplit
from xml.etree import ElementTree as ET


ROOT = "/dav/"
AUTHORIZATION = "Basic " + base64.b64encode(b"cinevault:fixture-only").decode("ascii")
SAMPLE_DIR = Path(__file__).resolve().parents[1] / "CineVaultTests" / "Fixtures"


def create_certificate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    config = directory / "openssl.cnf"
    config.write_text("""
[req]
distinguished_name = subject
prompt = no
x509_extensions = extensions

[subject]
CN = Disposable MediaVault WebDAV

[extensions]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = IP:127.0.0.1,IP:10.0.2.2
""", encoding="utf-8")
    certificate, key = directory / "fixture.pem", directory / "fixture-key.pem"
    subprocess.run(
        [
            "openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-sha256",
            "-days", "1", "-config", str(config), "-keyout", str(key), "-out", str(certificate),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["openssl", "x509", "-in", str(certificate), "-outform", "DER", "-out", str(directory / "fixture.cer")],
        check=True,
    )
    return certificate, key


class Handler(BaseHTTPRequestHandler):
    directories = {ROOT: ["Movies/"], ROOT + "Movies/": ["Film.mp4", "Film.en.srt", "film.en.srt", "bytes.bin"]}
    files = {
        ROOT + "Movies/Film.mp4": (SAMPLE_DIR / "playback.mp4").read_bytes(),
        ROOT + "Movies/Film.en.srt": b"1\n00:00:00,500 --> 00:00:05,000\nMatching fixture caption.\n",
        ROOT + "Movies/film.en.srt": b"1\n00:00:00,500 --> 00:00:05,000\nWrong-case fixture caption.\n",
        ROOT + "Movies/bytes.bin": b"0123456789",
    }

    def send_body(self, status, contents=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(contents)))
        self.end_headers()
        try:
            self.wfile.write(contents)
        except (BrokenPipeError, ConnectionResetError):
            # Playback may cancel reads while seeking.
            pass

    def authenticated(self):
        if self.headers.get("Authorization") == AUTHORIZATION:
            return True
        self.send_body(401, headers=[("WWW-Authenticate", 'Basic realm="fixture"')])
        return False

    def do_PROPFIND(self):
        if not self.authenticated():
            return
        path = urlsplit(self.path).path
        children = self.directories.get(path)
        if children is None:
            self.send_body(404)
            return
        if self.headers.get("Depth") != "1":
            self.send_body(400)
            return
        listing = ET.Element("{DAV:}multistatus")
        for entry in [path, *(path + name for name in children)]:
            response = ET.SubElement(listing, "{DAV:}response")
            ET.SubElement(response, "{DAV:}href").text = quote(entry, safe="/")
            propstat = ET.SubElement(response, "{DAV:}propstat")
            properties = ET.SubElement(propstat, "{DAV:}prop")
            resource_type = ET.SubElement(properties, "{DAV:}resourcetype")
            if entry.endswith("/"):
                ET.SubElement(resource_type, "{DAV:}collection")
            else:
                ET.SubElement(properties, "{DAV:}getcontentlength").text = str(len(self.files[entry]))
            ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
        self.send_body(207, ET.tostring(listing, encoding="utf-8"), [("Content-Type", "application/xml")])

    def do_GET(self):
        if not self.authenticated():
            return
        path = urlsplit(self.path).path
        contents = self.files.get(path)
        if contents is None:
            self.send_body(404)
            return
        etag = '"fixture-v1"'
        if self.headers.get("If-Match") not in (None, etag):
            self.send_body(412)
            return
        requested = re.fullmatch(r"bytes=([0-9]+)-([0-9]+)", self.headers.get("Range", ""))
        if not requested:
            self.send_body(400)
            return
        start, stop = map(int, requested.groups())
        if not 0 <= start <= stop < len(contents):
            self.send_body(416, headers=[("Content-Range", f"bytes */{len(contents)}")])
            return
        self.send_body(
            206, contents[start:stop + 1],
            [("Content-Range", f"bytes {start}-{stop}/{len(contents)}"), ("ETag", etag)],
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    arguments = parser.parse_args()
    certificate, key = create_certificate(arguments.directory)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    with ThreadingHTTPServer(("127.0.0.1", 15443), Handler) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
