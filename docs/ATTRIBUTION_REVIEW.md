# Ownership and third-party attribution review

Review date: **2026-10-08** (refreshing the 2026-09-18 and 2026-09-22 reviews
below). Release scope: **`v0.3.0` public template, fresh repository history**.

## Maintainer attestation

The repository maintainer, `abhiguru`, confirms that they hold the rights needed
to redistribute the original backend source, SQL migrations, scripts, tests, and
documentation in this repository under its MIT license, and the original sensor
bridge code under `docker/sensor-bridge/` under GPL-3.0-or-later. This attestation does
not claim ownership of Supabase-derived configuration, external modules,
container images, trademarks, or any other third-party material.

This is the maintainer's scoped factual confirmation for release review. It is
not a blanket legal certification and does not replace third-party license terms.

## Tracked-material inventory

| Material | Provenance | License / permission | License or notice location |
| --- | --- | --- | --- |
| Warehouse functions, migrations, scripts, tests, and documentation (everything outside `docker/sensor-bridge/`) | Original project work confirmed by the maintainer | MIT | `LICENSE` |
| Sensor bridge (`docker/sensor-bridge/`) | Original project work confirmed by the maintainer; installs python-kasa 0.11.0.1 (GPL-3.0) and its pinned dependencies from PyPI at image build time, not vendored; base image Python 3.14-slim-bookworm (PSF-2.0, Debian packages) | GPL-3.0-or-later (bridge code); GPL-3.0 (python-kasa) | `docker/sensor-bridge/LICENSE`; "Sensor bridge" section of `THIRD_PARTY_NOTICES.md` |
| Supabase Docker/database bootstrap and Supavisor configuration | Adapted from `supabase/supabase` self-hosting material | Apache-2.0 | `LICENSES/Apache-2.0.txt` and `THIRD_PARTY_NOTICES.md`; upstream copyright notices retained in copied files where present |
| Deno standard-library imports at `0.192.0` | Runtime URL imports; not vendored in the source archive | MIT | Upstream module license; recorded in `THIRD_PARTY_NOTICES.md` |
| Supabase JS 2.39.0 | Removed 2026-10-19: no longer imported or bundled; `functions/_shared/supabase-rest.ts` is original project code on plain `fetch` | n/a | n/a |
| `jose` 5.10.0 | Runtime URL import from esm.sh and, at the same version, locked npm development dependency; not vendored in the source archive | MIT, Filip Skokan | Installed `node_modules/jose/LICENSE.md`; package identity locked in `package-lock.json` |
| `ipp` 2.0.1 | Optional runtime npm import used only by unsupported printing paths; not vendored | MIT | Upstream npm package license; identity pinned in source imports |
| Source-built service recipes (`docker/{storage,postgres}`; the Alertmanager, node exporter, Postgres exporter, cAdvisor and Prometheus recipes were removed on 2026-10-19) | Copied upstream manifests plus security patches; archives fetched by checksum at build time | Apache-2.0 | `LICENSES/<project>/` and `THIRD_PARTY_NOTICES.md` |
| PDF renderer (`docker/pdf-renderer/`) | Original project work for this repository; downloads Chrome for Testing 155.0.8059.84 (chrome-headless-shell) at image build time (checksum pinned) and installs puppeteer-core 25.14.0 and its locked dependencies with `npm ci`; fonts are Debian packages; nothing third-party is committed | MIT (renderer code); BSD-3-Clause plus bundled notices (Chrome for Testing); Apache-2.0 (puppeteer-core); font and library packages under their own licences | `LICENSES/chrome-headless-shell/`, `LICENSES/puppeteer-core/`, `THIRD_PARTY_NOTICES.md`; the archive's own `LICENSE.headless_shell` stays in the image at `/opt/chs` |
| Referenced publisher images (Kong 3.9.3, PostgREST v16.4, Supavisor 2.9.13, edge-runtime v1.77.4, CUPS on `ubuntu:22.04`, the sensor bridge on Python 3.14-slim-bookworm) | Pulled at setup time; image contents are not redistributed in the source archive | Apache-2.0 / MIT / PSF-2.0 / Ubuntu and Debian package terms, per the table in `THIRD_PARTY_NOTICES.md` | `THIRD_PARTY_NOTICES.md` "Referenced publisher images"; exact tags and digests in `docker/docker-compose*.yml` and `docker/*/Dockerfile`; downstream operators must review image licences before distribution |

No image, font, audio, video, or native binary asset is tracked in the backend
source tree. Placeholder webhook URLs are configuration examples, not copied
credentials or protected assets.

## Review conclusion

The Apache-2.0 text required for the adapted Supabase configuration is included,
every referenced publisher image has a
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


Supabase Studio and postgres-meta were removed from the template (2026-10-19);
their recipes, patches and `LICENSES/postgres-meta/` are no longer shipped.

## Public template refresh — 2026-10-08

The pilot campaign tooling and dated evidence documents were moved to a private
repository (see [HISTORY.md](HISTORY.md)); nothing vendored changed. This
refresh added the publisher-image table in
`THIRD_PARTY_NOTICES.md` and the rows above. The
maintainer attestation and the 2026-09-22 recipe follow-up stand unchanged.

## Sensor bridge — 2026-10-13

The optional Tapo sensor bridge (`docker/sensor-bridge/`, Compose profile
`sensors`) uses python-kasa 0.11.0.1, licensed GPL-3.0. The bridge's own code is
therefore licensed GPL-3.0-or-later, with the complete licence text in
`docker/sensor-bridge/LICENSE`; it is a separate program that reaches the
backend over HTTP only, and the rest of the repository stays MIT. python-kasa
and its dependencies are pinned in `docker/sensor-bridge/requirements.txt` and
installed from PyPI when the operator builds the image; nothing is vendored and
no image is redistributed. Distributing a built bridge image carries the GPL
source offer described in `THIRD_PARTY_NOTICES.md`. The licences of the other
pinned packages were not reviewed one by one in this record.
