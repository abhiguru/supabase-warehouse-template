import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
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
        if self.path.startswith("/storage/v1/object/sign/"):
            self.send_header("Cache-Control", "public, max-age=3600")
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
                "/storage/v1/object/sign/documents/known.pdf",
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

    def test_exact_signed_object_requires_token_and_disables_caching(self):
        path = "/storage/v1/object/sign/documents/known.pdf?token=short-lived"
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request("GET", path, headers={"Host": "api.example.test"})
        response = connection.getresponse()
        self.assertEqual((response.status, response.read()), (200, b"known-read-only-response"))
        self.assertEqual(response.getheader("Cache-Control"), "private, no-store")
        self.assertEqual(response.getheader("Cloudflare-CDN-Cache-Control"), "no-store")
        connection.close()
        self.assertEqual(Upstream.seen, [("GET", path, None)])
        for unsafe in ("/storage/v1/object/sign/documents/known.pdf",
                       path + "&token=second", path + "&download=1",
                       "/storage/v1/object/sign/documents/other.pdf?token=short-lived"):
            status, _ = self.request("GET", unsafe)
            self.assertEqual(status, 403)
        for header in ({"Authorization": "Bearer service-role"}, {"apikey": "service-role"}):
            status, _ = self.request("GET", path, header)
            self.assertEqual(status, 403)
        self.assertEqual(Upstream.seen, [("GET", path, None)])

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

    def test_private_ipv4_upstream_config_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            config = {
                "canonical_host": "api.example.test", "listen_port": 18001,
                "upstream_port": 8000, "allowed_paths": ["/functions/v1/get-public-config"],
                "upstream_host": "172.22.0.8",
            }
            path.write_text(json.dumps(config))
            path.chmod(0o600)
            self.assertEqual(proxy.load_config(path)["upstream_host"], "172.22.0.8")
            for unsafe in ("8.8.8.8", "127.0.0.1", "169.254.1.2", "internal.example.test", "::1"):
                config["upstream_host"] = unsafe
                path.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    proxy.load_config(path)

    def test_concurrency_limit_rejects_excess_without_upstream(self):
        server = proxy.LoopbackServer({
            "canonical_host": "api.example.test", "listen_port": free_port(),
            "upstream_port": self.upstream.server_port,
            "allowed_paths": ["/functions/v1/get-public-config"],
        })
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        clients = []
        try:
            for _ in range(proxy.MAX_CONCURRENT_REQUESTS):
                connection = socket.create_connection(("127.0.0.1", server.server_port), timeout=3)
                connection.sendall(b"GET /functions/v1/get-public-config HTTP/1.1\r\n"
                                   b"Host: api.example.test\r\n")
                clients.append(connection)
            for _ in range(100):
                if server.slots._value == 0:
                    break
                time.sleep(0.01)
            self.assertEqual(server.slots._value, 0)
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("GET", "/functions/v1/get-public-config", headers={"Host": "api.example.test"})
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (503, b""))
            connection.close()
            self.assertEqual(Upstream.seen, [])
        finally:
            for client in clients:
                client.close()
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
