# Ownership and third-party attribution review

Review date: **2026-09-18**. Release scope: **`v0.2.2-demo` source-only prerelease**.

## Maintainer attestation

The repository maintainer, `abhiguru`, confirms that they hold the rights needed
to redistribute the original backend source, SQL migrations, scripts, tests, and
documentation in this repository under its MIT license. This attestation does
not claim ownership of Supabase-derived configuration, external modules,
container images, trademarks, or any other third-party material.

This is the maintainer's scoped factual confirmation for release review. It is
not a blanket legal certification and does not replace third-party license terms.

## Tracked-material inventory

| Material | Provenance | License / permission | License or notice location |
| --- | --- | --- | --- |
| Warehouse functions, migrations, scripts, tests, and documentation | Original project work confirmed by the maintainer | MIT | `LICENSE` |
| Supabase Docker/database bootstrap, Grafana provisioning, and Supavisor configuration | Adapted from `supabase/supabase` self-hosting material | Apache-2.0 | `LICENSES/Apache-2.0.txt` and `THIRD_PARTY_NOTICES.md`; upstream copyright notices retained in copied files where present |
| Deno standard-library imports at `0.192.0` | Runtime URL imports; not vendored in the source archive | MIT | Upstream module license; recorded in `THIRD_PARTY_NOTICES.md` |
| Supabase JS/functions imports from esm.sh | Runtime URL imports; not vendored in the source archive | MIT | Upstream package license; recorded in `THIRD_PARTY_NOTICES.md` |
| `jose` 5.10.0 | Locked npm development dependency; not vendored in the source archive | MIT, Filip Skokan | Installed `node_modules/jose/LICENSE.md`; package identity locked in `package-lock.json` |
| `ipp` 2.0.1 | Optional runtime npm import used only by unsupported printing paths; not vendored | MIT | Upstream npm package license; identity pinned in source imports |
| Referenced container images | Pulled at setup time; image contents are not redistributed in the source archive | Each image's upstream terms | Exact image names/tags are in `docker/docker-compose*.yml` and digest-pinned local build recipes in `docker/*/Dockerfile`; downstream operators must review image licenses before distribution |

No image, font, audio, video, or native binary asset is tracked in the backend
source tree. Placeholder webhook URLs are configuration examples, not copied
credentials or protected assets.

## Review conclusion

The Apache-2.0 text required for the adapted Supabase configuration is included,
and the original repository MIT license remains separate. No unresolved
provenance item blocks this source-only prerelease. Future vendored code,
container redistribution, assets, or binaries require a new review; this record
must not be reused as blanket approval.

## Source recipe follow-up — 2026-09-22

New copied dependency manifests are inventoried in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md#maintained-container-source-recipes-2026-09-22).
Their upstream license texts and available notices were checked against the
matching source archives and included under `LICENSES/`. Modifications are
identified in [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md). This follow-up
covers the recipe/manifests source changes, not distribution of built images,
container dependency relicensing, or a new ownership attestation.


The postgres-meta v0.99.0 follow-up adds copied manifests and a source patch.
Its repository license was read directly from the checksum-verified archive and
retained under `LICENSES/postgres-meta/`; the upstream package metadata's differing
MIT label is explicitly recorded in `THIRD_PARTY_NOTICES.md`. Studio adds only a
recipe referencing its publisher image; no frontend assets are vendored.
