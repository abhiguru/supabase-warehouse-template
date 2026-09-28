#!/usr/bin/env python3
"""Run and monitor private operator backups on a UUID-pinned local disk."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
from datetime import datetime, timedelta, timezone


NAME = re.compile(r"^warehouse-\d{8}T\d{6}Z$")
REQUIRED = {
    "state_dir", "source_checkout", "recovery_secrets_dir", "mountpoint",
    "mount_uuid", "archive_dir", "local_backup_dir", "evidence_dir",
    "retention_hours", "minimum_generations", "freshness_minutes",
}
ROOT = Path(__file__).resolve().parent.parent


def fail(message):
    raise RuntimeError(message)


def private_dir(path):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink() or path.resolve(strict=True) != path:
        fail("A private directory path is missing, relative or symlinked")
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        fail(f"Private directory must be owned by this user and mode 0700: {path}")
    return path


def source_dir(path):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink() or path.resolve(strict=True) != path:
        fail("Source checkout path is missing, relative or symlinked")
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        fail("Source checkout must be an existing directory owned by this user")
    return path


def load_config(path):
    path = Path(path)
    info = path.stat()
    if path.is_symlink() or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        fail("Backup config must be owned by this user and mode 0600")
    config = json.loads(path.read_text())
    if set(config) != REQUIRED:
        fail("Backup config has missing or unexpected keys")
    for key in ("retention_hours", "minimum_generations", "freshness_minutes"):
        if type(config[key]) is not int or config[key] < 1:
            fail(f"Invalid {key}")
    if config["minimum_generations"] < 2 or config["retention_hours"] != 48 or config["freshness_minutes"] > 50:
        fail("Backup retention or freshness differs from the approved policy")
    config["source_checkout"] = source_dir(config["source_checkout"])
    for key in ("state_dir", "recovery_secrets_dir", "mountpoint",
                "archive_dir", "local_backup_dir", "evidence_dir"):
        config[key] = private_dir(config[key])
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", config["mount_uuid"]):
        fail("Invalid mount UUID")
    if config["archive_dir"].parent != config["mountpoint"]:
        fail("Archive directory must be directly under the pinned mount")
    if config["local_backup_dir"].is_relative_to(ROOT) or config["evidence_dir"].is_relative_to(ROOT):
        fail("Private backup state must stay outside the Git checkout")
    return config


def check_mount(config):
    mount = config["mountpoint"]
    if not os.path.ismount(mount):
        fail("Backup disk is not mounted")
    result = subprocess.run(
        ["findmnt", "--json", "--target", str(mount), "--output", "TARGET,UUID,FSTYPE,OPTIONS"],
        capture_output=True, text=True, check=True,
    )
    entries = json.loads(result.stdout).get("filesystems", [])
    if len(entries) != 1 or entries[0]["target"] != str(mount):
        fail("Backup mount target does not match")
    if entries[0].get("uuid", "").lower() != config["mount_uuid"].lower() or entries[0].get("fstype") != "ext4":
        fail("Backup filesystem UUID or type does not match")
    options = set(entries[0].get("options", "").split(","))
    if not {"rw", "nosuid", "nodev", "noexec"}.issubset(options):
        fail("Backup mount options are not restricted")
    if config["archive_dir"].stat().st_dev != mount.stat().st_dev:
        fail("Archives do not reside on the backup filesystem")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as data:
        for chunk in iter(lambda: data.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path, payload):
    temporary = path.with_name(path.name + ".new")
    if temporary.exists() or temporary.is_symlink():
        fail("Temporary record already exists")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(temporary, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def run_logged(command, log, env=None):
    with open(log, "a", encoding="utf-8") as output:
        output.write("ACTION " + Path(command[0]).name + "\n")
        output.flush()
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        fail(f"Backup stage failed with exit {result.returncode}; see private run log")


def records(config):
    result = []
    for sidecar in config["archive_dir"].glob("warehouse-*.tar.receipt.json"):
        info = sidecar.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            fail("Unexpected receipt type, owner or mode")
        record = json.loads(sidecar.read_text())
        name = record.get("backup_name", "")
        if not NAME.fullmatch(name) or sidecar.name != name + ".tar.receipt.json":
            fail("Invalid backup receipt name")
        if record.get("mount_uuid", "").lower() != config["mount_uuid"].lower():
            fail("Backup receipt belongs to another filesystem")
        created = datetime.fromisoformat(record["created_at"])
        if created.tzinfo is None:
            fail("Backup receipt lacks timezone")
        archive = config["archive_dir"] / (name + ".tar")
        if not archive.exists() or archive.is_symlink() or not stat.S_ISREG(archive.stat().st_mode):
            fail("Verified backup archive is missing or unsafe")
        archive_info = archive.stat()
        if archive_info.st_uid != os.getuid() or stat.S_IMODE(archive_info.st_mode) != 0o600:
            fail("Verified backup archive is not private")
        result.append((created, name, archive, sidecar, record))
    return sorted(result)


def healthy(config, now):
    check_mount(config)
    saved = records(config)
    if not saved:
        fail("No verified backup on the backup disk")
    created, _, archive, _, receipt = saved[-1]
    if now - created > timedelta(minutes=config["freshness_minutes"]):
        fail("Latest verified backup is stale")
    if sha256(archive) != receipt["sha256"]:
        fail("Latest archive checksum differs from its receipt")
    return saved


def prune(config, now):
    saved = healthy(config, now)
    if len(saved) <= config["minimum_generations"]:
        return 0
    # Keep at least two recently verified generations even when older than policy.
    for _, _, archive, _, receipt in saved[-config["minimum_generations"]:]:
        if sha256(archive) != receipt["sha256"]:
            fail("A retained backup checksum differs from its receipt")
    cutoff = now - timedelta(hours=config["retention_hours"])
    removed = 0
    for created, name, archive, sidecar, _ in saved[:-config["minimum_generations"]]:
        if created >= cutoff:
            continue
        local = config["local_backup_dir"] / name
        if local.exists() and (local.is_symlink() or not local.is_dir() or local.resolve() != local):
            fail("Unsafe local backup path blocks pruning")
        check_mount(config)
        sidecar.unlink()
        archive.unlink()
        if local.exists():
            shutil.rmtree(local)
        removed += 1
    return removed


def backup(config):
    check_mount(config)
    if shutil.disk_usage(config["mountpoint"]).free < 100 * 1024 * 1024:
        fail("Backup disk has less than 100 MiB free")
    name = "warehouse-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    local = config["local_backup_dir"] / name
    archive = config["archive_dir"] / (name + ".tar")
    receipt = config["archive_dir"] / (name + ".tar.receipt.json")
    if local.exists() or archive.exists() or receipt.exists():
        fail("Backup name already exists")
    run_dir = config["evidence_dir"] / name
    run_dir.mkdir(mode=0o700)
    log = run_dir / "private.log"
    env = dict(os.environ, WAREHOUSE_STATE_DIR=str(config["state_dir"]))
    try:
        run_logged(["bash", str(config["source_checkout"] / "scripts/backup.sh"), str(local)], log, env)
        run_logged(["bash", str(config["source_checkout"] / "scripts/verify-restore.sh"), str(local)], log, env)
        check_mount(config)
        run_logged(["bash", str(ROOT / "scripts/export-recovery-backup.sh"), "--plain",
                    str(local), str(config["recovery_secrets_dir"]), str(archive)], log)
        check_mount(config)
        digest = sha256(archive)
        intake = run_dir / "intake"
        run_logged([sys.executable, str(ROOT / "scripts/prepare-recovery-bundle.py"),
                    str(archive), digest, str(intake)], log)
        shutil.rmtree(intake)
        check_mount(config)
        # The source snapshot began at this timestamp. Completion time would
        # understate recoverable data age when checking the one-hour RPO.
        created = datetime.strptime(name.removeprefix("warehouse-"), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        verified_at = datetime.now(timezone.utc)
        payload = {"backup_name": name, "created_at": created.isoformat(),
                   "verified_at": verified_at.isoformat(),
                   "mount_uuid": config["mount_uuid"], "sha256": digest,
                   "size": archive.stat().st_size}
        atomic_json(receipt, payload)
        atomic_json(config["evidence_dir"] / "last-success.json", payload)
        removed = prune(config, verified_at)
        print(f"Verified warehouse backup {name}; pruned {removed} expired generations")
    except Exception:
        atomic_json(config["evidence_dir"] / "last-failure.json",
                    {"time": datetime.now(timezone.utc).isoformat(), "backup_name": name})
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("action", choices=["check-config", "backup", "health"])
    args = parser.parse_args()
    os.umask(0o077)
    config = load_config(args.config)
    check_mount(config)
    if args.action == "check-config":
        print("Backup configuration and mounted filesystem match")
    elif args.action == "health":
        healthy(config, datetime.now(timezone.utc))
        print("Latest verified backup is fresh")
    else:
        lock = config["evidence_dir"] / "scheduled-backup.lock"
        with open(lock, "a") as output:
            try:
                fcntl.flock(output, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                fail("Another scheduled backup is still running")
            backup(config)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Scheduled backup: {error}", file=sys.stderr)
        sys.exit(1)
