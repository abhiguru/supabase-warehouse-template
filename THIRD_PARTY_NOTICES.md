# Third-Party Notices

This repository includes and adapts configuration and database initialization files
from the Supabase project:

- Project: Supabase
- Source: https://github.com/supabase/supabase
- License: Apache License 2.0

The affected material includes `docker/volumes/db/_supabase.sql`, `pooler.sql` and `roles.sql`, and the Supavisor
configuration. (`docker/volumes/db/00-bootstrap.sql` is original to this repository.) Those files remain subject to their
upstream Apache-2.0 terms and notices. The repository's MIT license applies to
the original warehouse-template code and does not replace third-party licenses.

The complete Apache License 2.0 text is included at
`LICENSES/Apache-2.0.txt`.

The edge functions carry one third-party library as a built file:
`functions/vendor/jose.mjs` (`jose` 5.10.0, MIT, Filip Skokan). supabase-js is
no longer bundled: the functions reach PostgREST and Storage through
`functions/_shared/supabase-rest.ts`, original project code on plain `fetch`.
The licence text of every package `jose.mjs` may contain is in
`functions/vendor/LICENSES.txt`; the exact versions are in
`scripts/edge-vendor/package-lock.json`. `jose` at the same version is also
the locked local development dependency the unit tests use. The optional `ipp`
2.0.1 package (MIT) is not vendored: the printing functions import it at run
time, and the router refuses those functions.

The Compose files reference pinned upstream container images but do not
redistribute their contents. Operators who redistribute images must review each
image's upstream terms. See `docs/ATTRIBUTION_REVIEW.md` for the reviewed
inventory, provenance boundary, and maintainer attestation.

## Sensor bridge (GPL-3.0-or-later)

`docker/sensor-bridge/` is the optional Tapo sensor bridge (Compose profile
`sensors`, see `docs/SENSORS.md`). It uses python-kasa, which is licensed under
the GNU General Public License v3.0, so the bridge's own code in that directory
is licensed **GPL-3.0-or-later** (complete text in
`docker/sensor-bridge/LICENSE`), not MIT. The rest of this repository stays
MIT: the bridge is a separate program that talks to the backend only over HTTP
(the `ingest-sensor-readings` function through the gateway), and no other code
here imports the bridge or python-kasa.

python-kasa and its dependencies are not vendored. `docker/sensor-bridge/requirements.txt`
pins them, and pip installs them from PyPI when the operator builds the
installation's bridge image (`<project>-sensor-bridge`) on their own host. This
repository redistributes no built image. An operator who distributes a built
bridge image distributes python-kasa and the bridge, and must offer their
complete corresponding source under the GPL (GPL-3.0 section 6), together with
the licences of the other packages in the image. Running the bridge on one's
own premises is not distribution.

| Project | Version | Licence | Upstream |
| --- | --- | --- | --- |
| python-kasa | 0.11.0.1 (`python-kasa==0.11.0.1` in `docker/sensor-bridge/requirements.txt`) | GPL-3.0 | https://github.com/python-kasa/python-kasa |

The other packages pinned in that file keep their own upstream licences.

## Referenced publisher images

The Compose files and recipes reference these publisher images without
redistributing them. Versions are the ones pinned in
`docker/docker-compose*.yml` and `docker/*/Dockerfile` at the time of writing.

| Project | Version | Licence | Upstream |
| --- | --- | --- | --- |
| Kong Gateway (open source) | 3.9.3 (`kong:3.9.3-ubuntu`) | Apache-2.0 | https://github.com/Kong/kong |
| PostgREST | v16.4 (`postgrest/postgrest:v16.4`, pinned by index digest) | MIT | https://github.com/PostgREST/postgrest |
| PostgreSQL (official Docker image) | 17.11 (`postgres:17.11-trixie`, pinned by tag and index digest in `docker/postgres/Dockerfile`; the Supabase PostgreSQL image is no longer used) | PostgreSQL License for PostgreSQL; Debian packages under their individual free-software licences | https://hub.docker.com/_/postgres and https://www.postgresql.org/ |
| Supavisor | 2.9.13 (base of `docker/supavisor/Dockerfile`) | Apache-2.0 | https://github.com/supabase/supavisor |
| Supabase edge-runtime | v1.77.4 (only its `edge-runtime` binary is copied, onto `debian:bookworm-slim`, by `docker/edge-runtime/Dockerfile`) | MIT | https://github.com/supabase/edge-runtime |
| Chrome for Testing (chrome-headless-shell) | 155.0.8059.84 (`ARG CHS_VERSION` in `docker/pdf-renderer/Dockerfile`, downloaded at build time and checked against `ARG CHS_SHA256`) | BSD-3-Clause (Chromium), plus the bundled third-party notices of the archive | https://googlechromelabs.github.io/chrome-for-testing/ and https://www.chromium.org/ |
| puppeteer-core | 25.14.0 (`docker/pdf-renderer/package.json`, pinned exactly) | Apache-2.0 | https://github.com/puppeteer/puppeteer |
| CUPS container base image: Ubuntu | 22.04 (`ubuntu:22.04`, `docker/cups/Dockerfile`) | Ubuntu packages under their individual free-software licences; CUPS itself Apache-2.0 with upstream's stated exceptions | https://hub.docker.com/_/ubuntu and https://github.com/OpenPrinting/cups |
| Sensor bridge base image: Python | 3.14-slim-bookworm (`python:3.14-slim-bookworm`, `docker/sensor-bridge/Dockerfile`) | Python under PSF-2.0; Debian packages under their individual free-software licences | https://hub.docker.com/_/python and https://github.com/python/cpython |

## Maintained container source recipes (2026-09-22)

The dependency manifest under `docker/storage` is copied from the upstream version listed in
[CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) and modified to resolve
security updates. `docker/postgres` is the official PostgreSQL 17 image plus one component built from source: `gosu`
1.19, rebuilt with a patched Go toolchain (Apache-2.0; text in `LICENSES/gosu/LICENSE`, also copied into the image).
(The Alertmanager, node exporter, Postgres exporter, cAdvisor and Prometheus recipes were removed on 2026-10-19.) Recipe URLs and SHA-256 checksums identify the source archives.
No third-party executable or source archive is committed or published here.

The PostgREST image is the publisher's static v16.4 image. The release-binary
identity check and the unresolved component inventory recorded in
[CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) were made for the earlier
v14.17 image and have not been repeated for v16.4.

Upstream license files were read from those source archives (Storage's license
from its matching release tag). Their complete texts and available NOTICE files
are retained under `LICENSES/{storage,gosu}/` (and `LICENSES/chrome-headless-shell/`, `LICENSES/puppeteer-core/` for the PDF renderer's downloaded and installed components). The projects in the braces use Apache-2.0.
Each source-built runtime image also retains the corresponding upstream license
and available NOTICE. Dependencies keep their own upstream terms; this inventory
does not authorize redistribution of the resulting images or native binaries.
