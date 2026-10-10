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

Runtime URL imports are not vendored in the source archive. Functions reference
the Deno standard library 0.192.0 (MIT), the Supabase JS 2.39.0 package (MIT),
and the optional `ipp` 2.0.1 package (MIT). `jose` 5.10.0 (MIT, Filip Skokan)
is a runtime URL import and, at the same version, the locked local development
dependency the unit tests use; its installed license is
`node_modules/jose/LICENSE.md`. The exact versions are listed in
`functions/import_map.json`.

The Compose files reference pinned upstream container images but do not
redistribute their contents. Operators who redistribute images must review each
image's upstream terms. See `docs/ATTRIBUTION_REVIEW.md` for the reviewed
inventory, provenance boundary, and maintainer attestation.

## Grafana (AGPL-3.0)

Grafana is licensed under the GNU Affero General Public License v3.0
(upstream: https://github.com/grafana/grafana; the complete licence text is
vendored at `LICENSES/grafana/LICENSE`, see `LICENSES/grafana/README.md`).
`docker/grafana/Dockerfile` builds the local `warehouse-grafana:local` image
from the publisher's digest-pinned `grafana/grafana:13.2.2` image: it upgrades
two Alpine libraries and replaces the bundled plugins with publisher-signed,
checksum-pinned releases (`plugins.lock`, `install-plugins.sh`). No Grafana
source is modified or vendored here; the earlier core-rebuild research and its
Thrift patch were retired under the won't-fix disposition in
`docs/PRODUCTION_DEPENDENCIES.md`.

This repository redistributes neither the publisher image nor any rebuilt
image: operators build `warehouse-grafana:local` on their own host at setup
time. An operator who distributes a rebuilt or modified Grafana image must offer
its corresponding source under AGPL-3.0, and one who modifies Grafana (for
example by applying the Thrift patch) and lets users interact with it over a
network must offer the modified source as well (AGPL-3.0 section 13). The
Grafana provisioning files adapted from `supabase/supabase` remain Apache-2.0.

## Referenced publisher images

The Compose files and recipes reference these publisher images without
redistributing them. Versions are the ones pinned in
`docker/docker-compose*.yml` and `docker/*/Dockerfile` at the time of writing.

| Project | Version | Licence | Upstream |
| --- | --- | --- | --- |
| Kong Gateway (open source) | 3.9.3 (`kong:3.9.3-ubuntu`) | Apache-2.0 | https://github.com/Kong/kong |
| PostgREST | v16.4 (`postgrest/postgrest:v16.4`) | MIT | https://github.com/PostgREST/postgrest |
| Supabase Realtime | v2.134.10 (base of `docker/realtime/Dockerfile`) | Apache-2.0 | https://github.com/supabase/realtime |
| Supavisor | 2.9.13 (base of `docker/supavisor/Dockerfile`) | Apache-2.0 | https://github.com/supabase/supavisor |
| Supabase edge-runtime | v1.77.4 (base of `docker/edge-runtime/Dockerfile`) | MIT | https://github.com/supabase/edge-runtime |
| Supabase Studio | 2026.09.21-sha-512201d (base of `docker/studio/Dockerfile`) | Apache-2.0 | https://github.com/supabase/supabase (`apps/studio`) |
| Gotenberg | 8.37.0 (base of `docker/gotenberg/Dockerfile`) | MIT | https://github.com/gotenberg/gotenberg |
| CUPS container base image: Ubuntu | 22.04 (`ubuntu:22.04`, `docker/cups/Dockerfile`) | Ubuntu packages under their individual free-software licences; CUPS itself Apache-2.0 with upstream's stated exceptions | https://hub.docker.com/_/ubuntu and https://github.com/OpenPrinting/cups |
| Grafana | 13.2.2 (`grafana/grafana:13.2.2`) | AGPL-3.0 | https://github.com/grafana/grafana |

## Maintained container source recipes (2026-09-22)

The dependency manifests under `docker/alertmanager`, `docker/node-exporter`,
`docker/postgres-exporter`, `docker/cadvisor`, `docker/prometheus`,
`docker/gotenberg`, `docker/auth`, `docker/storage`, `docker/imgproxy`, and `docker/postgres`
are copied from the upstream versions listed in
[CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) and modified to resolve
security updates. Recipe URLs and SHA-256 checksums identify the source archives.
No third-party executable or source archive is committed or published here.

The Grafana recipe uses the publisher's digest-pinned 13.2.2 image and
copies no application or plugin files into the source repository; the plugins it
installs are the publisher-signed releases listed in `docker/grafana/plugins.lock`
with their own manifests and notices (see the Grafana section above). The PostgREST image is the publisher's static v16.4 image. The release-binary
identity check and the unresolved component inventory recorded in
[CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) were made for the earlier
v14.17 image and have not been repeated for v16.4.

Upstream license files were read from those source archives (Storage's license
from its matching release tag). Their complete texts and available NOTICE files
are retained under `LICENSES/{alertmanager,node-exporter,postgres-exporter,
cadvisor,prometheus,pdfcpu,auth,storage,imgproxy,gosu,wal-g}/`. GoTrue/Auth is MIT
(Copyright 2021–2025 Supabase); imgproxy is MIT (Copyright 2017 Sergey
Alexandrovich); the other listed projects use Apache-2.0.
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
