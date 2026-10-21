# Baseline tooling (item 18)

> History: this describes the PostgreSQL 15 to 17 squash and its `@pg17` labels, which stay as they were. The scripts still run, against the pin in `docker/postgres/Dockerfile` (now PostgreSQL 18); `lib.sh` sets `PGDATA` like the stack does.

Replaces the chain of append-only migrations with ONE baseline migration that is an exact squash of the chain, and proves
that it is. The baseline is `migrations/00000000000000_baseline.sql`; these scripts generated it and check it again whenever it is regenerated.
Everything runs in throwaway containers named `slim-tool-*` (no network except the internal one of the postgres:17 run, removed on exit); no stack is touched.

| File | What it does |
| --- | --- |
| `build-chain-db.sh [--image ref] [--root dir] [--empty] [--name n]` | Starts a throwaway database like `tests/migrations.sh` (same image pin and `-c` flags from `docker/docker-compose.override.yml`) and applies the chain with the `scripts/migration-plan.mjs` of the tag `migrations-pre-baseline` (it has the lock 71046 the chain needs). Leaves it running and prints its name. `--empty` applies nothing. |
| `dump-baseline.sh <container> <out.sql> --expect-last N` | `pg_dump --schema-only` of the chain database (owners and ACLs kept; `public` and every other schema the chain created; `auth` for its functions only; no extensions, no image schemas, no ledger), edited by `edit-dump.mjs`, with a `SET LOCAL` header, extensions, the chain's own roles, seed rows (`pg_dump --data-only`, triggers off) and sequence positions. |
| `edit-dump.mjs` | The explicit edits: header and psql meta lines out; `pgrst_ddl_watch` / `pgrst_drop_watch` out; grants and default privileges naming removed roles out; `auth.email/jwt/role/uid` owned by `supabase_admin`; `CREATE SCHEMA public` out; `SET` lines made `SET LOCAL`. Fails if a removed role is still named. |
| `catalog-dump.sql`, `seed-dump.sql` | One line per catalog fact (schemas, relations, columns in order, constraints, indexes, views, functions with full definition, owner, `SECURITY DEFINER`, `proconfig`, ACL, triggers with `tgenabled`, RLS, policies, sequences, default ACLs, comments, publications, event triggers, extensions, roles, memberships, settings) and one hash line per table that has rows. Timestamps and random uuids are masked in the seed hash (a fresh install cannot repeat them). |
| `catalog-diff.mjs <A> <B>` | Runs both dumps in two containers, prints every line that exists on one side only, and checks each against `allowed-differences.txt`. Exit 1 on anything else. |
| `allowed-differences.txt` | The expected differences, each with its reason. |
| `image-as-bootstrap.sql` | Trial helper: takes the old image's default privileges in `public` away before the baseline is applied, as the new bootstrap has none. Used only on the old image; on another image the run fails unless the bootstrap has no default privileges. |
| `verify-baseline.sh` | Builds the chain database and a baseline database (baseline plus any later migrations, plus a probe that checks no setting leaked from the baseline header), runs the diff, applies the baseline plan twice (the second pass must skip it), exits 0 only if nothing differs beyond the allow-list. `npm run baseline:verify`. Not part of `npm test`. |

`tests/baseline-tooling.test.mjs` (in `npm test`) covers the parsing, allow-list (the real `allowed-differences.txt` against lines it must not allow), owner normalisation, dump-edit and masking logic with fixture text, without a database.

## Trial on the current chain

    c=$(scripts/baseline/build-chain-db.sh)                         # prints the container name
    scripts/baseline/dump-baseline.sh "$c" /tmp/baseline-trial.sql --expect-last N   # N = number of the chain's last migration
    scripts/baseline/verify-baseline.sh --baseline /tmp/baseline-trial.sql --chain-container "$c"   # B against the very database it was dumped from, nothing masked
    docker rm -f -v "$c"

`--chain-container` skips the second chain build and compares the seed rows unmasked. Leave it out to build a fresh chain
database instead; then timestamps and random ids of seed rows are masked (the allow-list header and `seed-dump.sql` say which).

## Order at release time

1. Preconditions: the final `main` is rebased on and frozen (no other migration PR is merged while this runs). The chain must end at migration 110 (migrations 100 to 110 are on `main`), including 108 (`pgjwt` goes) and the migration that drops `warehouse_monitoring`; the freeze applies until the baseline is merged. `dump-baseline.sh` also fails unless the chain's extensions are exactly pg_stat_statements, pg_trgm, pgcrypto and uuid-ossp (`--expected-extensions` overrides); `dump-baseline.sh --expect-last N` fails on any gap except the known 050 and unless the chain ends at N.
   Since migration 123 (not yet the end of a chain that was squashed) a later squash ends at N >= 123 and its dump holds none of what 123 dropped (the views `foreign_key_status`, `high_cpu_analysis`, `low_stock_alerts`, `rls_policies_summary`, `security_metrics`, `sensor_health_dashboard`, `stock_summary` and `user_customer_assignments`; 16 empty tables such as `auth_logs`, `jwt_config` and `secrets_vault`; the dead functions). The extension list above is unchanged: `uuid-ossp` stays because three line tables keep `uuid_generate_v1()`. The `@pg17` `viewdef` entry of `allowed-differences.txt` therefore names only `sensor_status`, the one single-table view left.
2. Tag first, on the exact tree that is dumped: `git tag -a migrations-pre-baseline -m "Last tree with the 000..N migration chain"`, then build from that tag, not from the working tree: `d=$(mktemp -d); git archive migrations-pre-baseline migrations | tar -x -C "$d"; c=$(scripts/baseline/build-chain-db.sh --root "$d")`. Push the tag (squash merges: the tagged commit is not on `main`).
3. Dump the baseline into `migrations/`: `scripts/baseline/dump-baseline.sh "$c" migrations/00000000000000_baseline.sql --expect-last N`, then `docker rm -f -v "$c"`. It fails if a removed role (`warehouse_monitoring`, `warehouse_list_refresher`) or an unexpected extension is left at the chain end.
4. `git rm` every file that was in the tag's `migrations/` (except the new baseline). Only files written after the cut, numbered above the chain's last, stay.
5. Verify: `npm run baseline:verify` (chain from the tag plus later migrations versus baseline plus later migrations), and with the new image `npm run baseline:verify -- --bootstrap <a directory that holds a copy of docker/volumes/db/00-bootstrap.sql only>` (the image is the pin of scripts/db-image.sh; the entrypoint runs every `*.sql` of the directory, and roles.sql needs service passwords). Exit 0, and no allow-list entry unused.

## Evidence rule: both runs on the byte-identical file

The baseline counts as verified only when BOTH runs pass on the SAME file, the same chain (root or tag) and the same allow-list:

1. the old image: `verify-baseline.sh --baseline <file> --chain-container <the database it was dumped from>` (seed rows unmasked) and the
   same with a freshly built chain (masked), and
2. postgres:17: `verify-baseline.sh --baseline <file> --chain-root <root> --bootstrap <dir with only 00-bootstrap.sql>` (bootstrap and Storage 1.80.2).

Every run prints the sha256 of the baseline, of the chain's files and of the allow-list; the three values must be equal in all runs. Each
run exits 0 with `unexpected: 0` and no UNUSED entry (an alternative of an entry that matches nothing is unused as well). A postgres:17 run
alone is never evidence: the old-image run is what shows that nothing but the listed properties of the images differs.
The chain side keeps its own frozen image and `-c` flags (`OLD_DB_IMAGE`, `OLD_DB_FLAGS` in lib.sh, equal to those of f1236ae, the last commit
before the switch; a unit test compares them), because the shipped flags no longer preload pg_cron.

## Using the new image (postgres:17)

    verify-baseline.sh --baseline-image <image> --bootstrap <dir with the init scripts> [--storage-image <ref>]

`--bootstrap <dir>` mounts the directory at `/docker-entrypoint-initdb.d` and starts the cluster as production does:
`POSTGRES_USER=supabase_admin`, `POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8`, `pg_isready -U supabase_admin -d postgres`; the old
`pg_cron` preload is dropped from the `-c` flags. Put only the SQL that should run in `<dir>` (the entrypoint runs every `*.sql`, `*.sh`).

Storage 1.80.2 (the pin in `docker/storage/Dockerfile`, with `DB_SUPER_USER=supabase_storage_admin`, `DB_INSTALL_ROLES=false`)
runs against BOTH databases after their migrations, in setup.sh's order (database up, migrations, then Storage builds its
tables), so `storage.*` compares like for like. This is the choice because the facilities run Storage 1.80.2 on the old image
as well; a comparison with Storage on one side only would list every `storage.*` line as a difference. The two databases and
Storage talk over a throwaway `--internal` network created for the run and removed on exit. The chain database stays on
the old image (the chain only applies there).

`allowed-differences.txt` entries tagged `@supabase` apply only when B is the old image, `@pg17` only on postgres:17. An entry
that applies to the run and matches nothing fails it, so a stale entry cannot hide a later difference. The default
privileges of the bootstrap must be empty; the run fails otherwise.
