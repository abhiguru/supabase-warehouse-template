# SPDX-License-Identifier: GPL-3.0-or-later
import asyncio
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from sensor_bridge import __version__
from sensor_bridge.poster import Delivery, HttpPoster
from sensor_bridge.queue import Queue, open_db

from .fakes import FAKE_KEY, T0, FakePoster, cid, run_inline

HUB = {"id": "HUB-1", "host": "192.0.2.10", "online": True, "firmware": "1.4.0"}


def reading(n: int, second: int = 0) -> dict:
    return {"external_id": cid(n), "measured_at": f"2026-10-03T04:00:{second:02d}Z", "temperature": 20.0 + n,
            "humidity": None, "kind": "change"}


class DeliveryTest(unittest.TestCase):
    def setUp(self):
        self.queue = Queue(open_db(":memory:"))
        self.queue.set_hub("h", HUB)

    def delivery(self, poster, max_batch=200):
        return Delivery(self.queue, poster, "bridge-a", max_batch, run_blocking=run_inline)

    def tick(self, delivery, at):
        return asyncio.run(delivery.tick(at))

    def test_payload_has_the_contract_shape(self):
        self.queue.put("h", [reading(1)], T0)
        poster = FakePoster()
        self.assertTrue(self.tick(self.delivery(poster), T0))
        self.assertEqual(poster.payloads, [{"bridge": {"id": "bridge-a", "version": __version__}, "hub": HUB,
                                            "readings": [reading(1)]}])
        self.assertEqual(self.queue.size(), 0)

    def test_hub_status_alone_is_sent_once(self):
        poster = FakePoster()
        delivery = self.delivery(poster)
        self.assertTrue(self.tick(delivery, T0))
        self.assertTrue(self.tick(delivery, T0 + 60))
        self.assertEqual(len(poster.payloads), 1)
        self.assertEqual(poster.payloads[0]["readings"], [])

    def test_batches_respect_max_batch_and_drain_in_one_tick(self):
        self.queue.put("h", [reading(n, n) for n in range(1, 6)], T0)
        poster = FakePoster()
        self.assertTrue(self.tick(self.delivery(poster, max_batch=2), T0))
        self.assertEqual([len(p["readings"]) for p in poster.payloads], [2, 2, 1])

    def test_5xx_keeps_the_batch_and_the_resend_is_identical(self):
        self.queue.put("h", [reading(1), reading(2)], T0)
        poster = FakePoster(503)
        delivery = self.delivery(poster)
        self.assertFalse(self.tick(delivery, T0))
        self.assertEqual(self.queue.size(), 2)
        self.assertFalse(self.tick(delivery, T0 + 14), "waits 15 s")
        self.assertEqual(len(poster.payloads), 1)
        self.assertTrue(self.tick(delivery, T0 + 15))
        self.assertEqual(poster.payloads[0], poster.payloads[1], "same measured_at, so the backend dedupes")
        self.assertEqual(self.queue.size(), 0)

    def test_transient_failures_back_off_15_s_doubling_to_10_min(self):
        self.queue.put("h", [reading(1)], T0)
        poster = FakePoster(*([None] * 9))
        delivery = self.delivery(poster)
        waits, at = [], T0
        for _ in range(8):
            self.tick(delivery, at)
            waits.append(delivery.next_at - at)
            at = delivery.next_at
        self.assertEqual(waits, [15, 30, 60, 120, 240, 480, 600, 600])
        self.assertEqual(self.queue.size(), 1, "nothing is dropped for network errors")
        self.tick(delivery, at)
        self.tick(delivery, delivery.next_at)  # the 9 failures are used up: 200
        self.assertEqual(self.queue.size(), 0)
        self.assertEqual(delivery.retry, 0, "a success resets the backoff")

    def test_401_waits_5_minutes_and_keeps_everything(self):
        self.queue.put("h", [reading(1)], T0)
        poster = FakePoster(401, 401)
        delivery = self.delivery(poster)
        for _ in range(2):
            self.assertFalse(self.tick(delivery, delivery.next_at or T0))
        self.assertEqual(len(poster.payloads), 2)
        self.assertEqual(delivery.last_status, "auth_refused")
        self.assertFalse(self.tick(delivery, T0 + 600 - 1))
        self.assertEqual(len(poster.payloads), 2, "no post inside the 5 minutes")
        self.assertTrue(self.tick(delivery, T0 + 600))
        self.assertEqual(self.queue.size(), 0)
        self.assertEqual(poster.readings(), [reading(1)])

    def test_three_400s_drop_the_batch_and_the_next_one_goes_through(self):
        self.queue.put("h", [reading(1)], T0)
        poster = FakePoster(400, 400, 400)
        delivery = self.delivery(poster, max_batch=1)
        at = T0
        for expected_size in (1, 1, 0):
            self.tick(delivery, at)
            self.assertEqual(self.queue.size(), expected_size)
            at = delivery.next_at
        self.assertEqual(delivery.totals["dropped"], 1)
        self.queue.put("h", [reading(2)], at)
        self.assertTrue(self.tick(delivery, at))
        self.assertEqual(poster.readings(), [reading(2)])

    def test_408_and_429_are_retried_not_dropped(self):
        self.queue.put("h", [reading(1)], T0)
        poster = FakePoster(429, 408, 429, 408)
        delivery = self.delivery(poster)
        at = T0
        for _ in range(4):
            self.tick(delivery, at)
            at = delivery.next_at
        self.assertEqual(self.queue.size(), 1)


class Recorder(BaseHTTPRequestHandler):
    requests: list = []
    answer = (200, {"success": True, "accepted": 1, "duplicates": 0, "rejected": 0, "devices": 1})

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        Recorder.requests.append((self.path, dict(self.headers), json.loads(body)))
        status, answer = Recorder.answer
        if status == 302:
            self.send_response(302)
            self.send_header("Location", "/elsewhere")
            self.end_headers()
            return
        data = json.dumps(answer).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class HttpPosterTest(unittest.TestCase):
    """Against a server on 127.0.0.1 (works inside `docker run --network none`)."""

    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/functions/v1/ingest-sensor-readings"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Recorder.requests = []

    def test_posts_json_with_the_bearer_key(self):
        Recorder.answer = (200, {"success": True, "accepted": 1, "duplicates": 0, "rejected": 0, "devices": 1})
        result = HttpPoster(self.url, FAKE_KEY, timeout=5).post({"hub": HUB, "readings": []})
        self.assertEqual((result.status, result.body["accepted"]), (200, 1))
        path, headers, body = Recorder.requests[0]
        self.assertEqual(path, "/functions/v1/ingest-sensor-readings")
        self.assertEqual(headers["Authorization"], f"Bearer {FAKE_KEY}")
        self.assertEqual(headers["Content-Type"], "application/json")
        self.assertEqual(body, {"hub": HUB, "readings": []})

    def test_error_statuses_are_returned_not_raised(self):
        Recorder.answer = (401, {"success": False, "error": "Unauthorized"})
        self.assertEqual(HttpPoster(self.url, FAKE_KEY, timeout=5).post({}).status, 401)
        Recorder.answer = (503, {"success": False})
        self.assertEqual(HttpPoster(self.url, FAKE_KEY, timeout=5).post({}).status, 503)

    def test_a_redirect_is_not_followed(self):
        Recorder.answer = (302, {})
        result = HttpPoster(self.url, FAKE_KEY, timeout=5).post({})
        self.assertEqual(result.status, 302)
        self.assertEqual(len(Recorder.requests), 1, "the key went to one URL only")

    def test_unreachable_is_status_none_with_the_error_type_only(self):
        result = HttpPoster("http://127.0.0.1:9/x?" + "secret=1", FAKE_KEY, timeout=2).post({})
        self.assertIsNone(result.status)
        self.assertNotIn("secret", result.error)
        self.assertTrue(result.error)


if __name__ == "__main__":
    unittest.main()
