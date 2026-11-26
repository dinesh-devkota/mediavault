"""Regression coverage for the disposable TLS fixture, never production transport."""

from contextlib import contextmanager
import http.client
import importlib.util
from pathlib import Path
import socket
import ssl
import tempfile
import threading
import time
import unittest


spec = importlib.util.spec_from_file_location("webdav_fixture", Path(__file__).parents[1] / "webdav_fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class QuietHandler(fixture.Handler):
    def log_message(self, *_args):
        pass


class ObservedServer(fixture.TLSFixtureServer):
    def __init__(self, *args, **kwargs):
        self.accepted = threading.Event()
        self.handshakes = []
        self.handshake_observed = threading.Event()
        super().__init__(*args, **kwargs)

    def get_request(self):
        connection = super().get_request()
        self.accepted.set()
        return connection

    def log_handshake(self, address, *, elapsed, protocol=None, error=None):
        self.handshakes.append((elapsed, protocol, type(error).__name__ if error else None))
        self.handshake_observed.set()

    def handle_error(self, *_args):
        # Invalid/untrusted TLS handshakes below intentionally end a worker.
        pass


class WebDAVFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.certificate, cls.key = fixture.create_certificate(Path(cls.directory.name))
        cls.trusted = ssl.create_default_context(cafile=str(cls.certificate))

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    @contextmanager
    def server(self, *, timeout=5, handshake_timeout=None):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.certificate, self.key)
        with ObservedServer(("127.0.0.1", 0), QuietHandler,
                            ssl_context=context, connection_timeout=timeout,
                            handshake_timeout=timeout if handshake_timeout is None else handshake_timeout) as server:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
            thread.start()
            try:
                yield server
            finally:
                server.shutdown()
                thread.join(timeout=2)
                self.assertFalse(thread.is_alive())

    def request(self, server, method="PROPFIND", path="/dav/", *, context=None, authorized=True, headers=None):
        client = http.client.HTTPSConnection("127.0.0.1", server.server_port,
                                           context=context or self.trusted, timeout=2)
        request_headers = {"Depth": "1"}
        if authorized:
            request_headers["Authorization"] = fixture.AUTHORIZATION
        request_headers.update(headers or {})
        try:
            client.request(method, path, headers=request_headers)
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def test_idle_raw_tcp_connection_does_not_block_authenticated_tls_request(self):
        with self.server() as server, socket.create_connection(server.server_address, timeout=2) as idle:
            # Ensure the idle socket reaches the listener before the real client.
            self.assertTrue(server.accepted.wait(2), "Listener never accepted the speculative connection")
            status, _, body = self.request(server)
            self.assertEqual(status, 207)
            self.assertIn(b"/dav/Movies/", body)
            # It stayed open throughout the successful concurrent request.
            self.assertNotEqual(idle.fileno(), -1)

    def test_idle_handshake_is_bounded_and_server_remains_available(self):
        with self.server(timeout=0.15) as server, socket.create_connection(server.server_address, timeout=2) as idle:
            self.assertTrue(server.accepted.wait(2))
            idle.settimeout(2)
            self.assertEqual(idle.recv(1), b"", "Idle TLS peer should be closed after the worker timeout")
            self.assertTrue(server.handshake_observed.wait(2))
            self.assertEqual(server.handshakes[0][1:], (None, "TimeoutError"))
            self.assertEqual(self.request(server)[0], 207)

    def test_completed_handshake_is_distinguished_from_idle_http_timeout(self):
        with self.server(timeout=0.15) as server:
            with socket.create_connection(server.server_address, timeout=2) as raw:
                with self.trusted.wrap_socket(raw, server_hostname="127.0.0.1") as client:
                    self.assertTrue(server.handshake_observed.wait(2))
                    self.assertIsNotNone(server.handshakes[0][1])
                    self.assertIsNone(server.handshakes[0][2])
                    self.assertEqual(client.recv(1), b"", "Idle HTTP read remains bounded after TLS completes")
            self.assertEqual(self.request(server)[0], 207)

    def test_delayed_tls_handshake_uses_its_own_budget_then_restores_http_idle_limit(self):
        with self.server(timeout=0.1, handshake_timeout=1) as server:
            with socket.create_connection(server.server_address, timeout=2) as raw:
                self.assertTrue(server.accepted.wait(2))
                # Deliberately exceed the HTTP idle budget before ClientHello.
                # The former shared timeout closed this otherwise valid client.
                time.sleep(0.25)
                with self.trusted.wrap_socket(raw, server_hostname="127.0.0.1") as client:
                    self.assertTrue(server.handshake_observed.wait(2))
                    self.assertGreaterEqual(server.handshakes[0][0], 0.2)
                    self.assertIsNone(server.handshakes[0][2])
                    started = time.monotonic()
                    self.assertEqual(client.recv(1), b"")
                    self.assertLess(time.monotonic() - started, 0.8,
                                    "TLS completion must restore the shorter HTTP idle timeout")
            self.assertEqual(self.request(server)[0], 207)

    def test_authentication_range_reads_and_certificate_validation_remain_enforced(self):
        with self.server() as server:
            self.assertEqual(self.request(server, authorized=False)[0], 401)
            status, headers, body = self.request(server, "GET", "/dav/Movies/bytes.bin", headers={"Range": "bytes=3-6"})
            self.assertEqual((status, body), (206, b"3456"))
            self.assertEqual(headers["Content-Range"], "bytes 3-6/10")
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.request(server, context=ssl.create_default_context())
            self.assertEqual(self.request(server)[0], 207)


if __name__ == "__main__":
    unittest.main()
