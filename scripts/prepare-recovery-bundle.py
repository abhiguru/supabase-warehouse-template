#!/usr/bin/env python3
"""Verify and privately unpack an unencrypted v4 recovery export; start no services."""

import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile

BACKUP_FILES = {
    "database.dump", "storage.tar.gz", "integrity.txt", "metadata.txt",
    "compose.env", "instance.json", "roles.txt", "globals.sql", "SHA256SUMS",
}


def fail(message):
    raise ValueError(message)


def private_path(path, directory):
    if not path.is_absolute() or path.is_symlink() or not path.exists():
        fail("Expected an existing absolute path without a symlink")
    if path.resolve() != path:
        fail("Path contains a symlink or noncanonical component")
    stat = path.stat()
    if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        fail("Input/output path must be owned by this user with no group/other access")
    if (path.is_dir() if directory else path.is_file()) is False:
        fail("Input/output path has the wrong type")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_members(tar):
    members = tar.getmembers()
    if not members or len(members) > 100000:
        fail("Archive has no entries or too many entries")
    seen = set()
    roots = set()
    total = 0
    for member in members:
        name = member.name.rstrip("/")
        parts = PurePosixPath(name).parts
        if (not name or name.startswith("/") or "\\" in name or
                any(part in (".", "..", "") for part in name.split("/")) or
                str(PurePosixPath(name)) != name):
            fail("Archive contains an unsafe path")
        if name in seen:
            fail("Archive contains a duplicate path")
        seen.add(name)
        roots.add(parts[0])
        if not (member.isdir() or member.isfile()):
            fail("Archive contains a link or special file")
        total += member.size
    if len(roots) != 2 or not all(any(m.name.rstrip("/") == root and m.isdir() for m in members) for root in roots):
        fail("Archive must contain two explicit top-level directories")
    backup_candidates = [root for root in roots if f"{root}/metadata.txt" in seen]
    if len(backup_candidates) != 1:
        fail("Archive must contain exactly one v4 backup")
    backup_root = backup_candidates[0]
    secrets_root = (roots - {backup_root}).pop()
    if {p[len(backup_root) + 1:] for p in seen if p.startswith(backup_root + "/")} != BACKUP_FILES:
        fail("Backup has missing or unexpected entries")
    if not any(m.isfile() and m.name.startswith(secrets_root + "/") for m in members):
        fail("Recovery credentials are missing")
    return members, backup_root, secrets_root, total


def verify_backup(backup):
    if (backup / "metadata.txt").read_text()[:128].splitlines()[0] != "format=warehouse-backup-v4":
        fail("Expected a v4 backup")
    lines = (backup / "SHA256SUMS").read_text().splitlines()
    expected_files = BACKUP_FILES - {"SHA256SUMS"}
    found = set()
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        if not match or match[2] not in expected_files or match[2] in found:
            fail("Backup checksum manifest is invalid")
        found.add(match[2])
        if sha256(backup / match[2]) != match[1]:
            fail("Backup checksum mismatch")
    if found != expected_files:
        fail("Backup checksum manifest is incomplete")
    if not (backup / "globals.sql").stat().st_size:
        fail("Cluster-global backup is empty")
    with tarfile.open(backup / "storage.tar.gz", "r:gz") as storage:
        seen = set()
        for member in storage:
            name = member.name.rstrip("/")
            if (not (member.isdir() or member.isfile()) or
                    (name not in ("", ".") and
                     (name.startswith("/") or "\\" in name or
                      any(part == ".." for part in name.split("/")) or name in seen))):
                fail("Storage archive contains an unsafe entry")
            seen.add(name)


def main():
    os.umask(0o077)
    if len(sys.argv) != 4:
        fail("Usage: prepare-recovery-bundle.py ARCHIVE_TAR EXPECTED_SHA256 NEW_PRIVATE_DIR")
    archive = Path(sys.argv[1])
    expected = sys.argv[2].lower()
    output = Path(sys.argv[3])
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        fail("Expected SHA-256 must be 64 hexadecimal characters")
    private_path(archive, False)
    if sha256(archive) != expected:
        fail("Archive SHA-256 mismatch")
    if not output.is_absolute() or output.exists() or output.is_symlink():
        fail("Destination must be a new absolute directory")
    private_path(output.parent, True)
    with tarfile.open(archive, "r:") as source:
        members, backup_root, secrets_root, total = safe_members(source)
        if shutil.disk_usage(output.parent).free < total + 256 * 1024 * 1024:
            fail("Insufficient space for private extraction")
        output.mkdir(mode=0o700)
        try:
            for member in sorted(members, key=lambda item: (item.name.count("/"), item.name)):
                parts = PurePosixPath(member.name.rstrip("/")).parts
                folder = "backup" if parts[0] == backup_root else "recovery-secrets"
                target = output / folder
                if len(parts) > 1:
                    target = target.joinpath(*parts[1:])
                if member.isdir():
                    target.mkdir(mode=0o700, exist_ok=True)
                else:
                    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    with source.extractfile(member) as reader, target.open("xb") as writer:
                        shutil.copyfileobj(reader, writer)
                    target.chmod(0o600)
            verify_backup(output / "backup")
        except BaseException:
            shutil.rmtree(output)
            raise
    print("Archive hash, tar safety, private extraction, backup checksums and storage archive passed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, UnicodeError, tarfile.TarError, IndexError) as error:
        print(f"Recovery preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
