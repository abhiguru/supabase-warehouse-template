# SPDX-License-Identifier: GPL-3.0-or-later
"""The health file: rewritten on every loop, so its age shows the loop is alive.

`python -m sensor_bridge.health` is the image's HEALTHCHECK: it exits 0 when the file
is younger than SENSOR_BRIDGE_HEALTH_MAX_AGE seconds (default 120), else 1. Hub and
delivery states are in the file for people; they do not make the check fail, because a
hub that is switched off is not a reason to restart the bridge.
"""

from __future__ import annotations

import json
import os
import sys
import time


def write(path: str, status: dict) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(status, handle, sort_keys=True)
    os.replace(tmp, path)


def is_fresh(path: str, max_age: float, now: float | None = None) -> bool:
    try:
        age = (time.time() if now is None else now) - os.stat(path).st_mtime
    except OSError:
        return False
    return age <= max_age


def main() -> int:
    path = os.environ.get("SENSOR_BRIDGE_HEALTH_PATH") or "/data/health.json"
    raw = os.environ.get("SENSOR_BRIDGE_HEALTH_MAX_AGE") or "120"
    max_age = int(raw) if raw.isdigit() else 120
    if is_fresh(path, max_age):
        return 0
    print(f"health file {path} missing or older than {max_age} s", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
