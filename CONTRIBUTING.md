# Contributing

Thanks for your interest in contributing! New here? Start with the quickstart
at the top of [README.md](README.md) and the contributor guide in
[docs/DEVELOPER_HANDOFF.md](docs/DEVELOPER_HANDOFF.md) (repository layout, test
commands, migration conventions, CI jobs and the mobile companion pin).

## Development Setup

1. Fork and clone the repo
2. `npm ci`, then `npm test` (no Docker needed) and `bash tests/migrations.sh` (disposable database, needs Docker)
3. For runtime changes, install an isolated Linux x86-64 instance with [operator installation](docs/OPERATOR_INSTALL.md) and run `./health-check.sh` against it
4. Make your changes and add tests next to the existing ones
5. Submit a PR

Set `WAREHOUSE_STATE_DIR` to the instance's private state path for doctor, start,
stop and Compose commands. The installer generates a unique project name, and
`bash stop.sh` preserves data. Never target a generic database container. Add
new migrations instead of editing applied files.

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
the tested combination stays traceable. Do not merge a backend change that
needs a mobile change until the mobile commit exists and the pin points at it.

## Pull Request Process

1. Update `CHANGELOG.md` with your changes
2. Update `.env.example` if you added new environment variables
3. Ensure `./health-check.sh` passes
4. Ensure the database security baseline passes
5. Request review from a maintainer

## Reporting Issues

Use the GitHub issue templates for bug reports and feature requests.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
