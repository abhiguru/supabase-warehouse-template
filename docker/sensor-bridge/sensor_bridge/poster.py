# SPDX-License-Identifier: GPL-3.0-or-later
"""Sending the outbox to the backend's ingest-sensor-readings function.

  200          the batch is stored (or was a duplicate): removed from the outbox
  401          the key is refused: everything waits 5 minutes, nothing is dropped
  other 4xx    the batch is refused: kept for 3 tries in all, then dropped
  5xx, 408, 429, network errors and timeouts: kept, retried after 15 s doubling to 10 min
"""

from __future__ import annotations

import asyncio
import http.client
import json
import logging
import urllib.error
import urllib.request
from dataclasses import dataclass, field

from . import __version__
from .queue import Queue

log = logging.getLogger("sensor_bridge")

AUTH_BACKOFF = 300
RETRY_FIRST, RETRY_MAX = 15, 600
MAX_REFUSALS = 3


@dataclass
class PostResult:
    status: int | None  # None: no HTTP answer (network error or timeout)
    body: dict = field(default_factory=dict)
    error: str = ""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # The key must only ever go to the configured URL.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


class HttpPoster:
    def __init__(self, url: str, key: str, timeout: float = 20):
        self._url, self._key, self.timeout = url, key, timeout
        self._opener = urllib.request.build_opener(_NoRedirect)

    def post(self, payload: dict) -> PostResult:
        request = urllib.request.Request(
            self._url, data=json.dumps(payload).encode(), method="POST",
            headers={"Authorization": f"Bearer {self._key}", "Content-Type": "application/json",
                     "User-Agent": f"warehouse-sensor-bridge/{__version__}"})
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                return PostResult(response.status, _json(response.read(65536)))
        except urllib.error.HTTPError as exc:
            try:
                body = _json(exc.read(65536)) if exc.fp else {}
                exc.close()
            except (http.client.HTTPException, OSError):
                body = {}
            return PostResult(exc.code, body)
        except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as exc:
            # Only the error's type: a message may quote the URL, and its query.
            reason = getattr(exc, "reason", exc)
            return PostResult(None, error=type(reason if isinstance(reason, BaseException) else exc).__name__)


def _json(raw: bytes) -> dict:
    try:
        value = json.loads(raw)
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


class Delivery:
    """Drains the outbox hub by hub, in batches of at most max_batch readings."""

    def __init__(self, queue: Queue, poster, bridge_id: str, max_batch: int, run_blocking=None):
        self.queue, self.poster, self.max_batch = queue, poster, max_batch
        self.bridge = {"id": bridge_id, "version": __version__}
        self.run_blocking = run_blocking or asyncio.to_thread
        self.next_at = 0.0
        self.retry = 0
        self.totals = {"posts": 0, "accepted": 0, "duplicates": 0, "rejected": 0, "dropped": 0}
        self.last_status: str = "none"

    async def tick(self, now: float) -> bool:
        """Send what is pending. True when the outbox is empty afterwards."""
        if now < self.next_at:
            return False
        for hub_key in self.queue.pending_hubs():
            while True:
                hub, version, rows = self.queue.take(hub_key, self.max_batch)
                if hub is None or (not rows and not version):
                    break  # readings of a hub whose status was never recorded: impossible by construction
                ids = [i for i, _ in rows]
                payload = {"bridge": self.bridge, "hub": hub, "readings": [r for _, r in rows]}
                result = await self.run_blocking(self.poster.post, payload)
                if not self._handle(result, now, hub, hub_key, ids, version):
                    return False
                if len(rows) < self.max_batch:
                    break
        return self.queue.size() == 0

    def _handle(self, result: PostResult, now: float, hub: dict, hub_key: str, ids: list[int], version: int) -> bool:
        status = result.status
        self.totals["posts"] += 1
        if status is not None and 200 <= status < 300:
            self.queue.ack(hub_key, ids, version)
            self.retry = 0
            counts = {k: result.body.get(k) for k in ("accepted", "duplicates", "rejected")}
            for k, v in counts.items():
                if isinstance(v, int):
                    self.totals[k] += v
            self.last_status = "ok"
            log.info("event=post_ok hub=%s online=%s readings=%d accepted=%s duplicates=%s rejected=%s",
                     hub.get("id"), hub.get("online"), len(ids), counts["accepted"], counts["duplicates"], counts["rejected"])
            return True
        if status == 401:
            self.next_at = now + AUTH_BACKOFF
            self.last_status = "auth_refused"
            log.error("event=auth_refused status=401 retry_in=%d queued=%d", AUTH_BACKOFF, self.queue.size())
            return False
        if status is not None and 400 <= status < 500 and status not in (408, 429):
            dropped = self.queue.fail(hub_key, ids, version, MAX_REFUSALS)
            self.totals["dropped"] += dropped
            self.last_status = f"refused_{status}"
            self._back_off(now)
            log.error("event=post_refused status=%d hub=%s readings=%d dropped=%d retry_in=%d",
                      status, hub.get("id"), len(ids), dropped, self.next_at - now)
            return False
        self.last_status = f"failed_{status}" if status else "unreachable"
        self._back_off(now)
        log.warning("event=post_failed status=%s error=%s readings=%d retry_in=%d queued=%d",
                    status if status is not None else "none", result.error or "-", len(ids), self.next_at - now,
                    self.queue.size())
        return False

    def _back_off(self, now: float) -> None:
        self.retry = RETRY_FIRST if not self.retry else min(RETRY_MAX, self.retry * 2)
        self.next_at = now + self.retry
