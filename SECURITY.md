# Security Policy

## Supported Versions

Facilities run tagged releases (`vMAJOR.MINOR.PATCH`), not `main`: `main` is development and can hold changes that were never
released. Security fixes are provided for:

- the **current minor release line** (for example 0.7.x): the fix ships in a new patch release of that line;
- the **previous minor release line** (for example 0.6.x) for **6 months after the next minor release** (0.7.0) came out: the fix is
  backported and ships as a patch release of that line.

Earlier lines get no fix; move to a supported line. A move between releases is `bash upgrade.sh vX.Y.Z`
([docs/OPERATOR_INSTALL.md](docs/OPERATOR_INSTALL.md), "Rerun and upgrade"); a release on another PostgreSQL major is the separate
"Major PostgreSQL upgrade" procedure there, and a fix in the previous line does not carry that move with it. While the version is
0.x, a minor release can carry operator actions: read its release note.

### How a fix is announced

A security fix is published as a **GitHub release with "Security" in its title** (for example "v0.7.2 Security: sign-in codes in
logs"). The release note names the affected versions, what an attacker could do, the fixed releases and anything the operator has
to do besides `bash upgrade.sh vX.Y.Z`. A published advisory (GitHub Security tab) accompanies it when the issue needs a CVE.
Watch the repository's releases to be told (Watch, Custom, Releases). Fixes land on `main` first and are tagged from there; a backport
is tagged from the branch `release/MAJOR.MINOR` of its line.

This project has one maintainer ([docs/PRODUCTION_DEPENDENCIES.md](docs/PRODUCTION_DEPENDENCIES.md), "Accepted by the owner"):
answers and fixes are best effort and slow down when the maintainer is away.

## Reporting a Vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting for this repository ("Report a vulnerability"
under the Security tab). If that is unavailable, write to the security contact
below.

Security contact: abhinavguru@gmail.com

Include the affected version, reproduction steps, impact, and any suggested
mitigation. Please allow a reasonable amount of time for investigation before
public disclosure.

Do not include production credentials, customer data, database dumps, or logs in
reports.
