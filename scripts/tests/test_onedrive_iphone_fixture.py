"""Exercise OAuth device-code requests over the iPhone fixture's real TLS listener."""

from http.client import HTTPSConnection
import json
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import threading
import unittest
from urllib.parse import urlencode

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    from onedrive_iphone_fixture import CLIENT_ID, Handler, OneDriveFixtureServer
    from webdav_fixture import create_certificate
finally:
    sys.path.pop(0)


class ObservedOneDriveServer(OneDriveFixtureServer):
    def __init__(self, *args, **kwargs):
        self.accepted = threading.Event()
        super().__init__(*args, **kwargs)

    def get_request(self):
        connection = super().get_request()
        self.accepted.set()
        return connection


class OneDriveIPhoneFixtureTests(unittest.TestCase):
    def test_idle_tcp_peer_does_not_block_trusted_device_code_request(self):
        with tempfile.TemporaryDirectory() as directory:
            certificate, key = create_certificate(Path(directory))
            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(certificate, key)
            trusted = ssl.create_default_context(cafile=str(certificate))
            with ObservedOneDriveServer(("127.0.0.1", 0), Handler, ssl_context=server_context) as server:
                worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
                worker.start()
                try:
                    with socket.create_connection(server.server_address, timeout=2) as idle:
                        self.assertTrue(server.accepted.wait(2), "Listener did not accept the idle connection")
                        address, port = server.server_address
                        client = HTTPSConnection(address, port, context=trusted, timeout=2)
                        try:
                            client.request("POST", "/auth/consumers/oauth2/v2.0/devicecode", body=urlencode({
                                "client_id": CLIENT_ID,
                                "scope": "https://graph.microsoft.com/Files.Read offline_access",
                            }), headers={"Content-Type": "application/x-www-form-urlencoded"})
                            response = client.getresponse()
                            self.assertEqual(response.status, 200)
                            device_code = json.loads(response.read())
                            self.assertEqual(device_code["user_code"], "OD-PHONE")
                            self.assertTrue(device_code["device_code"].startswith("fixture-device-"))
                            self.assertNotEqual(idle.fileno(), -1)
                        finally:
                            client.close()
                finally:
                    server.shutdown()
                    worker.join(timeout=2)
