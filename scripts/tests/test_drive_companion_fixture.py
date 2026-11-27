import http.client
import json
from pathlib import Path
import ssl
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from drive_companion_fixture import FixtureServer, create_certificate


class DriveCompanionFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        certificate, key = create_certificate(Path(directory.name), "Drive Companion Test")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        cls.client_context = ssl.create_default_context(cafile=str(certificate))
        cls.server = FixtureServer(0, ssl_context=context)
        cls.addClassCleanup(cls.server.server_close)
        thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        thread.start()
        cls.addClassCleanup(thread.join, 5)
        cls.addClassCleanup(cls.server.shutdown)

    def request(self, method, path, *, token=None, body=None, headers=None):
        connection = http.client.HTTPSConnection("127.0.0.1", self.server.server_port,
                                                 context=self.client_context, timeout=5)
        headers = dict(headers or {})
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if body is not None:
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, response.headers, response.read()
        finally:
            connection.close()

    def pairing(self):
        status, _, body = self.request("POST", "/v1/pairings", body=b"{}")
        self.assertEqual(status, 201)
        pairing = json.loads(body)
        self.assertRegex(pairing["id"], r"^[A-Za-z0-9_-]{24}$")
        self.assertRegex(pairing["secret"], r"^[A-Za-z0-9_-]{43}$")
        self.assertEqual(pairing["verificationUrl"], f"{self.server.origin}/pair")
        self.assertEqual(pairing["code"], "AB23-CD45")
        self.assertGreater(pairing["expiresIn"], 10)
        return pairing

    def approve(self, pairing):
        path = "/v1/pairings/" + pairing["id"]
        self.assertEqual(self.request("GET", path, token="wrong")[0], 404)
        for _ in range(2):
            status, _, body = self.request("GET", path, token=pairing["secret"])
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body), {"status": "pending"})
        status, _, body = self.request("GET", path, token=pairing["secret"])
        self.assertEqual(status, 200)
        approved = json.loads(body)
        self.assertEqual(approved["status"], "approved")
        self.assertRegex(approved["connection"]["token"], r"^[A-Za-z0-9_-]{43}$")
        return approved["connection"]

    def test_pairing_reconnect_keeps_exact_selection_and_revokes_only_the_old_connection(self):
        first = self.pairing()
        second = self.pairing()
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(self.request("GET", "/v1/connection", token=first["secret"])[0], 401)
        first_connection = self.approve(first)
        second_connection = self.approve(second)
        first_token, second_token = first_connection["token"], second_connection["token"]
        self.assertNotIn(first_token, (first["secret"], second_token))
        self.assertEqual(first_connection["files"], second_connection["files"])
        files = second_connection["files"]
        self.assertEqual([file["name"] for file in files],
                         ["Drive Fixture Clip.mp4", "Drive Fixture Clip.en.srt"])
        self.assertEqual(files[0]["parentId"], files[1]["parentId"])
        first_path = "/v1/pairings/" + first["id"]
        self.assertEqual(self.request("DELETE", first_path, token=second["secret"])[0], 404)
        self.assertEqual(self.request("DELETE", first_path, token=first["secret"])[0], 204)
        self.assertEqual(self.request("GET", first_path, token=first["secret"])[0], 404)
        status, _, body = self.request("GET", "/v1/connection", token=first_token)
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"files": files})
        self.assertEqual(self.request("DELETE", "/v1/connection", token=first_token)[0], 204)
        self.assertEqual(self.request("GET", "/v1/connection", token=first_token)[0], 401)
        self.assertEqual(self.request("GET", "/v1/connection", token=second_token)[0], 200)

    def test_exact_range_and_caption_require_an_active_selection(self):
        connection = self.approve(self.pairing())
        token = connection["token"]
        clip, caption = connection["files"]
        path = "/v1/files/" + clip["id"]
        self.assertEqual(self.request("GET", path)[0], 401)
        self.assertEqual(self.request("GET", "/v1/files/unselected", token=token)[0], 404)
        status, headers, body = self.request("GET", path, token=token)
        self.assertEqual(status, 200)
        self.assertEqual(int(headers["Content-Length"]), clip["size"])
        self.assertEqual(len(body), clip["size"])
        status, headers, portion = self.request("GET", path, token=token, headers={"Range": "bytes=5-15"})
        self.assertEqual(status, 206)
        self.assertEqual(headers["Content-Range"], f"bytes 5-15/{clip['size']}")
        self.assertEqual(int(headers["Content-Length"]), 11)
        self.assertEqual(portion, body[5:16])
        invalid = f"bytes={clip['size']}-{clip['size']}"
        status, headers, _ = self.request("GET", path, token=token, headers={"Range": invalid})
        self.assertEqual(status, 416)
        self.assertEqual(headers["Content-Range"], f"bytes */{clip['size']}")
        status, _, body = self.request("GET", "/v1/files/" + caption["id"], token=token)
        self.assertEqual(status, 200)
        self.assertIn(b"Google Drive fixture caption.", body)
        self.assertEqual(self.request("DELETE", "/v1/connection", token=token)[0], 204)
        self.assertEqual(self.request("GET", path, token=token, headers={"Range": "bytes=5-15"})[0], 401)


if __name__ == "__main__":
    unittest.main()
