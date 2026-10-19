# Remaining production work

The list of what is open before production use. Production use stays gated until these are done. Each line says what closes it. Credentials never belong in this file;
they go in the operator's secret store. Nothing here authorizes production deployment, new billing policy or deletion.

## Needs the operator or the owner

- **Unattended host.** Physical-host startup and shutdown of the VM (on Windows) and a host reboot without a login,
  checked with both doctor modes ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#windows-host-with-linux-vm)).
- **Off-host backups.** An encrypted off-host destination, key custody, schedule, retention and RTO/RPO. Closed only by a
  full host-loss recovery onto a replacement host using the off-host copies alone, with measured recovery time and point.
  An encrypted USB archive has not been through a lost-host restore on real containers.
  Local copies and the in-place restore do not close this.
- **External alerts.** A delivered test message in the facility's Slack channel
  ([MONITORING.md](MONITORING.md)); the checker's one CI pass does not establish delivery. Incident contacts and an
  escalation policy are the operator's.
- **Paired upgrade and rollback.** A backend and app upgrade done together, with the preflight and a rehearsed rollback
  (the in-place restore). Redacted diagnostics for a failed upgrade.
- **Retention policy.** The operator or legal owner approves retention, deletion and legal-hold rules for business
  documents, invoices, PDFs, images and backups. The owner approved the sign-in rows and generated PDFs older than 7 days (2026-10-19);
  the checker's daily pass applies exactly that with `retention:apply` when its timer is installed, and never touches business
  records or photos ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#retention)). Anything beyond that still needs approval.
- **Billing and accounting.** The business owner signs off rates, taxes, rounding and reconciliation examples against
  [INVOICE_RULES.md](INVOICE_RULES.md). Payment requirements and a provider only if payments are in scope.
- **Capacity.** Target host, representative data volume and concurrency, latency and error targets, a soak run and
  recovery objectives, each with measured evidence.
- **Domain and ingress.** The facility's own Cloudflare hostname and tunnel, a cellular check, and the private boundary
  kept (database, CUPS, the Tapo hubs and the sensor bridge never reachable from outside).
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
- **Secrets without a procedure.** `SECRET_KEY_BASE` and `VAULT_ENC_KEY` (pooler profile) have no rotation procedure
  ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#secrets-that-rotate-keys-does-not-change)).
- **Printing functions.** `npm:ipp@2.0.1` is imported on demand; vendor it before printing is enabled
  ([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#edge-function-modules-and-image)).
- **Scheduled image scan.** No workflow runs the scan between releases.
- **CI HTTP 500 investigation.** The fresh loopback config bootstrap answered HTTP 500 on attempt 2 of backend-main CI run
  [35842102994](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/35842102994). It is not closed:
  capture redacted diagnostics, find the cause and fix it or document why it is not a defect. It was a CI observation, not
  a device failure.
