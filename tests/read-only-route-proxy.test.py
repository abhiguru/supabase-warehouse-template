import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "read-only-route-proxy.py"
spec = importlib.util.spec_from_file_location("read_only_route_proxy", SOURCE)
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Upstream(BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.seen.append((self.command, self.path, self.headers.get("Authorization")))
        body = b"known-read-only-response"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.seen.append((self.command, self.path, self.headers.get("Authorization")))
        self.send_response(200)
        self.send_header("Content-Length", "24")
        self.end_headers()

    def do_POST(self):
        self.seen.append((self.command, self.path, None))
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


class ReadOnlyProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", free_port()), Upstream)
        cls.server = proxy.LoopbackServer({
            "canonical_host": "api.example.test",
            "listen_port": free_port(),
            "upstream_port": cls.upstream.server_port,
            "allowed_paths": [
                "/functions/v1/get-public-config",
                "/storage/v1/object/authenticated/pilot/test.pdf",
            ],
        })
        cls.threads = [
            threading.Thread(target=cls.upstream.serve_forever, daemon=True),
            threading.Thread(target=cls.server.serve_forever, daemon=True),
        ]
        for thread in cls.threads:
            thread.start()

    @classmethod
    def tearDownClass(cls):
        for server in (cls.server, cls.upstream):
            server.shutdown()
            server.server_close()

    def setUp(self):
        Upstream.seen.clear()

    def request(self, method, path, headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request(method, path, body=body, headers={
            "Host": "api.example.test", **(headers or {})})
        response = connection.getresponse()
        status, payload = response.status, response.read()
        connection.close()
        return status, payload

    def test_exact_reads_and_auth_header_only(self):
        status, payload = self.request("GET", "/functions/v1/get-public-config")
        self.assertEqual((status, payload), (200, b"known-read-only-response"))
        status, payload = self.request("GET", "/storage/v1/object/authenticated/pilot/test.pdf?download=1",
                                       {"Authorization": "Bearer test-token"})
        self.assertEqual((status, payload), (200, b"known-read-only-response"))
        self.assertEqual(Upstream.seen[-1], ("GET", "/storage/v1/object/authenticated/pilot/test.pdf?download=1",
                                           "Bearer test-token"))
        status, payload = self.request("HEAD", "/functions/v1/get-public-config")
        self.assertEqual((status, payload), (200, b""))

    def test_mutations_and_unlisted_paths_never_reach_upstream(self):
        for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS"):
            status, _ = self.request(method, "/functions/v1/get-public-config", body=b"x")
            self.assertEqual(status, 405)
        for path in ("/rest/v1/receipts", "/functions/v1/get-public-config/../send-otp",
                     "/functions/v1/%67et-public-config"):
            status, _ = self.request("GET", path)
            self.assertEqual(status, 403)
        self.assertEqual(Upstream.seen, [])

    def test_wrong_host_upgrade_and_body_are_denied(self):
        for headers in ({"Host": "elsewhere.example"}, {"Upgrade": "websocket"},
                        {"Content-Length": "1"}):
            status, _ = self.request("GET", "/functions/v1/get-public-config", headers)
            self.assertIn(status, (403, 421))
        self.assertEqual(Upstream.seen, [])

    def test_duplicate_host_and_auth_headers_are_denied(self):
        for extra_header in ("Host: api.example.test", "Authorization: Bearer second"):
            with socket.create_connection(("127.0.0.1", self.server.server_port), timeout=3) as connection:
                request = ("GET /functions/v1/get-public-config HTTP/1.1\r\n"
                           "Host: api.example.test\r\nAuthorization: Bearer first\r\n"
                           f"{extra_header}\r\nConnection: close\r\n\r\n")
                connection.sendall(request.encode())
                response = connection.recv(100)
                self.assertTrue(response.startswith((b"HTTP/1.1 403", b"HTTP/1.1 421")))
        self.assertEqual(Upstream.seen, [])

    def test_config_requires_owned_mode_0600_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({
                "canonical_host": "api.example.test", "listen_port": 18001,
                "upstream_port": 18000, "allowed_paths": ["/functions/v1/get-public-config"]}))
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                proxy.load_config(path)
            path.chmod(0o600)
            self.assertEqual(proxy.load_config(path)["listen_port"], 18001)
            unsafe = json.loads(path.read_text())
            unsafe["allowed_paths"].append("/rest/v1/receipts")
            path.write_text(json.dumps(unsafe))
            with self.assertRaises(ValueError):
                proxy.load_config(path)
            link = Path(directory) / "linked.json"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                proxy.load_config(link)


if __name__ == "__main__":
    unittest.main()
