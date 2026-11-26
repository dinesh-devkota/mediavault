import ssl
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jellyfin_tvos_fixture import Handler


class JellyfinFixtureResponseTests(unittest.TestCase):
    def client(self, failure):
        response = Mock()
        response.wfile.write.side_effect = failure
        return response

    def test_handles_tls_eof_when_player_cancels_hls_body(self):
        response = self.client(ssl.SSLEOFError("client canceled the request"))
        Handler.send_body(response, 200, b"segment", [("Content-Type", "video/mp2t")])
        response.send_response.assert_called_once_with(200)
        response.send_header.assert_any_call("Content-Length", "7")
        response.wfile.write.assert_called_once_with(b"segment")

    def test_unexpected_ssl_failures_remain_visible(self):
        response = self.client(ssl.SSLError("unexpected transport failure"))
        with self.assertRaises(ssl.SSLError):
            Handler.send_body(response, 200, b"segment")
