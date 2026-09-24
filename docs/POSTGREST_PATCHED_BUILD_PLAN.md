# PostgREST v14.17 patched source build plan

Status: **investigation only; no replacement image built or deployed** (2026-09-24).
The warehouse `rest` service still uses `postgrest/postgrest:v14.17`.
As of 2026-09-24, the latest stable upstream releases are
[v14.18](https://github.com/PostgREST/postgrest/releases/tag/v14.18) on the v14
line and [v16.3](https://github.com/PostgREST/postgrest/releases/tag/v16.3)
overall. The [exact image investigation](POSTGREST_IMAGE_INVESTIGATION.md)
found affected `aeson` versions in both, so neither is a ready replacement.

## Source and patch boundary

Keep the PostgREST application at upstream tag `v14.17`, which resolves to
`064e5fea7bde63b0424fab53a0109c6f6016e95c` (`git ls-remote`, 2026-09-24),
and use its checked-in
`flake.lock`: Nixpkgs revision
`c80edd02003fe3d8af527215a3ac069be9cfd47f`, NAR hash
`sha256-BeuAPwNM2RBc5bvUTb0j4GRs2yBkDeRCw/8Y3v9Xesc=`. Record the resolved,
possibly annotated, tag object and peeled commit again before creating a patch
branch; the tag name alone is not an immutable source pin. Preserve the source
archive or checkout checksum in the build evidence.

The upstream **amd64** build uses `nix-build -A postgrestStatic` and
`nix-build -A docker.image`. `nix/static.nix` selects
`pkgsStatic.haskell.packages.native-bignum.ghc948`, while `default.nix` applies
`nix/overlays/haskell-packages.nix` to that compiler. The Docker derivation copies
the resulting static executable and runs it as UID 1000 on port 3000. The
published **arm64** v14.17 binary is instead dynamically linked on Ubuntu and
comes from the upstream Stack/GHC path. The amd64 Nix graph cannot attest its
components. Keep each architecture's runtime shape and command. The v14.17
`postgrest.cabal` range
`aeson >= 2.0.3 && < 2.3` accepts the fixed 2.2.5.1 version.

For amd64, add Hackage overrides alongside the existing `auto-update` override
in `nix/overlays/haskell-packages.nix`:

```nix
      aeson = prev.callHackageDirect {
        pkg = "aeson";
        ver = "2.2.5.1";
        sha256 = "<verified Nix SRI hash of the Hackage source archive>";
      } { };
      text-iso8601 = prev.callHackageDirect {
        pkg = "text-iso8601";
        ver = "0.1.1.2";
        sha256 = "<verified Nix SRI hash of the Hackage source archive>";
      } { };
```

For arm64, keep resolver `lts-22.44` (GHC 9.6.7) and add `aeson-2.2.5.1`
and `text-iso8601-0.1.1.2` to `stack.yaml` `extra-deps`. Regenerate and commit
`stack.yaml.lock` on a native arm64 runner, then verify the snapshot and Pantry
hashes and retain the complete resolved build plan. If `text-iso8601` is absent
from the plan, remove its unused pin and document the absence. Follow the exact
upstream arm64 workflow for packaging. Its Dockerfile pins
`ubuntu:resolute@sha256:678c6550cc43645e08669028bc177f50be4e7c5b8cca677067b1914d4afc7a03`
and installs `libpq-dev`, `zlib1g-dev`, `jq`, `gcc` and `libnuma-dev` from live apt
repositories. Preserve entrypoint, UID, dynamic linker and runtime libraries;
capture resolved apt package versions and native vulnerability findings per
build, since the base digest alone does not freeze live apt repositories.
Do not put a dynamically linked arm64 executable into the Nix scratch image.

Resolve the Nix hashes from the Hackage source archives on the build runner and
commit the **real hashes** with the patch. An intentionally wrong fixed-output
hash can make Nix report the expected SRI hash, but that error is only a way to
obtain the value; independently check the downloaded archive against the Hackage
index metadata. Do not use a fake hash, `jailbreak`, disabled checks, or a live
unlocked dependency update as a final recipe. If the second package is absent
from the resolved build graph, document that fact and decide whether its override
should remain; neither stripped-binary strings nor its absence from a runtime
closure prove absence from the statically linked graph.

Build separately on native Linux amd64 and arm64 workers with enough disk and
memory for their GHC toolchains. Before scheduling a build, measure available
disk, RAM, swap and cache space; set conservative parallelism for GHC and preserve
space for the Nix store, Stack package cache, image layers and retained logs.
Use dedicated runner storage, not the shared demo host. Cache immutable Nix store
paths and Stack snapshots per architecture and compiler version, with trusted
cache signatures; do not reuse a mutable compiler or package cache as build
attestation. Pin Nix and Stack versions in their respective build environments
and record them. The first work on each platform is evaluation and dependency
resolution. Correct upstream or transitive version bounds explicitly if the
new packages reveal an incompatibility, then rerun the full build; do not bypass
bounds. On amd64, build the executable and image from the **same checkout**:

```sh
git rev-parse HEAD
git rev-parse v14.17^{}
nix --version
nix-instantiate -A postgrestStatic > postgrest-static.drv-path
nix-store -qR "$(cat postgrest-static.drv-path)" > postgrest-build-graph.paths
nix derivation show --recursive "$(cat postgrest-static.drv-path)" > postgrest-build-derivations.json
nix-build -A postgrestStatic --no-out-link
nix-build -A docker.image --no-out-link
```

On arm64, run `stack build --dry-run`, `stack build`, and upstream tests under
the locked resolver. Save the Stack plan, lockfile, compiler/package database
inventory, build logs, binary hash, `file`/`readelf` linkage output and image
manifest digest. Prove the binary copied into each candidate image has the same
hash as its platform build artifact.

Save the complete amd64 **derivation/build-input** graph (the `.drv` query above),
source hashes, build logs and result paths. This graph includes build tools and
cannot by itself identify packages linked into the executable. The Stack plan
and installed package database have the same limitation. Capture the selected
GHC executable package IDs from the actual build/link invocation on **each**
platform, map them to exact Hackage versions and source hashes, and record a
native linker map with the archive paths and hashes used. If the build does not
expose enough link evidence, change its instrumentation and rebuild before
claiming a complete inventory. `readelf` identifies dynamic ELF dependencies,
but cannot enumerate code embedded from static Haskell or native archives.
Include native components such as OpenSSL and libpq and the arm64 dynamic
runtime packages. Confirm the linked package list contains `aeson-2.2.5.1`;
establish whether `text-iso8601` is linked from this list, not from stripped
binary strings or a runtime Nix closure. Search the whole selected link set for
older copies of either package.

Query OSV/Hackage advisories for every selected Haskell component and assess
native findings separately. A **PostgREST-specific** validator must reject
empty Hackage inventories, missing `base` or `aeson`, incomplete native link
evidence, platform manifest or executable hash mismatches, stale or failed
advisory lookups, and unresolved HIGH/CRITICAL findings. As positive controls,
it must flag affected `aeson` 2.2.3.0 and 2.1.2.1 while clearing fixed 2.2.5.1
under HSEC-2026-0007, and flag `text-iso8601` 0.1.1.1 while clearing 0.1.1.2
whether or not that package is linked. The current Trivy report validator
can pass on OS packages alone and cannot establish Haskell coverage.

Bind each inventory and advisory result to the producing source/build ref,
binary SHA-256 and platform OCI manifest digest. Verify a signed provenance
attestation from an approved builder identity whose subject is that platform
digest and whose materials include the inventory and binary hash, **or**
independently reproduce an identical binary hash with a separately verified
dependency graph. A dated inventory file next to an image is only a claim until
this producer-to-image link is verified. Retain the full advisory results. Run
the repository's image scan as an additional gate; zero-package Trivy output
must still fail.

Check `postgrest --version` and `--help`, then use a disposable database and
isolated Docker network to run upstream PostgREST tests. Run the warehouse API
regression against a freshly created demo project, including roles, sessions,
orders/cart, image routes and PDFs. Compare the old and candidate PostgREST
responses for representative authenticated and anonymous requests. Re-run the
affected physical-iPhone flow before promoting the image. Keep production and
the existing shared volumes, ports and services untouched during this work.

Do not replace the runtime image or merge a candidate PR until both platform
builds, inventory/vulnerability evidence, warehouse API regression and affected
physical-iPhone retest pass. Only then should the warehouse Compose `rest` image be
changed to a published, immutable multi-platform digest with attached
per-platform inventory and vulnerability assessment. Rerun the complete strict
19-image gate; this candidate alone cannot clear the unrelated Grafana findings.

## Current host blocker

The workspace host has no `nix`, `ghc`, `cabal`, or `stack` executable; it had
59 GB of free disk, 16 GiB available memory and full swap at inspection. Default
sandbox access could not resolve `github.com` or access `/var/run/docker.sock`;
scoped read-only escalation did resolve the upstream tag. No source checkout,
Hackage hash resolution, Nix evaluation, compilation, image creation, test or
SBOM claim was made here.
These conditions make a local static build unsuitable without a separately
provisioned runner. The recipe above is a review target, not a passing patch.

Primary references: [upstream v14.17 default.nix](https://github.com/PostgREST/postgrest/blob/v14.17/default.nix),
[Haskell overlay](https://github.com/PostgREST/postgrest/blob/v14.17/nix/overlays/haskell-packages.nix),
[Stack resolver](https://github.com/PostgREST/postgrest/blob/v14.17/stack.yaml),
[Stack lock](https://github.com/PostgREST/postgrest/blob/v14.17/stack.yaml.lock),
[build workflow](https://github.com/PostgREST/postgrest/blob/v14.17/.github/workflows/build.yaml),
[release workflow](https://github.com/PostgREST/postgrest/blob/v14.17/.github/workflows/release.yaml),
[arm64 Dockerfile](https://github.com/PostgREST/postgrest/blob/v14.17/Dockerfile),
[static derivation](https://github.com/PostgREST/postgrest/blob/v14.17/nix/static.nix),
[Docker derivation](https://github.com/PostgREST/postgrest/blob/v14.17/nix/tools/docker/default.nix),
[Cabal bounds](https://github.com/PostgREST/postgrest/blob/v14.17/postgrest.cabal),
[Nixpkgs Haskell override API](https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/haskell-modules/make-package-set.nix),
[Nix build closure query](https://nix.dev/manual/nix/2.26/command-ref/nix-store/query),
[HSEC-2026-0007](https://github.com/haskell/security-advisories/blob/main/advisories/published/2026/HSEC-2026-0007.md).
