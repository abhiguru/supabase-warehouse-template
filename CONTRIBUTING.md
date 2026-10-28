# Contributing

Thanks for your interest in contributing! New here? Start with the quickstart
at the top of [README.md](README.md) and the contributor guide in
[docs/DEVELOPER_HANDOFF.md](docs/DEVELOPER_HANDOFF.md) (repository layout, test
commands, migration conventions, CI jobs and the mobile companion pin).

## Development Setup

1. Fork and clone the repo
2. `npm ci`, then `npm test` (no Docker needed) and `bash tests/migrations.sh` (disposable database, needs Docker); for a change under `docker/sensor-bridge/`, its Python unit tests as well ([DEVELOPER_HANDOFF.md](docs/DEVELOPER_HANDOFF.md), "Running checks")
3. For runtime changes, install an isolated Linux x86-64 instance with [operator installation](docs/OPERATOR_INSTALL.md) and run `./health-check.sh` against it
4. Make your changes and add tests next to the existing ones
5. Submit a PR

Set `WAREHOUSE_STATE_DIR` to the instance's private state path for doctor, start,
stop and Compose commands. The installer generates a unique project name, and
`bash stop.sh` preserves data. Never target a generic database container. Add
new migrations instead of editing applied files; migrations 000 to 110 are one baseline file and the next
migration is number 111 ([docs/DEVELOPER_HANDOFF.md](docs/DEVELOPER_HANDOFF.md#migration-conventions)).

## Guidelines

- **Keep it simple** - This is a template repo. Avoid over-engineering.
- **Test your changes** - Run the operator installer in a fresh isolated VM before accepting installation changes.
- **Document breaking changes** - Update `.env.example` if you add new env vars.
- **Follow existing patterns** - Look at how existing edge functions and SQL are structured.

## Mobile companion pin (`MOBILE_REF`)

The `contract` job in `.github/workflows/ci.yml` checks this backend's API
surface against one exact commit of `abhiguru/rn-warehouse-template`, declared
once as the workflow-level `env: MOBILE_REF`. When a change here alters an
endpoint, response shape or manifest field the app consumes, or when the mobile
branch moves, bump `MOBILE_REF` to the full 40-character SHA of the mobile
commit you tested against (never a branch or tag name), run
`node scripts/check-mobile-contract.mjs <path-to-mobile-checkout>` locally at
that commit, and record the backend/mobile commit pair in the pull request so
the tested combination stays traceable. The same job also runs
`tests/rpc-callers.test.mjs` with `MOBILE_CHECKOUT` set, which compares the app's
RPC names with `tests/rpc_callers_exist.sql`. The live comparison before a release is a step of
[docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md#mobile-contract-before-a-release). Do not merge a backend change that
needs a mobile change until the mobile commit exists and the pin points at it.

## Releases

Operators follow release tags, not `main` ([SECURITY.md](SECURITY.md) has the support window). The flow, step by step in
[docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md): finish `CHANGELOG.md` (the `## Unreleased` section becomes
`## vX.Y.Z (date)`; `upgrade.sh` prints the sections by that heading), tag `vX.Y.Z-rc.N` on `main` (`release.yml` validates the tag,
including what the release must contain for `upgrade.sh`, then builds, scans and publishes the release images and leaves a draft release with their list), rehearse `bash upgrade.sh vX.Y.Z-rc.N` from the previous tag on a test
install, tag the same commit `vX.Y.Z` (so a failed rehearsal never leaves a published tag that has to be moved), publish the GitHub
release note (the draft the workflow made), and operators run `bash upgrade.sh vX.Y.Z`.

### How a security fix ships

The fix lands on `main` first, with its test. Then:

- **The current line** (for example 0.7.x). If `main` holds nothing unreleased beyond the fix, tag the next patch from `main` (0.7.2).
  Otherwise, which is the normal state because a release line is many commits long, the fix ships as the **next minor release from
  `main`** (0.8.0). Tagging a patch from `main` would carry every unreleased feature, migration and operator action in a
  "patch". The exception is a fix that is a change to a definition file only (see "A fix to an RPC body" below): it ships as a patch of
  the current line from a `release/MAJOR.MINOR` branch cut from that line's latest tag when the fix is needed, under the same rules and the
  same CI guard as the previous line's branch. The first line that can take such a fix is the first minor release that contains
  `migrations/definitions/`; earlier lines have none.
- **The previous minor line** (0.6.x, while it is supported). A fix that is **code only** (functions, scripts, images, documents:
  nothing under `migrations/` except existing files of `migrations/definitions/`, see the next item) is cherry-picked onto `release/MAJOR.MINOR` of that line (create it from the line's last tag if it does
  not exist), the `CHANGELOG.md` section of the patch release is written there **and also added to `main`'s `CHANGELOG.md`** (so
  `upgrade.sh` can print it for a facility that moves from the patch to a later minor), and the patch is tagged on that branch. CI runs
  for `release/**` branches like for `main`, and refuses a pull request into one that changes a numbered file of `migrations/` or adds,
  removes or renames a file of `migrations/definitions/`.
- **A fix to an RPC body or to `authorize_rpc` is a change to its definition file, and may be backported, and may ship as a patch of the
  current line.** The bodies of
  `warehouse_security.authorize_rpc` and of the RPCs that were patched in migrations 111 to 126 live in `migrations/definitions/*.sql`
  (one function per file, with its `GRANT`/`REVOKE`). `setup.sh` applies the numbered migrations and then every definition file whose
  checksum differs from the one recorded in `warehouse_migrations.definitions` (each in its own transaction, then a schema reload), so a
  changed file reaches a facility with its next setup, and an unchanged one is skipped. A definition file
  holds only `CREATE OR REPLACE FUNCTION`, `COMMENT ON FUNCTION`, `GRANT`/`REVOKE ... ON FUNCTION` and `ALTER FUNCTION ... SET`/`RESET`,
  all about the one function of its `REVOKE ALL ON FUNCTION` line (no owner, rename, schema or `SECURITY` change);
  `scripts/migration-plan.mjs` refuses the whole plan for anything else. A run that applied a numbered migration applies every definition
  file again, and a file whose function a migration dropped or re-signed stops the plan, naming the file. Change the function in its file (do not write a `DO $patch$`
  migration for it), land the fix on `main` first with its test, and cherry-pick the same change onto the release branch. If the
  change is a fix of what the chain left, add the two `^function\|<schema>\.<name>\(` lines for the function to `tests/definitions-allowed-differences.txt` (`<schema>` is `public` or
  `warehouse_security`; the test that compares the catalog of the numbered files with the catalog after the definitions needs to be told),
  and a `^acl\|function\|` line for a change of its grants (the file says how). A **signature change, a new
  RPC (with its grants), tables, columns, policies and data** stay in numbered migrations; a migration that drops or re-signs a function
  with a definition file changes or removes that file in the same commit (`tests/definitions.test.mjs` refuses a migration that
  replaces, alters, comments or grants on such a function, or drops the signature its file holds). A re-signing migration may `REVOKE` on the new signature, and its `CREATE FUNCTION` must be followed by `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated` in the same migration, because a new function is executable by PUBLIC until then.
- **Backports never carry a migration.** A fix that needs one of those (a column, a policy, a new or re-signed RPC) ships only as the next minor
  from `main`; the previous line gets no patch, and its release note says "upgrade to the next minor release". The reason is how the
  ledger works: a migration file added on `release/0.6` under another name than on `main` is recorded in the facility's ledger, the next
  minor does not contain that name, and `upgrade.sh` and `scripts/migration-plan.mjs` then refuse to move the facility; under the same
  name, `main`'s earlier migrations that the facility does not have yet would be applied after it, in name order, and any of them
  that redefines the same object would silently undo the fix.

The `release/*` branches need a ruleset like `main`'s (owner action, [docs/PRODUCTION_DEPENDENCIES.md](docs/PRODUCTION_DEPENDENCIES.md)).

Rules that keep `upgrade.sh` working for the installed base:

- **Every release line keeps `upgrade.sh` and the inherited operator lock in `setup.sh`** (`operator_lock_or_inherited`); `upgrade.sh`
  refuses a release without `upgrade.sh`, and `scripts/check-release-contents.sh` (run by `release.yml`) fails a tag whose `CHANGELOG.md`
  has no section, or that lacks `upgrade.sh`, `scripts/pg-major.sh`, `scripts/maintenance.sh`, `scripts/upgrade-preflight.sh`, `scripts/upgrade-floor.txt`, the inherited lock
  or the functions recreate in `setup.sh`.
- **What a release needs done after its checkout belongs in its `setup.sh`.** `upgrade.sh` is the OLD release's script, still running
  from memory after the checkout; it does only this: the lock, the backup and its verification, the checkout, `setup.sh` of the new
  release, and the print of the operator actions (before it, the release's own preflight, below; around the checkout, the tags that keep the
  old images for the way back, and the removal of the older tags once setup has succeeded). Everything that depends on the release being moved to (images, migrations, roles,
  configuration, recreating the `functions` container, the local doctor) is a step of that release's `setup.sh`, so a release can change
  how it is moved into without the old script knowing, and a hand-made upgrade gets the same steps. A new post-checkout step goes into
  `setup.sh`, never into `upgrade.sh`. The one thing `upgrade.sh` does around setup is the write freeze (next rule).
- **Keep the write freeze's contract: `scripts/maintenance.sh on|off|status`, the marker `config/maintenance`, and `WAREHOUSE_MAINTENANCE`.**
  The `upgrade.sh` of the release an installation runs now closes the API before its backup with ITS `maintenance.sh on`, and after the
  checkout opens it with the NEW release's `maintenance.sh off` (the script must end with the health check, because `doctor --local` in setup cannot
  probe the API through a closed gateway). While the marker exists, `scripts/compose.sh` hands every Compose command
  `WAREHOUSE_MAINTENANCE=upgrading`, so the setup of the new release recreates the gateways closed; a release that stops doing that would open
  the API half way through the migrations. The gateway image reads `off` or `upgrading` (`docker/nginx/docker-entrypoint.d/17-maintenance-default.envsh`,
  `18-require-env.sh`) and answers 503 `{"code":"upgrading",...}` with `Retry-After: 120` on the three API routes, after the CORS preflight; the app
  may rely on that body. Add what a new service needs to keep it frozen (a second way in to the API is another gateway; `backup.sh` stops them
  all), never a way to bypass it. `/health` and the preflight are not part of the freeze.
- **`upgrade.sh` leaves a record while it runs** (`$WAREHOUSE_STATE_DIR/config/upgrade-in-progress`, read by
  `scripts/upgrade-record.mjs`; doctor, `start.sh` and the status commands report it; the checker raises `upgrade_interrupted` when it exists and
  the lock is free, and does no self-healing meanwhile). Keep its format (`format=1`, `key=value` lines)
  readable by every later release: add fields, never rename or remove one (`maintenance=on` is the latest).
- **Every release carries `scripts/upgrade-preflight.sh` and `scripts/upgrade-floor.txt`, and they are how a release tells the installed
  `upgrade.sh` what it needs.** `upgrade.sh` is the script of the release an installation runs now, so a check that must happen before the
  backup (a higher host minimum, a "before" operator action, the oldest release it accepts an upgrade from) cannot live in it. It reads the
  preflight out of the release it moves to (`git archive` of the target's commit, as `scripts/pg-major.sh` reads `db-image.sh`), together with the
  files named on the preflight's `# needs:` line, runs it from a temporary directory before the backup, in `--dry-run` too, and refuses the
  upgrade when it exits non-zero: so a new minimum or floor takes effect on the move **to** the release that carries it, not one release later (for an
  installation that runs an `upgrade.sh` from the release that introduced this rule or a later one; the move to that first release is still made by the older script).
  The environment it gets is `STATE`, `FROM_SHA`, `FROM_LABEL`, `FROM_TAG`, `TO_SHA`, `TO_LABEL`, `DRY` and `ASSUME_YES` (`yes` when the operator
  gave `--yes`; an older `upgrade.sh` leaves it unset, which means no); keep that contract. The preflight may ask the operator to press Enter after
  the operator actions it prints (a real run, standard input a terminal, `--yes` not given); it never waits otherwise. The floor file is
  `from_floor=` (the oldest release the release can be upgraded from) and `stepping_stone=` (what to upgrade to first), both empty while there is no
  floor. **A compatibility shim names the release that may drop it** (a comment at the shim, for example `configure.mjs`'s old `compose.env`
  lines); the release that removes one sets `from_floor` to the first release that has the code the shim stood in for, so no installation can reach it
  without passing through. That code must rewrite the old form on **every** run of setup, not only under an option (the old gateway-port name
  was renamed only by `--gateway-port` until `scripts/configure.mjs` did it on every run): an installation that has passed through
  the release must no longer hold the old form, or the shim cannot go. A release without a preflight (every tag before this rule) is moved to as before, with one line saying so.
- **The preflight runs from a copy with no `node_modules`.** It runs the target's own `scripts/doctor.mjs --host-preflight` from the temporary
  directory it was extracted into (`# needs: scripts CHANGELOG.md`: the `scripts/` tree and the changelog, nothing else). Everything `doctor.mjs` imports,
  directly or through `configure.mjs`, `watch.mjs`, `lan` and the rest of `scripts/`, must use only `node:` built-ins and local `./` files: one
  npm import would refuse every move to that release. The unit tests use a stand-in doctor and would not notice; the CI upgrade drill from the
  merge base runs the real one.
- **Keep the commands `scripts/pre-images.sh` has** (`name`, `tag`, `restore`, `prune`, each with the release label; `prune LABEL TAG` with the
  recorded tag as its third argument): the `upgrade.sh` of an earlier release tags the running images with the old release's copy before the
  checkout, and calls `prune` of the new release's copy after setup, passing the tag it recorded when it tagged (`pre_images=` in the upgrade
  record), so that a release which names its tags differently cannot remove the set that was just made; the way back that
  `scripts/upgrade-record.mjs` prints calls `restore` from the old release's checkout (the same copy that tagged), then `scripts/build-images.sh --save`
  of that release.
- **`migrations/` only grows at its end: never remove, rename or edit a file, and never add a file that sorts before an existing one.** The
  ledger of an installed facility records file names and checksums, and the plan applies the files it has not recorded in name order: a
  removed or renamed file strands every facility that recorded it, an edited one is refused by its checksum, and a file inserted before the
  last one runs on a fresh install before files that an installed facility ran earlier, so two databases of one release differ. The CI job
  `migration-order` (`scripts/check-migration-order.mjs`, run locally with `node scripts/check-migration-order.mjs origin/main`) fails a
  change that breaks it. Number a new file after the last one (`00000000000128_...` is next).
- **A later squash is a snapshot, not a replacement.** The chain in `migrations/` stays as it is for the installed facilities. If the chain
  grows too long for a fresh install, a snapshot (a schema dump that the baseline verification proves equal to the chain) is kept outside
  `migrations/`, is used only when the ledger is empty, and records the names and checksums of the files it stands for; the first migration
  after it continues the numbers. A facility's ledger then still matches the chain, and `upgrade.sh` never meets a ledger name the release
  lacks. Replacing the chain by a new baseline file strands every installed facility behind the manual reload: tell the owner first.
- **A release changes the PostgreSQL major only on purpose.** `upgrade.sh` refuses it; the release note must say so and link the
  "Major PostgreSQL upgrade" procedure.

## Pull Request Process

1. Update `CHANGELOG.md` with your changes
2. Update `.env.example` if you added new environment variables
3. Ensure `./health-check.sh` passes
4. Ensure the database security baseline passes
5. Request review from a maintainer

## Reporting Issues

Use the GitHub issue templates for bug reports and feature requests.

## License

By contributing, you agree that your contributions will be licensed under the
MIT License, except contributions to `docker/sensor-bridge/`, which are licensed
under GPL-3.0-or-later (`docker/sensor-bridge/LICENSE`) because the bridge uses
python-kasa (GPL-3.0). Do not import the bridge or python-kasa from any other
part of the repository; the backend talks to the bridge over HTTP only.
