#!/usr/bin/env python3
"""Check the proposed PostgREST Stack lock and dry-run package selection."""

import argparse
import pathlib
import re


PINS = {
    "aeson": ("2.2.5.1", "a89fd54b802351ebf57a6be451db25c167c3ccb35583b4a9d2bb54d7d1c43de2", 6335),
    "text-iso8601": ("0.1.1.2", "8da5b74d6c79eba657ec5f8fd289f1b0aad2463538928c96c6035c52d03ac9ab", 2390),
    "hashable": ("1.4.7.0", "573f3ab242f75465a0d67ce9d84202650a1606575e6dbd6d31ffcf4767a9a379", 6629),
    "character-ps": ("0.1", "b38ed1c07ae49e7461e44ca1d00c9ca24d1dcb008424ccd919916f92fd48d9fe", 1315),
    "attoparsec-aeson": ("2.2.2.0", "08948f45b892c5758d2c42e22fe2fbd41a4f6dc395fb0a43c2bf458a1f295736", 1664),
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("generated_lock", type=pathlib.Path)
    parser.add_argument("candidate_lock", type=pathlib.Path)
    parser.add_argument("dry_run_log", type=pathlib.Path)
    args = parser.parse_args()

    generated = args.generated_lock.read_bytes()
    if generated != args.candidate_lock.read_bytes():
        raise SystemExit("generated Stack lock differs from the committed candidate")
    lock = generated.decode()
    plan = args.dry_run_log.read_text()
    completed = re.findall(r"(?m)^- completed:\n    hackage: ([^\n]+)$", lock)

    for package, (version, cabal_sha, cabal_size) in PINS.items():
        expected = f"{package}-{version}@sha256:{cabal_sha},{cabal_size}"
        if completed.count(expected) != 1:
            raise SystemExit(f"expected exactly one completed lock entry for {expected}")
        selected = re.findall(rf"(?m)^\* {re.escape(package)}-(\d+(?:\.\d+)+):", plan)
        if selected != [version]:
            raise SystemExit(f"dry-run plan selects {package} versions {selected}; expected [{version}]")
        print(f"selected {package}-{version} with Cabal SHA-256 {cabal_sha}")

    if "original: lts-22.44" not in lock:
        raise SystemExit("lockfile resolver changed from lts-22.44")
    print("Generated lock matches the committed candidate and the dry-run selects every required pin.")
    print("This verifies dependency planning, not compilation or executable linkage.")


if __name__ == "__main__":
    main()
