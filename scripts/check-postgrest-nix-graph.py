#!/usr/bin/env python3
"""Check an evaluation-only PostgREST derivation graph for proposed pins."""

import argparse
import json
import pathlib
import re
import sys


PACKAGES = {
    "aeson": ("2.2.5.1", "ea82d650c0bbd8877dbf13a03b9baae3be7ed4a65f4e8cfe5b4eacb4f5beae75"),
    "text-iso8601": ("0.1.1.2", "ddbb13aec70a2fd54c7a25bf85e38a467d0d5599980d21f4925b3c706f8f7398"),
    "hashable": ("1.4.7.0", None),
}


def selected(drv: dict, package: str, version: str) -> bool:
    env = drv.get("env", {})
    name = drv.get("name") or env.get("name", "")
    return (env.get("pname") == package and env.get("version") == version) or bool(
        re.fullmatch(re.escape(package + "-" + version) + r"(?:-[^/]*)?", name)
    )


def source_fetches(graph: dict, package: str, version: str) -> list[tuple[str, str, str]]:
    archive = f"{package}-{version}.tar.gz"
    found = []
    for path, drv in graph.items():
        urls = drv.get("env", {}).get("urls", "")
        if archive not in str(urls):
            continue
        for output in drv.get("outputs", {}).values():
            if output.get("hashAlgo") == "sha256" and output.get("method") == "flat":
                found.append((path, output.get("path", ""), output.get("hash", "")))
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("graph", type=pathlib.Path)
    args = parser.parse_args()
    graph = json.loads(args.graph.read_text())
    if not isinstance(graph, dict) or not graph:
        raise SystemExit("empty or invalid recursive derivation graph")

    errors = []
    for package, (version, expected_hash) in PACKAGES.items():
        selected_paths = [path for path, drv in graph.items() if selected(drv, package, version)]
        if not selected_paths:
            errors.append(f"missing {package}-{version} derivation")
            continue
        print(f"selected {package}-{version}: {len(selected_paths)} derivation(s)")
        if expected_hash is None:
            continue
        fetches = source_fetches(graph, package, version)
        if not fetches:
            errors.append(f"missing flat SHA-256 Hackage source derivation for {package}-{version}")
        for path, output_path, actual_hash in fetches:
            if not any(
                path in graph[selected_path].get("inputDrvs", {})
                or output_path == graph[selected_path].get("env", {}).get("src")
                for selected_path in selected_paths
            ):
                errors.append(f"{package}-{version} source {path} is not an input of its package derivation")
            if actual_hash.lower() != expected_hash:
                errors.append(f"unexpected {package}-{version} source hash in {path}: {actual_hash}")
            else:
                print(f"declared {package}-{version} archive SHA-256: {actual_hash}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Derivation graph contains the proposed package versions and declared source hashes.")
    print("Evaluation does not download or verify archive bytes or establish linked packages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
