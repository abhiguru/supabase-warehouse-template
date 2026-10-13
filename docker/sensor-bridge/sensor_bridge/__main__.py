# SPDX-License-Identifier: GPL-3.0-or-later
"""Command line: run forever (default), --once, --dump, --check-config."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import signal
import sys
import time

from . import __version__
from .config import EX_CONFIG, Config, ConfigError, load
from .poster import Delivery, HttpPoster
from .queue import Queue, open_db
from .scheduler import Bridge, HubRunner
from .state import ChangeDetector

log = logging.getLogger("sensor_bridge")


class RedactingFormatter(logging.Formatter):
    """One line per event, UTC, with every configured secret replaced by ***."""

    converter = time.gmtime

    def __init__(self, secrets: list[str]):
        super().__init__("%(asctime)sZ %(levelname)s %(message)s", "%Y-%m-%dT%H:%M:%S")
        self.secrets = sorted((s for s in secrets if s), key=len, reverse=True)

    def format(self, record: logging.LogRecord) -> str:
        text = super().format(record).replace("\n", " | ")
        for secret in self.secrets:
            text = text.replace(secret, "***")
        return text


def setup_logging(secrets: list[str], level: str = "INFO", stream=None) -> None:
    handler = logging.StreamHandler(stream or sys.stderr)
    handler.setFormatter(RedactingFormatter(secrets))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # python-kasa and asyncio log at their own levels; keep them quiet unless asked.
    for name in ("kasa", "asyncio", "aiohttp"):
        logging.getLogger(name).setLevel(level if level == "DEBUG" else "WARNING")


def kasa_factory(config: Config):
    from .hub import KasaHub

    return lambda host: KasaHub(host, config.username, config.password)


def build(config: Config, hub_factory, poster=None, clock=time.time) -> Bridge:
    db = open_db(config.queue_path)
    queue, detector = Queue(db), ChangeDetector(db, config.heartbeat_seconds)
    runners = [HubRunner(h, hub_factory(h), detector, queue, config) for h in config.hubs]
    delivery = Delivery(queue, poster or HttpPoster(config.ingest_url, config.ingest_key), config.bridge_id,
                        config.max_batch)
    return Bridge(runners, delivery, queue, clock, config.health_path)


async def dump(config: Config, hub_factory, out) -> bool:
    """Connect to every hub, print what it reports, send nothing and store nothing."""
    ok = True
    for host in config.hubs:
        client = hub_factory(host)
        try:
            await client.connect()
            await client.poll()
            data = client.dump()
        except Exception as exc:  # noqa: BLE001 - HubError from KasaHub; reported, then the next hub
            ok = False
            data = {"host": host, "error": str(exc)}
        finally:
            await client.close()
        text = json.dumps(data, indent=2, sort_keys=True, default=str)
        for secret in config.secrets():
            text = text.replace(secret, "***")
        print(text, file=out, flush=True)
    return ok


async def run_forever(bridge: Bridge) -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await bridge.run(stop)


def main(argv: list[str] | None = None, env: dict | None = None, hub_factory=None, poster=None, out=None) -> int:
    parser = argparse.ArgumentParser(prog="sensor_bridge", description=__doc__)
    parser.add_argument("--once", action="store_true", help="poll every hub once, post once, exit (0 = all ok)")
    parser.add_argument("--dump", action="store_true", help="print what each hub reports; posts nothing")
    parser.add_argument("--check-config", action="store_true", help="validate the settings and exit")
    parser.add_argument("--version", action="version", version=__version__)
    args = parser.parse_args(argv)
    out = out or sys.stdout
    try:
        config = load(env, need_ingest=not args.dump)
    except ConfigError as exc:
        setup_logging([])
        log.error("event=config_error reason=%s", exc)
        return EX_CONFIG
    setup_logging(config.secrets(), config.log_level)
    if args.check_config:
        print(json.dumps(config.summary(), indent=2), file=out)
        return 0
    factory = hub_factory or kasa_factory(config)
    if args.dump:
        return 0 if asyncio.run(dump(config, factory, out)) else 1
    bridge = build(config, factory, poster)
    if args.once:
        return 0 if asyncio.run(bridge.once()) else 1
    asyncio.run(run_forever(bridge))
    return 0


if __name__ == "__main__":
    sys.exit(main())
