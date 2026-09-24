# Manual PostgREST v14.17 arm64 build evidence

This workflow is a bounded native-build experiment for the patched dependency
proposal. It is **manual only** and runs only when dispatched on `main`. It does
not build an image, change Compose, deploy a service, or upload the executable.
It has not been run as part of this proposal. The earlier [resolution
experiment](POSTGREST_RESOLUTION_EXPERIMENT.md) establishes a dry-run plan, not
compilation or executable linkage.

Before dispatch, provide a dedicated **ephemeral** self-hosted Linux arm64
runner with labels `self-hosted`, `Linux`, `ARM64` and
`postgrest-build-isolated`. It must have GHC 9.6.7, Stack 3.7.1, Git, Python 3,
`file`, `readelf`, `timeout`, `gzip` and standard coreutils installed. No
repository or cloud secrets are needed. Restrict who can register or control
this runner and who may dispatch the workflow. The workflow checks for at
least 100 GiB free on the workspace and runner temp filesystems and at least
16 GiB **available** memory; it fails before cloning upstream when either
threshold is unmet. The runner should have enough additional margin for the
operating system and GitHub Actions. These gates do not predict peak build
usage, so the job also has a 180-minute timeout and the build command a
150-minute timeout. It limits Stack to one package build at a time, caps each
process's virtual memory at 14 GiB, and stops the build if the job-owned work
directory reaches 80 GiB. Use a freshly provisioned runner rather than
sharing a host with services or persistent build caches.

The workflow clones upstream tag `v14.17` and checks the exact commit
`064e5fea7bde63b0424fab53a0109c6f6016e95c`. It applies the merged
candidate script with the arm64 Stack pins, copies the committed candidate
lock, asserts its SHA-256
`2b2a9695a986da7d6f150beb5f1facbfc948d387c8c5d3f4202f51f0e5b6ee11`
and patched Git tree `7e6d822e4754f3ac5d40869d64788ed03f806349`,
then runs the existing dry-run lock and selection checker. Only after those
checks does it build `postgrest:exe:postgrest`. `STACK_ROOT`, `TMPDIR`, the
upstream checkout and the full build log live in one temporary directory,
which an exit trap removes. A final step removes the job-owned metadata staging
directory after artifact upload. The job does not remove or modify unrelated
runner state. A disposable runner remains the required isolation boundary.

On success, the artifact contains the source commit and patch diff/tree,
candidate lock and dry-run plan, toolchain versions and executable hashes, GHC package database and
selected unit records, the recorded PostgREST GHC link invocation and its
transitive package-unit closure, a compressed GNU linker map, and the binary's
SHA-256, `file`, `readelf` header/dynamic-section and `--version` output.
The checker rejects missing evidence, a wrong architecture or version, a
missing final GHC link invocation or its unique absolute linker map, and any of
the five pinned packages absent from the invocation's transitive unit closure.
It records the SHA-256 and ELF build ID of both the direct link output and the
installed executable, and requires identical bytes or a matching nonempty
build ID when Stack strips/copies the installed executable. This is
stronger than finding a package somewhere in the installed package database.
It still does not substitute for runtime tests or prove that the patched
binary has the desired API behavior. The link-command extractor assumes Cabal
verbosity 3 prints the final GHC invocation on one line. That format has not
been tested with a cold build; an unexpected format fails the job closed.

The artifact is metadata only, retained for three days under repository
Actions permissions. The executable and raw build log are **not** uploaded.
The job uses read-only repository permission and disables persisted checkout
credentials. A failure leaves the GitHub job log for diagnosis but does not
publish a partial evidence artifact. Review the resulting unit closure,
linker map, and binary hash before relying on a later image build. A retained
hash alone cannot prove a later image copied those bytes: hash the executable
inside that image and compare it to this evidence before making that claim. This
procedure addresses only native arm64; a separate, verified Nix build and
link-evidence extraction would be needed for amd64.
