# PostgREST v14.17 dependency resolution experiment

This is an evaluation-only candidate. It does not build an executable or image.
The source is upstream `v14.17` at commit
`064e5fea7bde63b0424fab53a0109c6f6016e95c`. The source script rejects
any other checkout before making changes.

| Hackage archive | SHA-256 (hex) | Nix SRI |
| --- | --- | --- |
| `aeson-2.2.5.1.tar.gz` | `ea82d650c0bbd8877dbf13a03b9baae3be7ed4a65f4e8cfe5b4eacb4f5beae75` | `sha256-6oLWUMC72Id9vxOgO5uq475+1KZfToz+W06stPW+rnU=` |
| `text-iso8601-0.1.1.2.tar.gz` | `ddbb13aec70a2fd54c7a25bf85e38a467d0d5599980d21f4925b3c706f8f7398` | `sha256-3bsTrscKL9VMeiW/heOKRn0NVZmYDSH0kls8cG+Pc5g=` |

The archives were downloaded from Hackage, hashed locally, and independently
matched against the `package-hashes.SHA256` and `package-size` fields in the
[`all-cabal-hashes` Hackage index mirror](https://github.com/commercialhaskell/all-cabal-hashes/tree/hackage).
The archive sizes are 341499 and 10174 bytes respectively.

PostgREST's `aeson >= 2.0.3 && < 2.3` accepts 2.2.5.1. The locked Nixpkgs
revision `c80edd02003fe3d8af527215a3ac069be9cfd47f` has `hashable`
1.4.7.0, which satisfies the new `aeson` source's `hashable >= 1.4.6.0`
bound. Nix evaluation itself remains unverified on this host because Nix is
unavailable. The CI experiment evaluates `postgrestStatic`, exports its recursive
derivation graph, and fails unless it selects `aeson` 2.2.5.1,
`text-iso8601` 0.1.1.2 and `hashable` 1.4.7.0. It also checks that the two
Hackage fetch derivations are inputs of their selected package derivations and
declare the expected flat SHA-256 archive hashes. The graph and top-level
derivation path are saved as a CI artifact. These are declaration checks:
evaluation does not download or verify archive bytes, build packages, or prove
which packages will be linked into an executable.

The upstream `lts-22.44` snapshot includes `hashable` 1.4.4.0. Since
`aeson` 2.2.5.1 requires at least 1.4.6.0, the two proposed Stack extra-deps
alone cannot resolve against that snapshot. The CI Stack experiment adds
`hashable-1.4.7.0` as a third extra-dep on a native arm64 runner and runs
`stack build --dry-run` without a binary build. Its result, including any
further transitive conflicts, must be checked before a build recipe is claimed.

The workflow runs on a PR that changes its workflow or script, and can be
dispatched manually after the workflow exists on the default branch. The job
timeouts are 25 minutes. No workflow result has been claimed here.
