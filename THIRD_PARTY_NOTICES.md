# Third-Party Notices

This repository includes and adapts configuration and database bootstrap files
from the Supabase project:

- Project: Supabase
- Source: https://github.com/supabase/supabase
- License: Apache License 2.0

The affected material includes files under `docker/volumes/db/`, Grafana
provisioning, and Supavisor configuration. Those files remain subject to their
upstream Apache-2.0 terms and notices. The repository's MIT license applies to
the original warehouse-template code and does not replace third-party licenses.

The complete Apache License 2.0 text is included at
`LICENSES/Apache-2.0.txt`.

The edge functions carry two third-party libraries as built files:
`functions/vendor/jose.mjs` (`jose` 5.10.0, MIT, Filip Skokan) and
`functions/vendor/supabase-js.mjs` (the Supabase JS 2.39.0 package, MIT, with
its dependencies). The licence text of every package they may contain is in
`functions/vendor/LICENSES.txt`; the exact versions are in
`scripts/edge-vendor/package-lock.json`. `jose` at the same version is also
the locked local development dependency the unit tests use. The optional `ipp`
2.0.1 package (MIT) is not vendored: the printing functions import it at run
time, and the router refuses those functions.

The Compose files reference pinned upstream container images but do not
redistribute their contents. Operators who redistribute images must review each
image's upstream terms. See `docs/ATTRIBUTION_REVIEW.md` for the reviewed
inventory, provenance boundary, and maintainer attestation.

## Grafana (AGPL-3.0)

Grafana is licensed under the GNU Affero General Public License v3.0
(upstream: https://github.com/grafana/grafana; the complete licence text is
vendored at `LICENSES/grafana/LICENSE`, see `LICENSES/grafana/README.md`).
`docker/grafana/Dockerfile` builds the installation's local Grafana image
(`<project>-grafana`) from the publisher's digest-pinned `grafana/grafana:13.2.4`
image: it upgrades two Alpine libraries and replaces the bundled plugins with
publisher-signed, checksum-pinned releases (`plugins.lock`, `install-plugins.sh`). No Grafana
source is modified or vendored here; the earlier core-rebuild research and its
Thrift patch were retired under the won't-fix disposition in
`docs/PRODUCTION_DEPENDENCIES.md`.

This repository redistributes neither the publisher image nor any rebuilt
image: operators build the installation's local Grafana image
(`<project>-grafana`) on their own host at setup time. An operator who
distributes a rebuilt or modified Grafana image must offer its corresponding
source under AGPL-3.0, and one who modifies Grafana (for
example by applying the Thrift patch) and lets users interact with it over a
network must offer the modified source as well (AGPL-3.0 section 13). The
Grafana provisioning files adapted from `supabase/supabase` remain Apache-2.0.

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
| Supabase Realtime | v2.143.3 (base of `docker/realtime/Dockerfile`) | Apache-2.0 | https://github.com/supabase/realtime |
| Supavisor | 2.9.13 (base of `docker/supavisor/Dockerfile`) | Apache-2.0 | https://github.com/supabase/supavisor |
| Supabase edge-runtime | v1.77.4 (base of `docker/edge-runtime/Dockerfile`) | MIT | https://github.com/supabase/edge-runtime |
| Supabase Studio | 2026.10.12-sha-3699278 (base of `docker/studio/Dockerfile`) | Apache-2.0 | https://github.com/supabase/supabase (`apps/studio`) |
| Chrome for Testing (chrome-headless-shell) | 155.0.8059.84 (`ARG CHS_VERSION` in `docker/pdf-renderer/Dockerfile`, downloaded at build time and checked against `ARG CHS_SHA256`) | BSD-3-Clause (Chromium), plus the bundled third-party notices of the archive | https://googlechromelabs.github.io/chrome-for-testing/ and https://www.chromium.org/ |
| puppeteer-core | PUPPETEER_VERSION (`docker/pdf-renderer/package.json`, pinned exactly) | Apache-2.0 | https://github.com/puppeteer/puppeteer |
| CUPS container base image: Ubuntu | 22.04 (`ubuntu:22.04`, `docker/cups/Dockerfile`) | Ubuntu packages under their individual free-software licences; CUPS itself Apache-2.0 with upstream's stated exceptions | https://hub.docker.com/_/ubuntu and https://github.com/OpenPrinting/cups |
| Grafana | 13.2.4 (`grafana/grafana:13.2.4`) | AGPL-3.0 | https://github.com/grafana/grafana |
| Sensor bridge base image: Python | 3.14-slim-bookworm (`python:3.14-slim-bookworm`, `docker/sensor-bridge/Dockerfile`) | Python under PSF-2.0; Debian packages under their individual free-software licences | https://hub.docker.com/_/python and https://github.com/python/cpython |

## Maintained container source recipes (2026-09-22)

The dependency manifests under `docker/alertmanager`, `docker/node-exporter`,
`docker/postgres-exporter`, `docker/cadvisor`, `docker/prometheus`,
`docker/auth`, `docker/storage`, `docker/imgproxy`, and `docker/postgres`
are copied from the upstream versions listed in
[CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) and modified to resolve
security updates. Recipe URLs and SHA-256 checksums identify the source archives.
No third-party executable or source archive is committed or published here.

The Grafana recipe uses the publisher's digest-pinned 13.2.4 image and
copies no application or plugin files into the source repository; the plugins it
installs are the publisher-signed releases listed in `docker/grafana/plugins.lock`
with their own manifests and notices (see the Grafana section above). The PostgREST image is the publisher's static v16.4 image. The release-binary
identity check and the unresolved component inventory recorded in
[CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) were made for the earlier
v14.17 image and have not been repeated for v16.4.

Upstream license files were read from those source archives (Storage's license
from its matching release tag). Their complete texts and available NOTICE files
are retained under `LICENSES/{alertmanager,node-exporter,postgres-exporter,
cadvisor,prometheus,auth,storage,imgproxy,gosu,wal-g}/` (and `LICENSES/chrome-headless-shell/`, `LICENSES/puppeteer-core/` for the PDF renderer's downloaded and installed components). GoTrue/Auth is MIT
(Copyright 2021–2025 Supabase); imgproxy is MIT (Copyright 2017 Sergey
Alexandrovich); the other listed
projects use Apache-2.0.
Each source-built runtime image also retains the corresponding upstream license
and available NOTICE. Dependencies keep their own upstream terms; this inventory
does not authorize redistribution of the resulting images or native binaries.


### Postgres-meta source migration

`docker/postgres-meta` contains modified v0.99.0 package manifests and an explicit
source patch. Its source URL/checksum is in the Dockerfile. The repository's
actual `LICENSE` is Apache-2.0 and is retained at
`LICENSES/postgres-meta/LICENSE` and in the runtime image. The upstream
`package.json` separately labels the package MIT; that metadata is preserved,
not substituted for the checked repository license. The source patch retains
upstream authorship and uses the included repository license text. Studio's
recipe references the publisher image and vendors no additional source/assets.
