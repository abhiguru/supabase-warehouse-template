# Storage image recipe

The recipe has two stages. Stage 1 takes the publisher's `supabase/storage-api` image, with its
precompiled application and native modules, and installs this directory's
`package.json` and `package-lock.json` over it. Stage 2 (the image that runs) is a clean
`node:<x>-alpine<y>` image onto which only the patched `/app` is copied, so the compilers and
Python of stage 1 are not shipped. The manifest is the
publisher's own (without `scripts` and `devDependencies`) plus the dependency
versions raised for security fixes.

## Moving to a new publisher tag

The manifest belongs to one tag. Changing the `FROM` line alone installs the
old tag's dependency set under the new application.

1. Read the new image's manifest and lockfile:
   `docker run --rm --entrypoint cat supabase/storage-api:<tag> /app/package.json`
   (and `/app/package-lock.json`).
2. Start from those two files. Drop `scripts` and `devDependencies`, then
   carry over the raised versions and the `overrides` block from the current
   `package.json`, leaving out any the new tag already meets.
3. `npx -y npm@<the image's npm> install --package-lock-only --ignore-scripts --lockfile-version 2` in this directory, with the npm
   the publisher image ships (`docker run --rm --entrypoint npm supabase/storage-api:<tag> -v`; 12.2.1 since v1.85.0) and the
   lockfile version of its own lock. The build's `npm install` runs that npm under the image's `/app/.npmrc` (`engine-strict`,
   `allow-git=root`, `strict-allow-scripts`), so keep the publisher's `engines` and `allowScripts`.
4. Set the tag and digest in `Dockerfile` (`FROM ... AS patched`), keep stage 2's Node image (`node:<x>-alpine<y>`)
   equal in major, minor and Alpine to the publisher image's (`docker run --rm --entrypoint node
   supabase/storage-api:<tag> -v`; `cat /etc/alpine-release` in the same image) and set `ENV VERSION` to the tag's
   version. Build with `--no-cache`, and scan
   the result (`trivy image --severity HIGH,CRITICAL`). Raise or override what
   the scan still names and repeat from step 3. The build fails if the image's npm
   rewrites `package-lock.json` (sha256 compared before and after `npm install`) or if
   `npm ls --omit=dev --all` finds an invalid package; regenerate the lockfile as in step 3.
5. Move the Storage schema version with the tag (the section below): `migrations-head.txt` and `DB_MIGRATIONS_FREEZE_AT`.
6. Update the version in `docs/CONTAINER_SECURITY.md`, then run the operator
   API tests, which upload and read photos and documents.

## The Storage schema version, and the quarterly move

Storage keeps its own database schema in `storage.migrations` and applies the migrations of its image to the catalog every time it
starts, in the schema `storage` that the facility's photos and documents hang from. Upstream adds about 34 a year (object versioning,
for one, rewrote `storage.objects`), so a pin that is never moved ends in one forced jump over dozens of migrations on years of rows,
at the moment a security fix or an end-of-life base image forces it. Owner decision of 2026-10-26: **move the pin every quarter, a few
minors at a time, after the seeded drill.**

Three places hold the version, and `tests/storage-schema.test.mjs` and `tests/migrations.sh` fail when they disagree:

- `migrations-head.txt`: the number (`id=`) and name (`name=`) of the newest migration the image in the `Dockerfile` ships
  (`docker run --rm --entrypoint ls <image> /app/migrations/tenant`; the highest number).
- `docker/docker-compose.yml`, the `storage` service: `DB_MIGRATIONS_FREEZE_AT` is that name. Storage applies no migration beyond it,
  so an image that moved by accident (a Dependabot pull request that was merged without the steps below) cannot change the schema.
- `metadata.txt` and `integrity.txt` of every backup (`scripts/backup-integrity.sql`, `scripts/backup.sh`): `storage_image=` and
  `storage_schema_head=`; `integrity.txt` has `storage_migrations_count=` and `storage_migrations_head=` (the number). `db:verify-restore`,
  `db:restore` and `db:restore-host` refuse a backup whose head is higher than `migrations-head.txt` of the checkout, before anything is
  touched ("check out a release at least as new as the backup"): an older Storage image would start without complaint on a schema it was not built for (it ignores the migrations it does not know), and a
  Storage migration cannot be undone. A lower head is fine; Storage migrates it forward at the next start, as it always did.

**The quarterly move** (a few minors at a time; Dependabot proposes the minor update as a notice, and its pull request fails the tests
until the following is done in it):

1. Choose the target tag: the newest patch of the next one to three minors. Do not jump to the newest minor if it is many migrations
   ahead; the point is small steps.
2. Do the manifest steps above (1 to 4) for the tag, and set in the same change: the stage-1 tag and digest, `ENV VERSION`,
   `migrations-head.txt` (its highest migration) and `DB_MIGRATIONS_FREEZE_AT` in the compose file (the name from the file).
3. Run the drill against the target: `STORAGE_NEXT_TAG=<tag> STORAGE_DRILL_NEXT_REQUIRED=true bash tests/storage-drill.sh`, or set the
   repository variable `STORAGE_NEXT_TAG` and run the `storage-drill` job of the CI workflow. It builds a catalog of thousands of objects
   on the current image and reads every object and a signed URL. It then starts the target with the freeze still set, as an accidental
   bump would (the schema must not move, and the new code must still read every object, sign a URL and take an upload), and then with the
   freeze set to the name of the target's own newest migration file, as you will put it in the compose file. The catalog must end at exactly
   that migration (equal to the current head when the target ships no new Storage migration; the drill says so), with nothing lost, every
   object and signed URL working, and an upload working. It prints how long the start took: `setup.sh` waits 180 s for Storage's migrations,
   and the drill fails above 150 s. That limit is a smoke limit on 5,000 small rows, not a sizing figure: before a move whose migrations touch
   `storage.objects`, run it with `STORAGE_DRILL_OBJECTS` near the object count of the largest facility (`select count(*) from storage.objects`). The drill refuses a `STORAGE_NEXT_TAG` that is not newer than the tag in the `Dockerfile`: **clear the
   variable once the move has merged.**
4. `npm test` and `npm run test:migrations`, then deploy the Dev facility first and look at a photo and a document before any other.

Rehearse the move **before** the first of these is forced on you. When a tag has no usable successor yet, the drill's second half warns
and the first half still proves the current image on a seeded catalog.

`pg-boss` in `package.json` is pinned to one commit of the publisher's fork (`github:supabase/pg-boss#<sha>`), the one the lock
resolved when it was pinned (2026-10-27), so that the branch it used to name cannot move under a rebuild. When a new tag brings another
commit, take it from the new image's own manifest and lock (step 1 above) and run step 3.

2026-10-12, v1.79.14 to v1.80.2: the new tag's lockfile pinned fastify 5.11.2
and `@fastify/busboy` 3.1.1, both with HIGH findings, so `fastify` is raised
to `^5.12.2` and busboy is overridden to 3.2.1.

2026-10-13, two moderate advisories in the locked runtime: `@fastify/busboy`
3.2.1 ([GHSA-gxm5-99cw-xjw9](https://github.com/advisories/GHSA-gxm5-99cw-xjw9),
a bare line feed kept in a multipart filename; the uploader here does not use
that filename for the object key) and `fast-copy` 4.0.2
([GHSA-jggr-w7fw-pc2j](https://github.com/advisories/GHSA-jggr-w7fw-pc2j),
stack exhaustion on deeply nested values; it arrives through `pino-pretty` and
no request-controlled path to it was found). The busboy override is raised to
3.2.3 (3.2.2 is the fix; 3.2.3 adds only a fix for a hang on a multipart
epilogue) and `fast-copy@^4` is overridden to 4.1.2. The override is needed:
a plain lock regeneration keeps 4.0.2, which satisfies `pino-pretty`'s
`^4.0.0`, and a Dependabot bump to 4.1.2 was lost when the lock was rebuilt for
v1.80.2. The lock was regenerated with npm 11.12.1
(`npx -y npm@11.12.1 install --package-lock-only --ignore-scripts
--lockfile-version 2`) and changed only those two packages; `npm audit
--omit=dev` reports 0 vulnerabilities. The image build and the upload tests
run in CI's install job; the `--no-cache` build and Trivy scan (step 4) are
for the release checklist.

2026-10-18: the `undici` override is scoped to `undici@^7` (every 7.x copy is raised to
the root's 7.30.0). `@kubernetes/client-node` declares `undici ^8.7.0` and keeps its nested
8.11.2; an unscoped override made `npm ls` report it invalid.

2026-10-24: advisories published after the last main run failed `check:container-dependencies`:
`undici` [GHSA-xjj6-f33q-929c](https://github.com/advisories/GHSA-xjj6-f33q-929c) (HIGH) with
GHSA-4qv8-2p9j-2685 and GHSA-f72v-6w45-q472 (moderate), in both the root 7.30.0 and the 8.11.2 under
`@kubernetes/client-node`; `fast-uri` (four, up to moderate), `ip-address`
[GHSA-rxp7-6hxx-x8q5](https://github.com/advisories/GHSA-rxp7-6hxx-x8q5) and `fastify`
[GHSA-389g-gv7q-r4x8](https://github.com/advisories/GHSA-389g-gv7q-r4x8) (low). Raised: `undici`
7.30.1 (root, so the `undici@^7` override follows), a new scoped override `undici@^8` 8.12.3 (the nested
copy stays valid for `^8.7.0`), `fast-uri` 3.1.9 and 4.2.3, `ip-address` 10.7.4, `fastify` `^5.12.6`
(locks 5.12.7). The lock was regenerated as above with npm 11.12.1 and changed only those packages;
`npm audit --omit=dev` reports 0 vulnerabilities, and the image builds with its lockfile and `npm ls` guards.

2026-10-30: three advisories on `systeminformation`, which the OpenTelemetry host-metrics packages and platformatic pull in:
[GHSA-3f7j-7jwc-fxfj](https://github.com/advisories/GHSA-3f7j-7jwc-fxfj) (HIGH),
[GHSA-7648-jmwf-vw7j](https://github.com/advisories/GHSA-7648-jmwf-vw7j) (moderate) and
[GHSA-4vjg-vx72-qq4g](https://github.com/advisories/GHSA-4vjg-vx72-qq4g) (low). Raised: `systeminformation` 5.33.0 to 5.33.19, within
every parent's caret range, so no override was needed. The lock was updated with npm 11.12.1
(`npx -y npm@11.12.1 update systeminformation --package-lock-only --ignore-scripts --lockfile-version 2`) and only those two lock
entries changed; `npm audit --omit=dev` reports 0 vulnerabilities, and the image builds with its lockfile and `npm ls` guards.

2026-11-21, v1.80.2 to v1.95.0 (Dependabot #224): v1.85.0 moved the publisher image to Node 26 and npm 12, so stage 2 is
`node:26.13.0-alpine3.24` (the publisher's Node 26.13.0 on Alpine 3.24.3) and the manifest takes the publisher's `packageManager`
(`npm@12.2.1`), `engines` (Node 26, npm 12.2.1), `allowScripts` and its own override of `@fastify/busboy` (3.2.4, under
`@fastify/multipart`). The lock was regenerated from the v1.95.0 manifest and lock with npm 12.2.1 (`--lockfile-version 2`, the
publisher's); npm 11.12.1 writes the same bytes. Dropped because the new tree already meets them or they would now go backwards:
the `@fastify/busboy@^3` pin (3.2.3 is below the publisher's 3.2.4), `undici@^7` and `undici@^8` (the root is now undici 8.12.3,
and the 7.x copies under platformatic are 7.30.1, the fixed version), `fast-uri@^3`, `js-yaml@^4` and `protobufjs@^7` (no copy
below the fix), and `dotenv` (the publisher no longer depends on it). `@opentelemetry/propagator-jaeger` is now scoped to
`@<2.9.0`, so the root copy stays at 2.12.0 and only the 2.8.0 copy under `@platformatic/telemetry` is raised. Kept from the earlier
raises: `@opentelemetry/auto-instrumentations-node` `^0.81.0`, `@opentelemetry/instrumentation-http` `^0.222.0` (and the scoped
override under `@platformatic/telemetry`), `fast-xml-parser` `^5.12.0`, `jose` `^6.2.17`, and the `glob`, `minimatch`,
`brace-expansion`, `fast-copy`, `fast-uri@^4`, `ip-address`, `@grpc/grpc-js` and `socks` overrides; `systeminformation` was updated
inside its range to 5.33.23. `pg-boss` stays on commit 89b675b, the one v1.95.0 locks. `npm audit --omit=dev` reports 0
vulnerabilities (the v1.95.0 lock as published: 32, 7 of them high). Storage's schema moves from 73 to 80
(`revoke-extra-lifecycle-postgres-grants`): new lifecycle tables and triggers on `storage.buckets` (a short `EXCLUSIVE` lock on
`buckets`, retried within `lock_timeout` or one minute) and two partial indexes on `storage.objects` built `CONCURRENTLY`; no
migration rewrites `storage.objects`. The image also rewrites the stored hashes of migrations 2 and 62, which upstream edited in
place (`DB_ALLOW_MIGRATION_REFRESH` is left at its default, on).
