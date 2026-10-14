# Operator printing integration

Printing is not ready to enable on the operator branch. The public discovery
capability defaults to `false`, and the main Edge router rejects print routes.
The authoritative [operator ledger](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work)
tracks the remaining software and physical acceptance. Starting CUPS or changing
a capability flag does not complete that work.

The repository retains the LQ-1310 ESC/P layouts and CUPS image. The isolated
`npm run test:cups` check covers container startup, administrator credential
requirements and spool preservation; it does not submit paper jobs or validate
printer transport. CUPS has no published host port. Its spool is a project-scoped
Docker volume, so independent instances cannot share queued documents merely
because they use the same source checkout. The core database/document backup
does not yet include that optional volume.

The intended pilot transports are Linux direct USB through CUPS, and a private
Windows USB printer queue shared to the Linux VM through Samba. Windows transport
requires implementation and physical verification before it is supported.

Before enabling printing, complete queue configuration, operator document
branding and bounded form alignment, authorized submission, durable job identity
and duplicate protection. Expose queued, failed, completed-as-reported and
unknown outcomes accurately. A disappeared job is not proof of physical output;
never automatically resubmit an uncertain job.

Then record physical LQ-1310 continuous-form tests for GRN, dispatch and invoice,
multiple slips/pages, disconnects, paper outages and unattended reboot. Keep
CUPS administration and backend service-role credentials private to the server.
The mobile app must submit under its own authorized user session.

## Activation acceptance

The five printing routes still answer 503 (`functions/main/index.ts`). The
review of 2026-10-13 (PRINT1-5) found five faults in the dormant code; these are
now enforced in code and covered by tests that run without a printer:

- **Invoice pages by printed rows.** A page holds at most 20 item rows, the GRN
  group header rows included; a group that goes on to the next page repeats its
  header there, marked `contd.`, and a header never ends a page on its own
  (`functions/_shared/invoice-print-layout.ts`, `tests/print-paginator.test.mjs`).
- **Server line amounts.** Each invoice line's storage amount is the one
  `get_invoice_range_for_print` returns (`storage_amount`, migration 72, with
  `pricing_mode` and `labour_amount`): a ONE_TIME line is charged once, whatever
  its duration. The print never computes an amount and stops on a line without
  one (`functions/_shared/invoice-print-amounts.ts`,
  `tests/print_invoice_range.sql`, `tests/print-amounts.test.mjs`).
- **Validated IPP replies.** A print is submitted only when the reply has a
  successful status and a positive integer job id; otherwise the job is recorded
  as `unknown` and the caller gets 502 "The printer did not confirm the job".
  A printer status needs the attribute block, a known state and the
  accepting-jobs flag, and only an idle printer is online
  (`functions/_shared/ipp-validate.ts`, `tests/ipp-validation.test.mjs`).
- **`unknown` outcomes.** The status monitor records completed, cancelled or
  failed only from a final state CUPS reports. A job CUPS no longer lists, or one
  still running after 35 s, is `unknown` with a note and no completion time
  (`print_jobs.status` accepts `unknown` since migration 72). The Print-Job
  submission of the three preprinted routes is given up after 8 s (no answer
  is an unconfirmed job, recorded as `unknown`); the submission plus the
  monitor's worst case is 52 s, under the router's 60 s worker lifetime
  (`functions/_shared/print-monitor-rule.ts`, `tests/print-monitor.test.mjs`).
- **Indian financial year.** An invoice print without `inv_fin_year` prints the
  current Indian financial year (1 April to 31 March, Asia/Kolkata); a given year
  must be an integer from 2000 to 9999, else 400.

Still physical acceptance, not shown by any test here:

- one invoice with one large group and one with many small groups printed on the
  LQ-1310 continuous form, the totals and the next invoice on their printed
  fields;
- a ONE_TIME invoice with a duration above one printed, its line and page
  amounts equal to the saved invoice;
- the shape of npm:ipp's decoded replies (status code, job and printer attribute
  groups) on a real CUPS, for Print-Job, Get-Job-Attributes and
  Get-Printer-Attributes;
- a procedure for staff to check `unknown` jobs at the printer before anyone
  prints again, and the submission itself finishing early enough in the worker
  for the monitor's 54 s.
