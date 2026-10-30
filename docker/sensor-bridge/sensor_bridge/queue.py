# SPDX-License-Identifier: GPL-3.0-or-later
"""The outbox: readings and hub status waiting for the backend, kept in SQLite (WAL).

A reading is identified by (external_id, measured_at), as in the backend, so putting the
same reading twice keeps one row and sending it twice is harmless.
"""

from __future__ import annotations

import json
import os
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  hub_key TEXT NOT NULL,
  external_id TEXT NOT NULL,
  measured_at TEXT NOT NULL,
  payload TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  queued_at REAL NOT NULL,
  UNIQUE (external_id, measured_at)
);
CREATE INDEX IF NOT EXISTS outbox_hub ON outbox (hub_key, id);
CREATE TABLE IF NOT EXISTS hub_status (
  hub_key TEXT PRIMARY KEY,
  payload TEXT NOT NULL,
  version INTEGER NOT NULL,
  sent_version INTEGER NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0
);
"""


def open_db(path: str) -> sqlite3.Connection:
    if path != ":memory:":
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA busy_timeout=5000")
    return db


class Queue:
    def __init__(self, db: sqlite3.Connection, max_rows: int = 200_000):
        self.db, self.max_rows = db, max_rows
        with db:
            db.executescript(SCHEMA)

    def put(self, hub_key: str, readings: list[dict], now: float) -> int:
        """Queue readings and commit (together with anything the caller wrote before)."""
        with self.db:
            before = self.db.total_changes
            self.db.executemany(
                "INSERT OR IGNORE INTO outbox (hub_key, external_id, measured_at, payload, queued_at) VALUES (?,?,?,?,?)",
                [(hub_key, r["external_id"], r["measured_at"], json.dumps(r, sort_keys=True), now) for r in readings],
            )
            return self.db.total_changes - before

    def set_hub(self, hub_key: str, hub: dict, force: bool = False) -> bool:
        """Record the hub's status; it is sent again when it changed, or always with force."""
        payload = json.dumps(hub, sort_keys=True)
        with self.db:
            row = self.db.execute("SELECT payload, version FROM hub_status WHERE hub_key=?", (hub_key,)).fetchone()
            if row is None:
                self.db.execute("INSERT INTO hub_status (hub_key, payload, version) VALUES (?,?,1)", (hub_key, payload))
                return True
            if row[0] == payload and not force:
                return False
            self.db.execute("UPDATE hub_status SET payload=?, version=version+1, attempts=0 WHERE hub_key=?",
                            (payload, hub_key))
            return True

    def rekey(self, old: str, new: str) -> None:
        """Move a hub's queued readings to a new key; its old status row is dropped (the caller sets the new one)."""
        if old == new:
            return
        with self.db:
            self.db.execute("UPDATE outbox SET hub_key=? WHERE hub_key=?", (new, old))
            self.db.execute("DELETE FROM hub_status WHERE hub_key=?", (old,))

    def pending_hubs(self) -> list[str]:
        rows = self.db.execute(
            "SELECT hub_key FROM hub_status WHERE version > sent_version "
            "UNION SELECT DISTINCT hub_key FROM outbox ORDER BY 1").fetchall()
        return [r[0] for r in rows]

    def take(self, hub_key: str, limit: int) -> tuple[dict | None, int, list[tuple[int, dict]]]:
        """The hub's status, its version and up to `limit` oldest readings. Nothing is removed."""
        row = self.db.execute("SELECT payload, version, sent_version FROM hub_status WHERE hub_key=?",
                              (hub_key,)).fetchone()
        rows = self.db.execute("SELECT id, payload FROM outbox WHERE hub_key=? ORDER BY id LIMIT ?",
                               (hub_key, limit)).fetchall()
        readings = [(i, json.loads(p)) for i, p in rows]
        if row is None:
            return None, 0, readings
        hub, version, sent = json.loads(row[0]), row[1], row[2]
        return hub, (version if version > sent else 0), readings

    def ack(self, hub_key: str, ids: list[int], version: int) -> None:
        with self.db:
            self.db.executemany("DELETE FROM outbox WHERE id=?", [(i,) for i in ids])
            if version:
                self.db.execute("UPDATE hub_status SET sent_version=MAX(sent_version, ?), attempts=0 WHERE hub_key=?",
                                (version, hub_key))

    def fail(self, hub_key: str, ids: list[int], version: int, max_attempts: int = 3) -> int:
        """Count a refused send; rows refused max_attempts times are dropped. Returns how many."""
        with self.db:
            self.db.executemany("UPDATE outbox SET attempts=attempts+1 WHERE id=?", [(i,) for i in ids])
            dropped = self.db.execute("DELETE FROM outbox WHERE hub_key=? AND attempts>=?",
                                      (hub_key, max_attempts)).rowcount
            if version:
                self.db.execute("UPDATE hub_status SET attempts=attempts+1 WHERE hub_key=?", (hub_key,))
                self.db.execute("UPDATE hub_status SET sent_version=version, attempts=0 "
                                "WHERE hub_key=? AND attempts>=?", (hub_key, max_attempts))
            return dropped

    def prune(self, now: float, max_age_seconds: float) -> int:
        """Drop readings the backend would refuse as too old, and the oldest beyond max_rows."""
        with self.db:
            old = self.db.execute("DELETE FROM outbox WHERE queued_at < ?", (now - max_age_seconds,)).rowcount
            over = self.db.execute(
                "DELETE FROM outbox WHERE id IN (SELECT id FROM outbox ORDER BY id DESC LIMIT -1 OFFSET ?)",
                (self.max_rows,)).rowcount
            return old + over

    def size(self) -> int:
        return self.db.execute("SELECT count(*) FROM outbox").fetchone()[0]
