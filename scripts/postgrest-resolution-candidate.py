#!/usr/bin/env python3
"""Apply the two verified Hackage pins to a disposable PostgREST v14.17 checkout.

This is an evaluation experiment. It deliberately leaves upstream's lockfile
untouched until Stack resolves the proposed extra dependencies.
"""

import argparse
import pathlib
import subprocess

SOURCE_SHA = "064e5fea7bde63b0424fab53a0109c6f6016e95c"
AESON_SRI = "sha256-6oLWUMC72Id9vxOgO5uq475+1KZfToz+W06stPW+rnU="
TEXT_SRI = "sha256-3bsTrscKL9VMeiW/heOKRn0NVZmYDSH0kls8cG+Pc5g="


def replace_once(path: pathlib.Path, before: str, after: str) -> None:
    source = path.read_text()
    if source.count(before) != 1:
        raise SystemExit(f"expected exactly one anchor in {path}: {before!r}")
    path.write_text(source.replace(before, after, 1))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("--stack-hashable", action="store_true")
    args = parser.parse_args()
    source = args.source.resolve()
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if actual != SOURCE_SHA:
        raise SystemExit(f"wrong PostgREST source: {actual}")

    overlay = source / "nix/overlays/haskell-packages.nix"
    pins = f'''      aeson = prev.callHackageDirect {{
        pkg = "aeson";
        ver = "2.2.5.1";
        sha256 = "{AESON_SRI}";
      }} {{ }};
      text-iso8601 = prev.callHackageDirect {{
        pkg = "text-iso8601";
        ver = "0.1.1.2";
        sha256 = "{TEXT_SRI}";
      }} {{ }};

'''
    replace_once(
        overlay,
        "      # TODO: Remove once available in nixpkgs\n      auto-update =\n",
        pins + "      # TODO: Remove once available in nixpkgs\n      auto-update =\n",
    )

    stack = source / "stack.yaml"
    deps = "  - aeson-2.2.5.1\n  - text-iso8601-0.1.1.2\n"
    if args.stack_hashable:
        deps += "  - hashable-1.4.7.0\n"
    replace_once(stack, "extra-deps:\n", "extra-deps:\n" + deps)


if __name__ == "__main__":
    main()
