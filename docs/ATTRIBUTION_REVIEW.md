# Ownership and third-party attribution review

Review date: **2026-10-08** (refreshing the 2026-09-18 and 2026-09-22 reviews
below). Release scope: **`v0.3.0` public template, fresh repository history**.

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
| Supabase JS 2.39.0 import from esm.sh | Runtime URL imports; not vendored in the source archive | MIT | Upstream package license; recorded in `THIRD_PARTY_NOTICES.md` |
| `jose` 5.10.0 | Runtime URL import from esm.sh and, at the same version, locked npm development dependency; not vendored in the source archive | MIT, Filip Skokan | Installed `node_modules/jose/LICENSE.md`; package identity locked in `package-lock.json` |
| `ipp` 2.0.1 | Optional runtime npm import used only by unsupported printing paths; not vendored | MIT | Upstream npm package license; identity pinned in source imports |
| Grafana 13.2.2 recipe (`docker/grafana/`) | Publisher image, pruned/reinstalled publisher-signed plugins | AGPL-3.0 (image); no Grafana source or binary vendored or modified | `LICENSES/grafana/LICENSE` (vendored AGPL-3.0 text) and `LICENSES/grafana/README.md`, Grafana section of `THIRD_PARTY_NOTICES.md` |
| Source-built service recipes (`docker/{alertmanager,node-exporter,postgres-exporter,cadvisor,prometheus,gotenberg,auth,storage,imgproxy,postgres,postgres-meta}`) | Copied upstream manifests plus security patches; archives fetched by checksum at build time | Apache-2.0 or MIT per project (see notices) | `LICENSES/<project>/` and `THIRD_PARTY_NOTICES.md` |
| Referenced publisher images (Kong 3.9.3, PostgREST v16.4, Realtime v2.134.10, Supavisor 2.9.13, edge-runtime v1.77.4, Studio 2026.09.21, Gotenberg 8.37.0, CUPS on `ubuntu:22.04`, Grafana 13.2.2) | Pulled at setup time; image contents are not redistributed in the source archive | Apache-2.0 / MIT / AGPL-3.0 / Ubuntu package terms, per the table in `THIRD_PARTY_NOTICES.md` | `THIRD_PARTY_NOTICES.md` "Referenced publisher images"; exact tags and digests in `docker/docker-compose*.yml` and `docker/*/Dockerfile`; downstream operators must review image licences before distribution |

No image, font, audio, video, or native binary asset is tracked in the backend
source tree. Placeholder webhook URLs are configuration examples, not copied
credentials or protected assets.

## Review conclusion

The Apache-2.0 text required for the adapted Supabase configuration is included,
the AGPL-3.0 obligations for the Grafana recipe and its retained patch are
recorded with the canonical licence URL, every referenced publisher image has a
name, version, licence and upstream entry, and the original repository MIT
license remains separate. No unresolved provenance item blocks this public
template release. Future vendored code,
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

## Public template refresh — 2026-10-08

The pilot campaign tooling and dated evidence documents were moved to a private
repository (see [HISTORY.md](HISTORY.md)); nothing vendored changed. This
refresh added the Grafana AGPL-3.0 notice, the publisher-image table in
`THIRD_PARTY_NOTICES.md`, and the rows above; the retired core-rebuild patch
was removed with its research recipe. The
maintainer attestation and the 2026-09-22 recipe follow-up stand unchanged.
