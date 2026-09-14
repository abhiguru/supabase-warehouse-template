# Contributing

Thanks for your interest in contributing! Here's how to get started.

## Development Setup

1. Fork and clone the repo
2. Install locked checks with `npm ci`, then run `bash setup.sh --demo` to bootstrap locally
3. Make your changes
4. Run `./health-check.sh` to verify everything works
5. Run `npm test`, `npm run test:migrations` (disposable database), and `npm run test:api` (fictional demo fixtures)
6. Submit a PR

Use `npm run doctor` for read-only diagnostics. Stop with `bash stop.sh`; this preserves data. For multiple checkouts, set a unique `WAREHOUSE_PROJECT_NAME=warehouse-your-name` in every command and choose unused loopback ports. Never target a generic database container. Use `bash scripts/compose.sh exec -T db ...` only for this checkout; it checks ownership. Add new migrations instead of editing applied files. See [developer handoff](docs/DEVELOPER_HANDOFF.md).

## Guidelines

- **Keep it simple** - This is a template repo. Avoid over-engineering.
- **Test your changes** - Run `bash setup.sh --demo` in an isolated checkout before submitting.
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
