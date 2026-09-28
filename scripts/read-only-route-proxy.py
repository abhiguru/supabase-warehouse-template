#!/usr/bin/env python3
"""Candidate loopback-only, exact-path read proxy for an isolated route drill.

This is not deployed. It requires a private JSON config on the target host.
Only explicitly listed GET/HEAD paths reach the loopback upstream. All other
methods and paths fail closed; no request headers or bodies are logged.
"""

import argparse
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import BoundedSemaphore
from urllib.parse import urlsplit

MAX_RESPONSE = 8 * 1024 * 1024
MAX_CONCURRENT_REQUESTS = 32
REQUEST_TIMEOUT_SECONDS = 10
PRIVATE_UPSTREAM_NETWORKS = tuple(ipaddress.ip_network(value) for value in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
FORWARD_REQUEST_HEADERS = frozenset({"authorization", "apikey", "accept", "range", "origin"})
FORWARD_RESPONSE_HEADERS = frozenset({
    "content-type", "content-disposition", "etag", "last-modified", "content-range",
    "accept-ranges", "cache-control", "content-encoding", "x-content-type-options",
    "access-control-allow-origin", "vary",
})


def load_config(path):
    path = Path(path)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), encoding="utf-8") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("Config must be an owned mode-0600 regular file")
        config = json.load(handle)
    required = {"canonical_host", "listen_port", "upstream_port", "allowed_paths"}
    if set(config) not in (required, required | {"upstream_host"}):
        raise ValueError("Unexpected or missing configuration keys")
    if "upstream_host" in config:
        try:
            address = ipaddress.IPv4Address(config["upstream_host"])
        except (ipaddress.AddressValueError, TypeError) as error:
            raise ValueError("Upstream host must be a private IPv4 literal") from error
        if not any(address in network for network in PRIVATE_UPSTREAM_NETWORKS):
            raise ValueError("Upstream host must be RFC1918 private IPv4")
    host = config["canonical_host"]
    if not isinstance(host, str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{2,252}", host):
        raise ValueError("Invalid canonical host")
    for key in ("listen_port", "upstream_port"):
        value = config[key]
        if type(value) is not int or not 1024 <= value <= 65535:
            raise ValueError("Invalid port")
    if config["listen_port"] == config["upstream_port"]:
        raise ValueError("Proxy and upstream ports must differ")
    paths = config["allowed_paths"]
    if not isinstance(paths, list) or not paths or len(set(paths)) != len(paths):
        raise ValueError("Expected distinct allowed paths")
    for item in paths:
        if (not isinstance(item, str) or not item.startswith("/") or
                "?" in item or "#" in item or "\\" in item or "%" in item or
                "//" in item or any(part in (".", "..") for part in item.split("/"))):
            raise ValueError("Allowed paths must be exact, decoded HTTP paths")
        if item != "/functions/v1/get-public-config" and not re.fullmatch(
                r"/storage/v1/object/authenticated/[^/]+/.+", item):
            raise ValueError("Only public identity and authenticated object reads may be allowed")
    return config


class ReadOnlyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        pass

    def send_safe(self, status, body=b""):
        self.send_response_only(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        self.handle_read()

    def do_HEAD(self):
        self.handle_read()

    def do_POST(self):
        self.send_safe(405)

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST
    do_OPTIONS = do_POST
    do_CONNECT = do_POST
    do_TRACE = do_POST

    def handle_read(self):
        config = self.server.config
        hosts = self.headers.get_all("Host", [])
        if len(hosts) != 1 or hosts[0].lower() != config["canonical_host"]:
            return self.send_safe(421)
        if (len(self.path) > 4096 or self.path.startswith("//") or
                any(ord(char) < 33 or ord(char) == 127 for char in self.path)):
            return self.send_safe(403)
        parsed = urlsplit(self.path)
        if parsed.scheme or parsed.netloc or parsed.fragment or parsed.path not in config["allowed_paths"]:
            return self.send_safe(403)
        if (self.headers.get_all("Upgrade") or self.headers.get_all("Transfer-Encoding") or
                self.headers.get_all("Expect") or self.headers.get_all("Content-Length") or
                any("upgrade" in value.lower() for value in self.headers.get_all("Connection", []))):
            return self.send_safe(403)
        request_headers = {"Host": config["canonical_host"], "Connection": "close"}
        for name in FORWARD_REQUEST_HEADERS:
            values = self.headers.get_all(name, [])
            if len(values) > 1 or any(len(value) > 8192 or any(ord(char) < 32 or ord(char) == 127 for char in value)
                                       for value in values):
                return self.send_safe(403)
            if values:
                request_headers[name] = values[0]
        upstream = http.client.HTTPConnection(config.get("upstream_host", "127.0.0.1"),
                                              config["upstream_port"], timeout=REQUEST_TIMEOUT_SECONDS)
        try:
            upstream.request(self.command, self.path, headers=request_headers)
            response = upstream.getresponse()
            body = b"" if self.command == "HEAD" else response.read(MAX_RESPONSE + 1)
            if len(body) > MAX_RESPONSE:
                return self.send_safe(502)
            self.send_response_only(response.status)
            for name, value in response.getheaders():
                if name.lower() in FORWARD_RESPONSE_HEADERS:
                    self.send_header(name, value)
            if self.command == "HEAD":
                length = response.getheader("Content-Length", "0")
                if not length.isdecimal():
                    length = "0"
            else:
                length = str(len(body))
            self.send_header("Content-Length", length)
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            self.close_connection = True
        except (OSError, ValueError, http.client.HTTPException):
            self.send_safe(502)
        finally:
            upstream.close()


class LoopbackServer(ThreadingHTTPServer):
    daemon_threads = True

    def get_request(self):
        request, client_address = super().get_request()
        request.settimeout(REQUEST_TIMEOUT_SECONDS)
        return request, client_address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                                b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, _request, _client_address):
        # Do not emit request paths or authentication headers into a journal.
        pass

    def __init__(self, config):
        self.config = config
        self.slots = BoundedSemaphore(MAX_CONCURRENT_REQUESTS)
        super().__init__(("127.0.0.1", config["listen_port"]), ReadOnlyHandler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config", help="Path to private mode-0600 JSON configuration")
    args = parser.parse_args()
    server = LoopbackServer(load_config(args.config))
    server.serve_forever(poll_interval=0.2)


if __name__ == "__main__":
    main()
