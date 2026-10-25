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
`## vX.Y.Z (date)`; `upgrade.sh` prints the sections by that heading), tag `vX.Y.Z` on `main` (`release.yml` validates the tag),
rehearse `bash upgrade.sh vX.Y.Z` from the previous tag on a test install, publish the GitHub release note, and operators run
`bash upgrade.sh vX.Y.Z`. A security fix is tagged first on `main`, then backported to `release/MAJOR.MINOR` of the previous
minor while it is supported, with a release note that has "Security" in its title.

Rules that keep `upgrade.sh` working for the installed base:

- **Every release line keeps `upgrade.sh` and the inherited operator lock in `setup.sh`** (`operator_lock_or_inherited`); `upgrade.sh`
  refuses a release without `upgrade.sh`.
- **A new baseline names what it replaces.** If the migrations are squashed again, the new baseline file and the release note list the
  names of the migration files it replaces. `upgrade.sh` refuses to move a database that recorded a migration the release lacks, and
  points to the Baseline reload; without the list an operator cannot tell a squash from a downgrade. Tell the owner first: a squash
  strands every installed facility behind the manual reload.
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
