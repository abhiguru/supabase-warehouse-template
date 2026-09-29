# Contributing

Thanks for your interest in contributing! Here's how to get started.

## Development Setup

1. Fork and clone the repo
2. Install locked checks with `npm ci`; follow [operator installation](docs/OPERATOR_INSTALL.md) for an isolated Linux x86-64 instance
3. Make your changes
4. Run `./health-check.sh` to verify everything works
5. Run `npm test` and `npm run test:migrations` (disposable database)
6. Submit a PR

Set `WAREHOUSE_STATE_DIR` to the instance's private state path for doctor, start,
stop and Compose commands. The installer generates a unique project name, and
`bash stop.sh` preserves data. Never target a generic database container. Add
new migrations instead of editing applied files. See the [developer
handoff](docs/DEVELOPER_HANDOFF.md).

## Guidelines

- **Keep it simple** - This is a template repo. Avoid over-engineering.
- **Test your changes** - Run the operator installer in a fresh isolated VM before accepting installation changes.
- **Document breaking changes** - Update `.env.example` if you add new env vars.
- **Follow existing patterns** - Look at how existing edge functions and SQL are structured.

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
