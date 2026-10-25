# Support

Use GitHub Discussions for setup and usage questions and GitHub Issues for
reproducible bugs and feature requests. Report security vulnerabilities using
the private process in [SECURITY.md](SECURITY.md).

This community project is provided without an SLA or warranty.

Support covers the supported release lines of [SECURITY.md](SECURITY.md) (the current and the previous minor). Before you write, say
which release you run (`git describe --tags` in the checkout) and attach the output of `node scripts/doctor.mjs`. Facilities move
between releases with `bash upgrade.sh vX.Y.Z` ([docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md), "Rerun and upgrade");
`$WAREHOUSE_STATE_DIR/config/upgrades.log` shows what ran and how it ended. The project has one maintainer: expect best effort, not a
response time.
