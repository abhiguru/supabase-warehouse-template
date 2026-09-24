#!/usr/bin/env python3
"""Check an evaluation-only PostgREST derivation graph for proposed pins."""

import argparse
import json
import pathlib
import sys


PACKAGES = {
    "aeson": ("2.2.5.1", "7f55de795c57c68215a8718d19495b48be0ba45d23c633e59c2e1752911fec2e"),
    "text-iso8601": ("0.1.1.2", "e00ce8d45eaa0c534d44a58ba412541a5ee7b299c23a840cd02f07f6f90520cb"),
    "hashable": ("1.4.7.0", None),
}


def selected(drv: dict, package: str, version: str) -> bool:
    env = drv.get("env", {})
    return env.get("pname") == package and env.get("version") == version


def closure(graph: dict, root: str) -> set[str]:
    seen = set()
    pending = [root]
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        if path not in graph:
            raise SystemExit(f"recursive graph omits input derivation: {path}")
        seen.add(path)
        pending.extend(graph[path].get("inputDrvs", {}))
    return seen


def direct_package(graph: dict, parent: str, package: str, version: str, errors: list[str]) -> str | None:
    matches = [
        path
        for path in graph[parent].get("inputDrvs", {})
        if graph[path].get("env", {}).get("pname") == package
    ]
    if len(matches) != 1 or not selected(graph[matches[0]], package, version):
        found = [graph[path].get("name", path) for path in matches]
        errors.append(f"{graph[parent].get('name', parent)} must directly select {package}-{version}; found {found}")
        return None
    print(f"direct dependency: {graph[parent].get('name')} -> {graph[matches[0]].get('name')}")
    return matches[0]


def source_fetches(graph: dict, package: str, version: str) -> list[tuple[str, str, str]]:
    archive = f"{package}-{version}.tar.gz"
    found = []
    for path, drv in graph.items():
        urls = drv.get("env", {}).get("urls", "")
        if archive not in str(urls):
            continue
        for output in drv.get("outputs", {}).values():
            if output.get("hashAlgo") == "sha256" and output.get("method") == "nar":
                found.append((path, output.get("path", ""), output.get("hash", "")))
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("graph", type=pathlib.Path)
    parser.add_argument("root_drv_file", type=pathlib.Path)
    args = parser.parse_args()
    graph = json.loads(args.graph.read_text())
    if not isinstance(graph, dict) or not graph:
        raise SystemExit("empty or invalid recursive derivation graph")
    root = args.root_drv_file.read_text().strip()
    if root not in graph or not selected(graph[root], "postgrest", "14.17"):
        raise SystemExit(f"root is not the selected PostgREST 14.17 derivation: {root}")
    rooted_paths = closure(graph, root)

    errors = []
    aeson_path = direct_package(graph, root, "aeson", "2.2.5.1", errors)
    if aeson_path:
        direct_package(graph, aeson_path, "text-iso8601", "0.1.1.2", errors)
        direct_package(graph, aeson_path, "hashable", "1.4.7.0", errors)
        conflicting_hashable = [
            graph[path].get("name", path)
            for path in closure(graph, aeson_path)
            if graph[path].get("env", {}).get("pname") == "hashable"
            and not selected(graph[path], "hashable", "1.4.7.0")
        ]
        if conflicting_hashable:
            errors.append(f"conflicting hashable derivations below aeson: {conflicting_hashable}")

    for package, (version, expected_hash) in PACKAGES.items():
        selected_paths = [path for path in rooted_paths if selected(graph[path], package, version)]
        if not selected_paths:
            errors.append(f"missing {package}-{version} derivation")
            continue
        print(f"selected {package}-{version}: {len(selected_paths)} derivation(s)")
        if expected_hash is None:
            continue
        fetches = source_fetches(graph, package, version)
        if not fetches:
            errors.append(f"missing recursive SHA-256 Hackage fetchzip derivation for {package}-{version}")
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
                print(f"declared {package}-{version} unpacked source SHA-256: {actual_hash}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Derivation graph contains the proposed package versions and declared source hashes.")
    print("Evaluation does not download or verify archive bytes or establish linked packages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
