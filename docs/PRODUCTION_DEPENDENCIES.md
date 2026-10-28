# Remaining production work

The dated, recurring obligations (renewals, end-of-life dates, the 2029 PostgreSQL move) are in [MAINTENANCE_CALENDAR.md](MAINTENANCE_CALENDAR.md). The list of what is open before production use. Production use stays gated until these are done. Each line says what closes it. Credentials never belong in this file;
they go in the operator's secret store. Nothing here authorizes production deployment, new billing policy or deletion.

## Needs the operator or the owner

- **Unattended host.** Physical-host startup and shutdown of the VM (on Windows) and a host reboot without a login,
  checked with both doctor modes ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#windows-host-with-linux-vm)).
- **Off-host backups.** Key custody, RTO/RPO and the drill. **Decided (owner, 2026-10-25): the USB drive is the only off-host copy;
  an unattended off-site copy is not required.** The drive holds one self-contained archive per backup, **encrypted by default**
  (readable only if the operator types `--no-encrypt`), and keeps the newest three; the recovery point is the last time the drive
  was plugged in, and the days since are lost with the facility (accepted). The backup key lives only on the host's disk, so a drive is
  not enrolled and an encrypted archive is not written until the operator has confirmed a copy kept elsewhere
  (`scripts/backup-key-escrow.sh`); a lost key means the encrypted archives are unrecoverable. CI rebuilds a host on real containers
  from an encrypted USB archive and the key copy alone. Still open, and closed only by the owner: a lost-host restore from the USB copy
  alone on a real replacement host, with the recovery time and point measured, and custody of the key copy (where, and who can
  fetch it).
- **External alerts.** A delivered test message in the facility's Slack channel
  ([MONITORING.md](MONITORING.md)); the checker's one CI pass does not establish delivery. Incident contacts and an
  escalation policy are the operator's.
- **Paired upgrade and rollback.** A backend and app upgrade done together, with the preflight and a rehearsed rollback
  (the in-place restore). Redacted diagnostics for a failed upgrade.
- **Retention policy.** The operator or legal owner approves retention, deletion and legal-hold rules for business
  documents, invoices, PDFs, images and backups. The owner approved the sign-in rows and generated PDFs older than 7 days (2026-10-19);
  the daily pass (`watch.mjs daily`) applies exactly that with `retention:apply` when the daily timer is installed, and never touches business
  records or photos ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#retention)). Anything beyond that still needs approval.
- **Billing and accounting.** The business owner signs off rates, taxes, rounding and reconciliation examples against
  [INVOICE_RULES.md](INVOICE_RULES.md). Payment requirements and a provider only if payments are in scope.
- **Capacity.** Target host, representative data volume and concurrency, latency and error targets, a soak run and
  recovery objectives, each with measured evidence.
- **Domain and ingress.** The facility's own Cloudflare hostname and tunnel, a cellular check, and the private boundary
  kept (database, CUPS, the Tapo hubs and the sensor bridge never reachable from outside).
- **Weekly signals the owner watches (GitHub issues, one each).** None of these blocks a pull request or a tag; each opens or updates
  one issue while it has something to say and closes it when it is clean. An edit notifies nobody, so a finding that is new in an issue
  that is already open (a new advisory, a new base image pin) arrives as one comment that lists only the new lines:
  - "Chrome for Testing pin is more than 14 days behind Stable" (`cft-freshness.yml`): bump `CHS_VERSION`, `CHS_SHA256` and
    puppeteer-core together, or decide in the issue to stay on the pin (docs/CONTAINER_SECURITY.md, "PDF renderer"). A tag is never held for it.
  - "Dependency advisories, <date>" (`dependency-audit.yml`): a HIGH or CRITICAL advisory in the Storage or PDF renderer npm tree with
    no valid exception, an expired exception, or one that expires within 14 days. Raise the dependency, or record a reviewed exception
    of at most 90 days in `docker/npm-audit-exceptions.json` ("Dependency advisory exceptions" in docs/CONTAINER_SECURITY.md).
  - "Base image pins need attention" (`base-images.yml`): a pinned base image variant that the official-images library no longer
    publishes (node's `alpine3.23` for Storage is the first, around the end of 2026; nginx 1.30, which leaves the library when 1.32
    ships; python's `slim-bookworm`), or a pinned tag not pushed for 120 days. Move the pin, rebuild and rescan.
  - Not weekly, but the same kind of signal: the image-scan exceptions in `docker/image-exceptions.json` expire on 2027-01-15 (see "Accepted by the owner").
- **Owner action: the `keep-alive` workflow and the Actions tab.** Once `.github/workflows/keep-alive.yml` is on `main`, run it by hand
  (Actions, Keep scheduled workflows enabled, Run workflow) and check both steps: the branch `keep-alive` exists (the workflow pushes there
  and not to `main`, which is protected by required status checks, so no setting changes), and "Enable the scheduled workflows" is
  green for `ci.yml`, `cft-freshness.yml`, `dependency-audit.yml` and `base-images.yml` (it calls the documented `PUT /repos/{owner}/{repo}/actions/workflows/{workflow_id}/enable`
  with the workflow's own token, which has `actions: write` in this workflow only). If a push is refused the run fails with this fix: no
  ruleset may cover `keep-alive`, or add the GitHub Actions app as its bypass actor. **Unverified: GitHub does not define "repository
  activity", so it is not known whether a push made with the workflow's own token resets the 60-day idle clock, nor whether the enable call
  revives a schedule GitHub has already disabled.** Until that is known, after any absence longer than about 45 days open the repository's
  Actions tab, look for "This scheduled workflow is disabled because there hasn't been activity in this repository for at least 60 days"
  on CI, Chrome for Testing freshness, dependency advisories and base images, and enable them there.
- **Owner action: cut `v0.7.0`.** Operators and the CI upgrade drill start from release tags, and none exists on the PostgreSQL 18 line
  (the newest, `v0.6.1`, is from before the PostgreSQL 18 move). When the production-readiness work has merged: finish the `CHANGELOG.md` section, tag
  `v0.7.0-rc.1`, rehearse, tag the same commit `v0.7.0`, publish the release note ([RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)). Until
  a tag exists the drill starts from the merge base with `main`, and a facility that runs a commit of `main` (Dev included) cannot use
  `upgrade.sh` to move to `v0.7.0` when it is already past it: it is refused with "already past".
- **Owner action: protect `release/*` like `main`.** A ruleset (Settings, Rules) for the branches `release/*` with the required status
  checks of `main`. `ci.yml` runs for them, and a pull request into one that changes `migrations/` fails (backports never carry a
  migration, [CONTRIBUTING.md](../CONTRIBUTING.md)). No release branch exists yet; set the ruleset before the first.
- **SMS provider.** Handset receipt, administrator login and a live provider-outage check on the facility's own MSG91
  account, and acceptance of the SMS account lifecycle (pending customer, approval, login after approval).

## Needs hardware or a device

- **Printing.** Authorized, durable jobs on the Epson LQ-1310 continuous forms (alignment, faults, Linux USB and the
  Windows shared-queue path). Until then the print routes answer 503 by design ([PRINTING.md](PRINTING.md)).
- **Sensors.** Both hubs and every T310 seen by `--once --dump`, an hour of change and heartbeat rows, a staff phone
  showing a new reading within 60 seconds, then `set-capability sensors on` ([SENSORS.md](SENSORS.md)).
- **Business flow.** On an operator installation: editable identity, branding, customer and pricing configuration, then
  approval, receipt, dispatch, invoice, orders, queue and cart, checked against [INVOICE_RULES.md](INVOICE_RULES.md).
- **Phones.** Native end-to-end acceptance on Android and iPhone, server selection by QR, replacement-instance
  isolation, authenticated restoration, two-server isolation, and the timed re-reads of order
  (15 s) and sensor (60 s) screens, which have no device acceptance yet. Release signing, store distribution and enabled
  telemetry delivery belong to the app's own handoff.

## Needs code or build work

- **Image scan.** `npm run scan:images` ends with every HIGH/CRITICAL row fixed or covered by a valid, unexpired entry of
  `docker/image-exceptions.json`; the PostgREST image still has no package inventory
  ([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#exception-ledger-and-the-image-scan)). Findings are not waived to make a
  scan green.
  **Dated (2026-10-26): the six scan exceptions in `docker/image-exceptions.json` all expire on 2027-01-15.** From that day the
  manual scan and the release checklist fail until the owner (`abhiguru`) has reviewed each entry again and renewed it (a new
  `reviewed` date, `expires` at most 90 days later, the reason updated with that day's scan counts) or removed it. CI does not
  notice: it checks the ledger at the date of the newest review, not at today's date (`tests/image-scan.test.mjs`). Put the
  renewal in the owner's calendar for early January 2027.
- **Secrets without a procedure.** `SECRET_KEY_BASE` and `VAULT_ENC_KEY` (generated only by `pooler.sh on`) have no rotation procedure
  ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#secrets-that-rotate-keys-does-not-change)).
- **Printing functions.** `npm:ipp@2.0.1` is imported on demand; vendor it before printing is enabled
  ([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#edge-function-modules-and-image)).
- **Scheduled image scan.** No workflow runs the scan between releases.
- **Telling facilities about releases (backlog, owner decision 2026-10-26: not now).** Operators learn of a release only from the GitHub
  release notes (Watch, Custom, Releases), and a facility whose operator has no GitHub account hears nothing. A daily-pass step could
  run `git ls-remote --tags origin`, post once to the facility's Slack ("vX.Y.Z is available; this facility runs vA.B.C") and show the
  same line in `doctor`; mark a security release (the public releases API returns the titles that carry "Security") and say
  "your line 0.6 is out of support since <date>". Not built.
- **`upgrade.sh --rollback` (backlog, owner decision 2026-10-26: not now).** A failed `upgrade.sh` prints the complete way back and
  `node scripts/upgrade-record.mjs rollback` prints it again from the record; a single command that runs those steps is not built.
- **CI HTTP 500 investigation.** The fresh loopback config bootstrap answered HTTP 500 on attempt 2 of backend-main CI run
  [35842102994](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/35842102994). It is not closed:
  capture redacted diagnostics, find the cause and fix it or document why it is not a defect. It was a CI observation, not
  a device failure.

## Accepted by the owner

- **One maintainer (owner, 2026-10-25).** One CODEOWNER can merge, tag and publish, and a second maintainer is not planned. The
  risk is accepted. A running facility does not depend on GitHub; what waits while the owner is away is everything that moves a
  facility to a newer release:
  - Dependabot pull requests (base images, npm, Actions) stay open, so no image or package moves.
  - Security fixes: no fix, no release tag and no release note with "Security" in its title ([SECURITY.md](../SECURITY.md)), no
    backport to the previous minor. Operators follow tags, so a fix that reached `main` does not reach them until a tag is cut.
  - Release tags and release notes, and with them every `bash upgrade.sh vX.Y.Z` the operators would run.
  - Image-scan exception renewals: the six entries of `docker/image-exceptions.json` expire on **2027-01-15**. After that date
    `npm run scan:images` and the release checklist fail until the owner reviews and renews them (CI does not run the scan). End-of-life
    dates behind it: Node 22 on the host 2027-04-30, Node 24 in the storage and PDF images 2028-04-30, Debian 12 for the
    functions image 2028-06-30. The rest of the end-of-life dates, with the forecast ones marked as such (Ubuntu 22.04 under CUPS
    2027-04 to 05, Alpine 3.23 2027-11-01, Python 3.15 for the sensor bridge about 2031-10, the database's move off Debian 13, with the PostgreSQL
    major move, in 2029 H1, PostgreSQL 18 2030-11), are in [MAINTENANCE_CALENDAR.md](MAINTENANCE_CALENDAR.md), which lists every dated obligation
    and where it is checked.
  - Mitigation, **unverified**: `.github/workflows/keep-alive.yml` commits a timestamp once a month to the orphan branch `keep-alive`
    and calls the documented endpoint that enables the weekly CI run and the weekly Chrome for Testing, dependency advisory and
    base image checks, to keep GitHub from disabling them after 60 days without repository activity. GitHub does not say what counts as activity, so whether this works is not
    known; the owner looks at the Actions tab after any long absence (see the owner action above). It does not merge, release or renew
    anything: it only keeps the checks running and the issue they open visible.
- **USB-only off-host copy (owner, 2026-10-25).** See "Off-host backups" above: the destination is the encrypted USB drive
  (encrypted by default, the newest three archives kept, the key copy confirmed before a drive is enrolled); the stale-copy risk
  (a facility lost between plug-ins loses the days since) is accepted, and so is the loss of every encrypted archive if the host and
  the key copy are both lost.
