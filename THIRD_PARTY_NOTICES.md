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
