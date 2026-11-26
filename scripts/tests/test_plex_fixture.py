import json
from pathlib import Path
import ssl
import sys
import tempfile
import threading
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, HTTPSHandler, build_opener

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from plex_fixture import ACCOUNT_TOKEN, SERVER_ID, SERVER_TOKEN, FixtureServer, certificate


class PlexFixtureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = cls.enterClassContext(tempfile.TemporaryDirectory(prefix="mediavault-plex-test-"))
        cert, key = certificate(Path(directory))
        cls.server = FixtureServer(0, "127.0.0.1")
        cls.addClassCleanup(cls.server.server_close)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        cls.server.socket = tls.wrap_socket(cls.server.socket, server_side=True)
        worker = threading.Thread(target=cls.server.serve_forever)
        worker.start()
        cls.addClassCleanup(worker.join)
        cls.addClassCleanup(cls.server.shutdown)
        context = ssl.create_default_context(cafile=str(cert))
        cls.client = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
        cls.origin = cls.server.origin

    def request(self, path, *, method="GET", token=None, device="fixture-device", headers=None):
        request_headers = {"X-Plex-Client-Identifier": device} if device else {}
        if token:
            request_headers["X-Plex-Token"] = token
        if headers:
            request_headers.update(headers)
        request = Request(self.origin + path, method=method, headers=request_headers)
        with self.client.open(request, timeout=5) as response:
            return response.status, response.headers, response.read()

    def assert_status(self, expected, path, **kwargs):
        with self.assertRaises(HTTPError) as error:
            self.request(path, **kwargs)
        self.assertEqual(error.exception.code, expected)

    def test_requires_trusted_tls(self):
        client = build_opener(ProxyHandler({}), HTTPSHandler(context=ssl.create_default_context()))
        with self.assertRaises(URLError) as error:
            client.open(self.origin + "/health", timeout=5)
        self.assertIsInstance(error.exception.reason, ssl.SSLCertVerificationError)
        self.assertEqual(self.request("/health")[2], b"ready")

    def test_device_link_pending_then_discovery_and_separate_tokens(self):
        status, _, body = self.request("/api/v2/pins?strong=false", method="POST")
        self.assertEqual(status, 201)
        pin = json.loads(body)
        path = f"/api/v2/pins/{pin['id']}?code={pin['code']}"
        self.assert_status(404, path, device="other-device")
        self.assertIsNone(json.loads(self.request(path)[2])["authToken"])
        token = json.loads(self.request(path)[2])["authToken"]
        self.assertEqual(token, ACCOUNT_TOKEN)
        self.assert_status(401, "/api/v2/resources?includeHttps=1", token=SERVER_TOKEN)
        servers = json.loads(self.request("/api/v2/resources?includeHttps=1", token=token)[2])
        self.assertEqual(servers[0]["connections"][0]["uri"], self.origin)
        self.assertEqual(servers[0]["clientIdentifier"], SERVER_ID)
        identity = json.loads(self.request("/identity", device=None)[2])["MediaContainer"]
        self.assertEqual(identity["machineIdentifier"], SERVER_ID)
        sections = "/library/sections"
        self.assert_status(401, sections, token=token)
        self.assert_status(400, sections + f"?X-Plex-Token={SERVER_TOKEN}", token=SERVER_TOKEN)
        libraries = json.loads(self.request(sections, token=servers[0]["accessToken"])[2])["MediaContainer"]
        self.assertEqual([row["type"] for row in libraries["Directory"]], ["movie", "show", "photo"])

    def test_paginates_movies_and_browses_hierarchy(self):
        for offset in range(2):
            raw = self.request("/library/sections/10/all", token=SERVER_TOKEN, headers={
                "X-Plex-Container-Start": str(offset), "X-Plex-Container-Size": "100",
            })[2]
            page = json.loads(raw)["MediaContainer"]
            self.assertEqual((page["offset"], page["size"], page["totalSize"]), (offset, 1, 2))
            self.assertEqual(page["Metadata"][0]["ratingKey"], str(101 + offset))
        episode = json.loads(self.request("/library/metadata/202/children", token=SERVER_TOKEN)[2])
        item, = episode["MediaContainer"]["Metadata"]
        self.assertEqual((item["grandparentRatingKey"], item["parentIndex"], item["index"]), ("201", 1, 2))
        detail = json.loads(self.request("/library/metadata/203", token=SERVER_TOKEN)[2])["MediaContainer"]
        self.assertEqual(detail["librarySectionID"], 20)
        self.assertEqual(detail["Metadata"][0], item)

    def test_ranges_artwork_subtitles_and_timeline(self):
        movie_path = "/library/parts/101/1/file.mp4"
        self.assert_status(401, movie_path, headers={"Range": "bytes=4-7"})
        self.assert_status(416, movie_path, token=SERVER_TOKEN, headers={"Range": "bytes=8-7"})
        status, headers, body = self.request(movie_path, token=SERVER_TOKEN, headers={"Range": "bytes=4-7"})
        self.assertEqual((status, body), (206, b"ftyp"))
        self.assertTrue(headers["Content-Range"].startswith("bytes 4-7/"))
        _, headers, photo = self.request("/library/metadata/301/thumb/1", token=SERVER_TOKEN)
        self.assertEqual(headers["Content-Type"], "image/jpeg")
        self.assertTrue(photo.startswith(b"\xff\xd8"))
        _, _, subtitle = self.request("/library/streams/1", token=SERVER_TOKEN)
        self.assertIn(b"Fixture Plex caption.", subtitle)
        for state in ("playing", "paused", "stopped"):
            self.request(f"/:/timeline?state={state}&ratingKey=101&time=1000", token=SERVER_TOKEN)
        events = json.loads(self.request("/fixture/timeline", token=SERVER_TOKEN)[2])
        self.assertEqual([event["state"] for event in events], ["playing", "paused", "stopped"])
