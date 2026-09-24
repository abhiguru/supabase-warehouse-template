#!/usr/bin/env python3
"""Check the native build's selected unit closure and metadata evidence."""

import gzip
import hashlib
import pathlib
import re
import shlex
import subprocess
import sys


VERSIONS = {
    "aeson": "2.2.5.1",
    "text-iso8601": "0.1.1.2",
    "hashable": "1.4.7.0",
    "character-ps": "0.1",
    "attoparsec-aeson": "2.2.2.0",
}
REQUIRED = (
    "patched-upstream.diff", "patched-upstream.tree", "upstream-source.sha",
    "stack.yaml.lock", "toolchain.txt", "stack-plan.log", "binary.file",
    "binary.elf-header", "binary.dynamic", "binary.version", "binary.sha256",
    "ghc-package-path.txt", "ghc-pkg.dump", "postgrest.link.map.gz",
)


def package_database(dump: str) -> dict[str, tuple[str, str, list[str]]]:
    packages = {}
    for entry in re.split(r"(?m)^---\s*$", dump):
        fields = {}
        current_field = None
        for line in entry.splitlines():
            match = re.match(r"^([\w-]+):\s*(.*)$", line)
            if match:
                current_field = match.group(1)
                fields[current_field] = match.group(2)
            elif line.startswith(" ") and current_field == "depends":
                fields["depends"] += " " + line.strip()
        if all(key in fields for key in ("id", "name", "version", "depends")):
            packages[fields["id"]] = (
                fields["name"], fields["version"], fields["depends"].split()
            )
    return packages


def digest(path: pathlib.Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def build_id(path: pathlib.Path) -> str | None:
    result = subprocess.run(["readelf", "-n", str(path)], text=True, capture_output=True, check=True)
    ids = re.findall(r"(?m)^\s*Build ID:\s*([0-9a-f]+)\s*$", result.stdout)
    if len(ids) > 1:
        raise SystemExit(f"ambiguous ELF build IDs in {path}")
    return ids[0] if ids else None


def check(directory: pathlib.Path, build_log: pathlib.Path, expected_map: pathlib.Path,
          installed_binary: pathlib.Path, source: pathlib.Path) -> None:
    for name in REQUIRED:
        if not (directory / name).is_file() or not (directory / name).stat().st_size:
            raise SystemExit(f"missing or empty build evidence: {name}")

    toolchain = (directory / "toolchain.txt").read_text()
    for key, expected in (("runner_arch", "aarch64"), ("ghc", "9.6.7"), ("stack", "3.7.1")):
        if not re.search(rf"(?m)^{key}={re.escape(expected)}$", toolchain):
            raise SystemExit(f"missing or unexpected toolchain evidence: {key}")
    for key in ("ghc_executable_sha256", "stack_executable_sha256"):
        if not re.search(rf"(?m)^{key}=[0-9a-f]{{64}}$", toolchain):
            raise SystemExit(f"missing toolchain executable hash: {key}")

    header = (directory / "binary.elf-header").read_text()
    if not re.search(r"(?m)^\s*Machine:\s*AArch64\s*$", header):
        raise SystemExit("binary ELF header is not AArch64")
    if not re.fullmatch(r"[0-9a-f]{64}  postgrest\n", (directory / "binary.sha256").read_text()):
        raise SystemExit("binary SHA-256 evidence is malformed")
    installed_sha = digest(installed_binary)
    if (directory / "binary.sha256").read_text() != f"{installed_sha}  postgrest\n":
        raise SystemExit("recorded binary SHA-256 does not match installed executable")
    if "14.17" not in (directory / "binary.version").read_text():
        raise SystemExit("binary version evidence does not identify PostgREST 14.17")
    map_hash = hashlib.sha256()
    map_size = 0
    with gzip.open(directory / "postgrest.link.map.gz", "rb") as link_map:
        for chunk in iter(lambda: link_map.read(1024 * 1024), b""):
            map_hash.update(chunk)
            map_size += len(chunk)
    if not map_size or map_hash.hexdigest() != digest(expected_map):
        raise SystemExit("saved linker map is empty or differs from the requested map")

    # Cabal verbosity 3 records the GHC executable invocation. Require the
    # final postgrest command, then walk its package-unit roots through the
    # active Stack package databases. A package installed elsewhere is not proof.
    link_lines = []
    with build_log.open(errors="replace") as log:
        for line in log:
            if "-package-id" not in line or " -o " not in line:
                continue
            try:
                tokens = shlex.split(line)
            except ValueError:
                continue
            output_args = [tokens[i + 1] for i, token in enumerate(tokens[:-1]) if token == "-o"]
            if len(output_args) == 1 and pathlib.Path(output_args[0]).name == "postgrest":
                link_lines.append((line.rstrip("\n"), tokens, output_args[0]))
    if len(link_lines) != 1:
        raise SystemExit(f"expected one unambiguous PostgREST GHC link invocation, found {len(link_lines)}")
    link_line, tokens, output_arg = link_lines[0]
    if f"-optl=-Wl,-Map={expected_map}" not in tokens:
        raise SystemExit("final PostgREST link command does not name the unique linker map")
    linked_binary = pathlib.Path(output_arg)
    if not linked_binary.is_absolute():
        linked_binary = source / linked_binary
    linked_binary = linked_binary.resolve(strict=True)
    if not linked_binary.is_file() or not linked_binary.stat().st_size:
        raise SystemExit("the final PostgREST link output is missing or empty")
    linked_sha = digest(linked_binary)
    linked_id = build_id(linked_binary)
    installed_id = build_id(installed_binary)
    if linked_sha != installed_sha and not (linked_id and linked_id == installed_id):
        raise SystemExit("installed executable differs from linked output without a matching ELF build ID")
    (directory / "link-command.txt").write_text(link_line + "\n")
    (directory / "link-output.sha256").write_text(f"{linked_sha}  {linked_binary}\n")
    (directory / "binary.build-id").write_text((installed_id or "none") + "\n")
    (directory / "link-output.build-id").write_text((linked_id or "none") + "\n")
    roots = {tokens[i + 1] for i, token in enumerate(tokens[:-1]) if token == "-package-id"}
    if not roots:
        raise SystemExit("PostgREST link invocation has no package-unit roots")
    packages = package_database((directory / "ghc-pkg.dump").read_text())
    if not packages:
        raise SystemExit("active GHC package database is empty or unparsable")
    visited = set()
    pending = list(roots)
    while pending:
        unit = pending.pop()
        if unit in visited:
            continue
        if unit not in packages:
            raise SystemExit(f"link unit is absent from active package database: {unit}")
        visited.add(unit)
        pending.extend(packages[unit][2])

    for package, version in VERSIONS.items():
        record = directory / f"unit-{package}.txt"
        if not record.is_file() or not record.stat().st_size:
            raise SystemExit(f"missing package unit evidence: {package}")
        text = record.read_text()
        versions = re.findall(r"(?m)^version:\s*(\S+)\s*$", text)
        units = re.findall(r"(?m)^id:\s*(\S+)\s*$", text)
        if versions != [version] or len(units) != 1:
            raise SystemExit(f"unexpected package unit evidence for {package}: {versions}, {units}")
        if units[0] not in visited or packages[units[0]][:2] != (package, version):
            raise SystemExit(f"{package}-{version} is absent from the executable unit closure")
        print(f"{package}-{version}: {units[0]}")
    (directory / "link-units.txt").write_text("\n".join(sorted(visited)) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        raise SystemExit("usage: check-postgrest-build-evidence.py EVIDENCE_DIR BUILD_LOG LINK_MAP INSTALLED_BINARY SOURCE_DIR")
    check(*(pathlib.Path(arg) for arg in sys.argv[1:]))
