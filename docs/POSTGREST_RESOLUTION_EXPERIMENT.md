# PostgREST v14.17 dependency resolution experiment

This is an evaluation-only candidate. It does not build an executable or image.
The source is upstream `v14.17` at commit
`064e5fea7bde63b0424fab53a0109c6f6016e95c`. The source script rejects
any other checkout before making changes.

| Hackage archive | Archive SHA-256 (hex) | Unpacked Nix `fetchzip` SRI |
| --- | --- | --- |
| `aeson-2.2.5.1.tar.gz` | `ea82d650c0bbd8877dbf13a03b9baae3be7ed4a65f4e8cfe5b4eacb4f5beae75` | `sha256-f1XeeVxXxoIVqHGNGUlbSL4LpF0jxjPlnC4XUpEf7C4=` |
| `text-iso8601-0.1.1.2.tar.gz` | `ddbb13aec70a2fd54c7a25bf85e38a467d0d5599980d21f4925b3c706f8f7398` | `sha256-4Azo1F6qDFNNRKWLpBJUGl7nspnCOoQM0C8H9vkFIMs=` |

The archives were downloaded from Hackage, hashed locally, and independently
matched against the `package-hashes.SHA256` and `package-size` fields in the
[`all-cabal-hashes` Hackage index mirror](https://github.com/commercialhaskell/all-cabal-hashes/tree/hackage).
The archive sizes are 341499 and 10174 bytes respectively.
The locked Nixpkgs `callHackageDirect` calls `fetchzip`, which hashes the
unpacked source tree recursively rather than the `.tar.gz` bytes. Nix 2.31.2
`nix-prefetch-url --unpack` produced the two Nix values above from the
archive-verified files. The aeson value matches the expected hash reported by
the first PR #49 Nix run; that run failed because it had used the archive hash
as the `fetchzip` hash. The subsequent Nix evaluation at `a916b51` passed and
saved a recursive derivation graph containing both declared unpacked hashes.

PostgREST's `aeson >= 2.0.3 && < 2.3` accepts 2.2.5.1. The locked Nixpkgs
revision `c80edd02003fe3d8af527215a3ac069be9cfd47f` has `hashable`
1.4.7.0, which satisfies the new `aeson` source's `hashable >= 1.4.6.0`
bound. Nix evaluation itself remains unverified on this host because Nix is
unavailable. The CI experiment evaluates `postgrestStatic`, exports its recursive
derivation graph, and fails unless the selected PostgREST 14.17 derivation
directly depends on `aeson` 2.2.5.1, and that aeson derivation directly depends
on `text-iso8601` 0.1.1.2 and `hashable` 1.4.7.0. It rejects another hashable
version anywhere below the selected aeson derivation. It also checks that the
two Hackage fetch derivations are inputs of their selected package derivations
and declare the expected recursive SHA-256 unpacked-source hashes. The graph
and top-level derivation path are saved as a CI artifact. These are build-input
declaration checks: evaluation does not download or verify archive bytes, build
packages, or prove which packages will be linked into an executable.

The upstream `lts-22.44` snapshot includes `hashable` 1.4.4.0. Since
`aeson` 2.2.5.1 requires at least 1.4.6.0, the two proposed Stack extra-deps
alone cannot resolve against that snapshot. The CI Stack experiment adds
`hashable-1.4.7.0` on a native arm64 runner and runs `stack build --dry-run`
without a binary build. Once Hackage metadata recovered, the Stack plan found
that `character-ps` 0.1 is absent from the snapshot. The experiment now also
pins `character-ps-0.1@sha256:b38ed1c07ae49e7461e44ca1d00c9ca24d1dcb008424ccd919916f92fd48d9fe,1315`.
That is the SHA-256 and byte length of the Cabal metadata file, independently
checked against Hackage; it is not the source archive hash. The next Stack
dry run found another bound conflict: snapshot `attoparsec-aeson` 2.1.0.0
requires `aeson < 2.2`. The candidate now pins `attoparsec-aeson` 2.2.2.0,
whose current revision allows `aeson >= 2.2.2.0 && < 2.4`. Its Cabal metadata
pin `sha256:08948f45b892c5758d2c42e22fe2fbd41a4f6dc395fb0a43c2bf458a1f295736,1664`
selects Cabal revision 1 and was checked against Hackage and the Hackage
index mirror. The distinct source archive has SHA-256
`fe9b2c23a16fe1ff8f41c329940cccc80aca7ac6a9ea314f7a77cf142d8f9edd`
and size 8081 bytes, both matching index metadata. Its embedded revision 0
Cabal file has SHA-256
`02dc3cc4d217a364471da7ce0f47be39e5b1449e7768134e5f2926d87a21448d`
and size 1590 bytes. Any further transitive conflicts must be resolved before
a build recipe is claimed.
The first PR #49 Stack run stopped before planning: Hackage Security rejected
`snapshot.json` with an invalid hash while updating the package index. A fresh
run should retain repository verification; a repeated failure needs the served
timestamp and snapshot response hashes investigated before trusting a plan.

The workflow runs on a PR that changes its workflow or script, and can be
dispatched manually after the workflow exists on the default branch. The job
timeouts are 25 minutes. No successful resolution has been claimed here.
