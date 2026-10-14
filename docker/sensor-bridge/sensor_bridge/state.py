# SPDX-License-Identifier: GPL-3.0-or-later
"""What was last sent per sensor, so only changes and heartbeats leave the bridge.

Kept in the same SQLite file as the outbox. observe() writes without committing; the
caller's Queue.put() commits the decision and the queued reading together, so a crash
can neither lose a change nor queue it twice. After a restart nothing is re-sent until a
value changes or the sensor's heartbeat falls due.
"""

from __future__ import annotations

import sqlite3

from .hub import ChildReading

SCHEMA = """
CREATE TABLE IF NOT EXISTS last_sent (
  external_id TEXT PRIMARY KEY,
  temperature REAL,
  humidity REAL,
  battery_low INTEGER,
  sent_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


class ChangeDetector:
    def __init__(self, db: sqlite3.Connection, heartbeat_seconds: int):
        self.db, self.heartbeat_seconds = db, heartbeat_seconds
        with db:
            db.executescript(SCHEMA)

    def observe(self, child: ChildReading, now: float) -> str | None:
        """'change', 'heartbeat' or None (nothing to send). Records what is sent, uncommitted."""
        row = self.db.execute("SELECT temperature, humidity, battery_low, sent_at FROM last_sent WHERE external_id=?",
                              (child.external_id,)).fetchone()
        low = None if child.battery_low is None else int(child.battery_low)
        if row is None or (row[0], row[1], row[2]) != (child.temperature, child.humidity, low):
            kind = "change"
        elif now - row[3] >= self.heartbeat_seconds:
            kind = "heartbeat"
        else:
            return None
        self.db.execute(
            "INSERT INTO last_sent (external_id, temperature, humidity, battery_low, sent_at) VALUES (?,?,?,?,?) "
            "ON CONFLICT (external_id) DO UPDATE SET temperature=excluded.temperature, humidity=excluded.humidity, "
            "battery_low=excluded.battery_low, sent_at=excluded.sent_at",
            (child.external_id, child.temperature, child.humidity, low, now))
        return kind

    def get(self, key: str) -> str | None:
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def set(self, key: str, value: str) -> None:
        with self.db:
            self.db.execute("INSERT INTO meta (key, value) VALUES (?,?) ON CONFLICT (key) DO UPDATE SET value=excluded.value",
                            (key, value))
