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
the Deno standard library 0.192.0 (MIT), Supabase JS/functions packages (MIT),
and the optional `ipp` 2.0.1 package (MIT). The locked local development
dependency `jose` 5.10.0 is MIT licensed by Filip Skokan; its installed license
is `node_modules/jose/LICENSE.md`.

The Compose files reference pinned upstream container images but do not
redistribute their contents. Operators who redistribute images must review each
image's upstream terms. See `docs/ATTRIBUTION_REVIEW.md` for the reviewed
inventory, provenance boundary, and maintainer attestation.

## Maintained container source recipes (2026-09-22)

The dependency manifests under `docker/alertmanager`, `docker/node-exporter`,
`docker/postgres-exporter`, `docker/cadvisor`, `docker/prometheus`,
`docker/gotenberg`, `docker/auth`, `docker/storage`, `docker/imgproxy`, and `docker/postgres`
are copied from the upstream versions listed in
[CONTAINER_SECURITY.md](docs/CONTAINER_SECURITY.md) and modified to resolve
security updates. Recipe URLs and SHA-256 checksums identify the source archives.
No third-party executable or source archive is committed or published here.

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
