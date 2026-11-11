# Invoice rules

This describes the database contract in `calculate_invoice_duration`,
`build_invoice_recalculation_rows` and `save_invoice(uuid, jsonb, jsonb[])`. (The one-argument `save_invoice(jsonb)`, `recalculate_invoice_items` and `create_item_storage_price` were removed in migration 123.) The invoice form's preview
(`generate_invoice_data_for_grn`) is built by `build_invoice_form_lines` (migration 102): it follows the same rules and
calls `calculate_invoice_duration` for the duration, but never reads stored invoice lines (`invoice_trl`). The boundary
fixtures in `tests/invoice_duration.sql` assert explicit expected values.

## Duration and monthly charges

The receipt date and the dispatch date are read as calendar dates in India
(`Asia/Kolkata`), whatever time zone the database session uses (migration 41,
`warehouse_security.business_date`; there is no per-facility time-zone setting
yet). A receipt recorded at 02:00 on 1 April in India is stored as 20:30 UTC on
31 March and counts as 1 April. Legacy mode counts
dispatch date minus GRN date; standard mode includes both dates by adding one.
Billable days have a minimum of one. Duration is half-month increments of 15
days, with a minimum of one whole monthly period:

`duration = max(1, ceil(billable_days / 15) / 2)`

Thus 1–30 billable days cost one period, 31–45 cost 1.5, and 46–60 cost two.
This uses fixed day counts, not calendar months. Same-day legacy receipt and
dispatch reports zero elapsed days, one billable day, and one period.

For each monthly dispatch line, storage is quantity × unit price × duration,
rounded to two decimal places. Labour is quantity × labour rate, also rounded
to two places; it is charged once per dispatched unit, not once per period.
The base is storage plus labour. Line tax is base × tax percent / 100, rounded
to two places. Line total is base plus that rounded line tax.

ONE_TIME storage is quantity × unit price, rounded to two places, with zero
labour in the current preview. Rates are selected using item, customer, weight,
GRN date and pricing mode; a stored invoice figure takes precedence
(used by `build_invoice_recalculation_rows`, and reported by `get_grn_item_rates`; never by the preview). Missing prices are reported to the caller.

A rate typed for one GRN only (migration 86, `grn_rates`) sits between the two: a line's rent,
labour and tax come from one source, in this order, never mixed: the stored invoice figure (used by `build_invoice_recalculation_rows`, and reported by
`get_grn_item_rates`; never by the preview), then
the GRN's own rate whose weight band holds the line's weight (the narrowest band wins), then the
item's rate. Once the invoice is saved its figures win; if the invoice is deleted, the GRN's own
rate applies again.

## Charging rule (migration 164)

Each facility has one charging rule (`warehouse_security.charging_rule`, read with `get_charging_rule()` and changed with
`set_charging_rule(p_rule)`, administrators only; each change writes one `audit_log` row). It starts as the rule above:

| Field | Values | Default (the rule above) |
|---|---|---|
| `step_days` | 15 (half a month), 30 (a month), 1 (a day) | 15 |
| `minimum_days` | 0 (one step), 15, 30, 60, 90; never between 0 and the step | 30 |
| `days_counted` | `legacy` (dispatch date minus receipt date), `standard` (plus the day of receipt) | `legacy` |
| `rounding` | `up` (ceiling), `nearest` (50 paise up), `none` (to paise) | `up` |

Duration in months is `max(minimum_days, ceil(billable_days / step_days) × step_days) / 30`, billable days never below one; a month
is 30 days for every step. With the default this is the formula above, value for value (`warehouse_security.charge_duration` uses
that expression for it). With steps of a day the stored duration has two decimals (40 days: 1.33) and the line's storage is worked out
from the days: quantity × rate × days / 30, rounded to paise. `rounding` applies to the header tax and the grand total (where the
ceilings below are); line figures stay rounded to paise. ONE_TIME lines have no duration; only the rounding applies to them.

A new invoice takes the facility's rule when it is saved and stores it (`invoice.charge_step_days`, `charge_minimum_days`,
`total_rounding`, and `duration_mode`); an edit, the header recalculation, the readers and the prints use the stored rule. Every
invoice saved before migration 164 is stored as the default rule. A `duration_mode` sent with a save still wins over `days_counted`.
The invoice form's preview answers the facility's rule as `charging`; the form sends it back as `charging` in the invoice data, and a
save whose rule is no longer the facility's is refused with `CHARGING_CHANGED` (WH409, nothing saved; no `charging` key: no check).

## Invoicing goods as they leave (migration 165)

The charging rule's `invoice_as_goods_leave` (default true since migration 174, which also turned it on where no administrator had
changed it; `set_charging_rule` takes it as an optional key) lets a facility invoice
dispatch lines while other lots of the GRN are still in store. With it off every rule of this page holds as written. With it on:
the D9 stock check (`GRN_HAS_STOCK`) is not made, a GRN may have several live invoices, and a dispatch line is on one live invoice at
most (`A dispatch line is already on another invoice`, WH409). The invoice form offers only the dispatch lines on no live invoice, and
`get_invoiceable_grns` lists the GRNs that have one. A GRN is `invoiced` when it has no stock and every dispatch line is on a live
invoice, `partly_invoiced` when it has a live invoice and is not invoiced, else `not_invoiced` (with the setting off: a live invoice
means invoiced). `goodsreceived.invoiced` is the cache of `invoiced`. A partly invoiced GRN takes new lots; its GRN date is locked; its
own rates stay live until it is invoiced. Each invoice rounds its own header, so a GRN invoiced in parts can total up to the rounding
of each invoice more than one invoice would. Turning the setting off is refused while a GRN with stock has a live invoice
(`PARTIAL_INVOICES_OPEN`, with the count and up to five GRN numbers).
`get_grn_details` answers `can_create_invoice` in its invoice summary (migration 174): the GRN is not deleted, `get_invoiceable_grns` would
list it (both use `warehouse_security.grn_invoiceable`), and it has a dispatch line on no live invoice.

### Before the upgrade to migration 174: the GRNs that will read partly_invoiced

Migration 174 turns the setting on where no administrator ever changed it (an installation upgrading from v0.8.0 or earlier always
qualifies, as the setting does not exist there yet). From then on a GRN with a live invoice reads `partly_invoiced`, and can be invoiced
again for its free lines, when it still has stock in a lot or has a dispatch line (dispatch not deleted) on no live invoice, for example
after an edit removed a line from its invoice. The migration prints only how many GRN flags it changed. To see those GRNs before
upgrading, run this read-only query on the current database (it reads only tables that exist since v0.8.0 and changes nothing):

```bash
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres <<'SQL'
BEGIN TRANSACTION READ ONLY;
SELECT x.gr_no, x.grn_date, x.customer, x.stock_left, x.lines_on_no_live_invoice
  FROM (SELECT g.gr_no, g.date::date AS grn_date, c.name AS customer,
               (SELECT COALESCE(sum(t.stock), 0) FROM public.goodsreceived_trl t WHERE t.gr_id = g.id) AS stock_left,
               (SELECT count(*) FROM public.dispatch_trl dt
                  JOIN public.dispatch d ON d.id = dt.disp_id AND d.deleted_at IS NULL
                 WHERE dt.gr_id = g.id
                   AND NOT EXISTS (SELECT 1 FROM public.invoice_trl it JOIN public.invoice iv ON iv.id = it.invoice_id
                                    WHERE it.disp_trl_id = dt.id AND iv.deleted_at IS NULL AND iv.cancelled_at IS NULL))
                 AS lines_on_no_live_invoice
          FROM public.goodsreceived g
          LEFT JOIN public.customers c ON c.id = g.customer_id
         WHERE g.deleted_at IS NULL
           AND EXISTS (SELECT 1 FROM public.invoice i WHERE i.gr_id = g.id AND i.deleted_at IS NULL AND i.cancelled_at IS NULL)) x
 WHERE x.stock_left > 0 OR x.lines_on_no_live_invoice > 0
 ORDER BY x.gr_no;
ROLLBACK;
SQL
```

Each row is a GRN that will read `partly_invoiced`: `stock_left` bags still in store, `lines_on_no_live_invoice` dispatch lines that a
new invoice may now take. No rows: no GRN changes state. Where an administrator already changed the setting, migration 174 leaves it
as it is and this list does not apply.


(With a charging rule other than the default, "ceiling" below reads as the invoice's `rounding`.) Preview subtotal sums line bases. Header tax is the ceiling of the sum of
**unrounded** line tax bases; grand total is the ceiling of subtotal plus header
tax. Consequently the sum of displayed line totals can differ from the header.

Since migration 24 the header money columns are server-computed for every
save path (`save_invoice(uuid,jsonb,jsonb[])` and
`update_invoice`) and for every role. Client-supplied `labour`, `tax_amount`
and `total` are ignored; `warehouse_security.recalculate_invoice_header`
derives them from the saved lines. Those two RPCs and `delete_invoice` are the
only ways an app session changes an invoice: since migration 42 no role, the
administrator and supervisor included, can insert, update or delete `invoice`
or `invoice_trl` rows with a direct table call, so "for every role" holds for
the whole API and not only for the RPC paths. The header is derived as follows:

- line base = storage + labour exactly as in the preview above, using each
  saved line's `charge`, `labour_rate`, `tax` and `duration`;
- header labour = sum of line labour;
- header tax = ceiling of the sum of unrounded line tax bases;
- header total = ceiling of (sum of line bases + header tax − stored discount).

Line rates remain inputs, within a range (migration 41): `charge` and
`labour_rate` must lie between 0 and 999999 and `tax` between 0 and 100, on all
three save paths. Zero is allowed. A save with a rate outside the range is
refused whole (`Invoice line charge must be between 0 and 999999`, `Invoice line
labour rate must be between 0 and 999999`, `Invoice line tax must be between 0
and 100`).

A storage charge of 0 needs a reason (owner decision of 2026-10-11, migration
48). The reason is sent as `zero_charge_reason` with the other header fields
(in `p_invoice_data` on both three-argument paths; on the one-argument path
there or in its `header` object). The rule is checked on every write, on all
three save paths, after the lines are saved:

- While at least one line of the invoice has a charge of 0, **staff must send
  a reason that is not blank**, also when they edit an invoice whose zero
  charge someone else entered. Administrators and supervisors may leave it
  empty. The refusal is `Enter a reason for the zero charge` (SQLSTATE 22023),
  in the same shape as the discount-reason refusal: `error` and `error_code`
  from the three-argument paths, inside `Database error: … (SQLState: 22023)`
  from the one-argument path.
- The reason is trimmed like the discount reason (white space and invisible
  characters around it are removed; a reason made only of them is blank) and
  cut to 500 characters.
- When no line has a zero charge, the reason is stored as NULL whatever was
  sent.
- A line saved without a charge is billed as 0 and counts as a zero charge.
  (The three-argument save refuses a missing charge before that; the other two
  paths accept it.)
- What counts is the stored charge, which has two decimals. A charge that
  rounds to 0.00 (0.004, -0.004), a zero sent as text (`"0.00"`), a `null`
  charge and a zero sent as `unit_price` (the alias the one-argument save and
  the edit accept when `charge` is missing) are zero charges like `0`. A charge
  of 0.005 is stored as 0.01 and needs no reason. `tests/zero_charge_reason.sql`
  tries each spelling on each path.
- A charge below 0 or above 999999 is still refused, with the range message
  above. A zero **duration** is a different matter and unchanged: the
  three-argument save refuses a line sent with a duration below 0.01
  (`Invalid invoice items`), and every path stores the duration it computes
  from the dates, which is at least one period.

The invoice records `zero_charge_reason`, `zero_charge_set_by` and
`zero_charge_set_at`. Author and time come from the session and are set when
the reason or the set of zero-charge lines changes: a first zero charge, a
reworded reason, a line gaining or losing its zero charge, and the removal of
the last zero charge (which leaves the reason NULL and the person who removed
it as the author). An edit that changes neither keeps them. What an edit does
to a stored reason depends on whether the request has the `zero_charge_reason`
key at all:

| The request | Staff | Administrator, supervisor |
|---|---|---|
| has the key with a reason | stored | stored |
| has the key as `null`, `""` or blank | refused | **the stored reason is cleared** (recorded as a change) |
| does not have the key | refused, also when a reason is stored | **the stored reason is kept** |

A request without the key comes from an older app build or a client that does
not know the field; it says nothing about the reason, so it must not erase
what staff entered. The app sends the key on every save, as `null` when the
field is empty. With no zero-charge line left the reason is NULL in every
case. Every change is appended to
`invoice_zero_charge_history` (invoice, number, customer, old and new reason,
the dispatch lines with a zero charge before and after, the author's profile,
name and role, time), which administrators and supervisors can read, nobody
can change, and which stays when the invoice is deleted. A discount and a zero
charge each need their own reason and have their own history.
`get_invoice_detail`
returns `zero_charge_reason`, `zero_charge_set_by`, `zero_charge_set_by_name`
and `zero_charge_set_at` beside the discount record, to administrators,
supervisors and staff and not to a customer account. The RPC is the only way
an app session reads them: the three columns, like the three discount columns,
are left out of the app role's SELECT on `invoice` (see "Internal columns"
below).

Invoices saved before migration 48 are not checked and not changed. One that
has a zero-charge line and no reason stays readable; when an administrator or
supervisor edits it without touching the zero charge, nothing is recorded; when
staff edit it, the rule applies at that edit, so they must enter a reason,
which is then recorded with their profile.

`discount` remains an input and is preserved as sent (negative values are
surcharges); a discount larger than the invoice amount is rejected. Whenever the
discount changes, the invoice records `discount_reason` (sent as
`discount_reason` in the invoice data), `discount_set_by` and `discount_set_at`
(migration 30). Staff must give a reason for every discount change;
administrators and supervisors may leave it empty. A reason made only of white
space or invisible characters (tab, no-break space, zero-width space) counts as
empty, and surrounding white space is removed. An edit that keeps the discount
keeps its recorded reason and author. The three columns hold the last change
only; every change is also appended to `invoice_discount_history` (invoice,
number, customer, old and new discount, reason, the author's profile, name and
role, time), which administrators and supervisors can read and nobody can
change, and which stays when the invoice is deleted. Both histories store the
author's name and role as they were at the change (`changed_by_name`,
`changed_by_role`; the name since migration 48), and `discount_set_by_name` and
`zero_charge_set_by_name` are that stored name: an account that is renamed, or
deleted by its owner with `delete_user_account` (which turns the profile's
name into "Deleted User"), stays named in the record of what it did. Only a
record without a stored name shows the profile's present name: discount
history rows from before migration 48 were given the name their author's
profile had at the upgrade, and a row whose author had no profile left then
has none. `get_invoice_detail` returns `discount_reason`,
`discount_set_by`, `discount_set_by_name` and `discount_set_at` to
administrators, supervisors and staff; a customer account does not receive
them, from the RPC or from the table ("Internal columns" below).
`get_invoice_data` does not return them yet. The
three-argument path does not range-check the submitted header `total`, `labour`
and `tax_amount` any more (migration 120): they are the phone's estimates, the
server discards them and stores its own figures, so an estimate is never a
reason to refuse a save (an amount that does not fit its stored column is still
refused). The discount keeps its range check. Every save validates line ownership,
GRN/customer consistency and dispatch references and rolls the whole save back
on a missing, duplicate or unrelated line. The mobile client computes the same
numbers for display; the stored values are authoritative.

A dispatch line is invoiced once (migration 41). `save_invoice`
refuses a receipt that is already marked invoiced (`GRN is already invoiced`)
and a line that is on another invoice (`A dispatch line is already on another
invoice`); `update_invoice` refuses to move an invoice onto an invoiced receipt
or to take a line from another invoice. Two saves for the same receipt run one
after the other, so the second is refused even under a new invoice number.
`cancel_invoice` (migration 134; administrators and supervisors; it replaced the removal of an invoice) keeps the invoice, its number and its lines,
marks it cancelled with who, when and why, and frees the receipt, after which it can be invoiced again under a new number; it refuses an invoice that
payments refer to (`INVOICE_HAS_PAYMENTS`). `delete_invoice` (migration 146; administrators and supervisors) removes a live or a cancelled invoice and its lines for good, after the screen's one confirmation: it refuses an invoice that payments refer to ("Cannot delete an invoice that has payments") and, when it is sent the version the screen read, an invoice someone else changed since (`STALE_RECORD`); the audit log keeps the deleted rows. A cancelled invoice can not be edited, is in no total
or count, is listed marked cancelled, and prints with a CANCELLED line. Invoices saved before this rule
are not checked; applying the migration prints a warning when dispatch lines
are already on more than one invoice, and such an invoice can still be edited
with the lines it has.

`get_invoice_items_detailed` computes each line as the header does (one-time
storage without duration or labour; storage and labour rounded separately; line
tax rounded on that base), so its lines differ from the header only by the
header's single tax ceiling. For a cancelled invoice (migration 143) it lists every line, reads the copy the line kept, and answers `details_available`;
a line emptied before the migration has no quantity, so its `tax_amount` and `total_amount` are `null` and it adds nothing to the summary.

A cancelled invoice keeps the details of its lines (migration 143): at cancel, each line copies item name, packaging, weight, rack, package mark,
dispatched quantity, dispatch number and date, GRN number and date into its own `kept_*` columns (same transaction; a refused cancel copies
nothing), and every read of a cancelled invoice (`get_invoice_detail`, `get_invoice_data`, the invoice PDF) shows the copy rather than the
current dispatch line, GRN or item. Deleting the dispatch later still empties `disp_trl_id`, and amounts and totals do not change. A line
emptied before the migration has nothing to copy: it is listed with its amounts and reads "Details not available" (`details_available` false).
The `kept_*` columns are not among the internal columns below: they hold what a line already shows.

## GST documents (migration 173)

Nothing here applies until an administrator saves the facility's GST details (`set_gst_details`): before that every invoice is saved as
`doc_type` `invoice`, with every figure, read, PDF and pre-printed print exactly as described above, and an item's GST treatment is not
used. An invoice saved before the details keeps `invoice` and today's rules for good, edits included.

**Which document** (decided by the server at save and stored on the invoice):

| Facility | Lines | Customer | Document |
|---|---|---|---|
| Not registered | any | any | `bill`: no tax on any line, no GSTIN or SAC |
| Registered | all exempt | any | `bill_of_supply` |
| Registered | all taxable | any | `tax_invoice` |
| Registered | mixed | no valid GSTIN | `invoice_cum_bos` (tax on the taxable lines only) |
| Registered | mixed | valid GSTIN | two documents in one transaction: `tax_invoice` (the number sent, the taxable lines, the discount) and `bill_of_supply` (the next number, the exempt lines), linked by `linked_invoice_id` |

A line is exempt when its item's `gst_treatment` is `exempt_agri` at the save; an exempt line charges no tax whatever its rate's tax %, its
stored tax % is 0, and so is every line of a bill. The invoice form answers `tax_percent` 0 for those lines, so the rate check and the
total check agree with the save. Each document rounds its own header (the charging rule's rounding).

**Saved documents keep what they were made with**: the facility's legal name, address, GSTIN, state and SACs, the customer's GSTIN, state
and address, and each line's treatment. An edit keeps them (the customer's are taken again only when the edit moves the invoice to another
customer); a line the edit adds takes its item's treatment, and the type follows the lines. An edit whose lines would need two documents is
refused (`EDIT_NEEDS_TWO_DOCUMENTS`). The edit form does not offer the lines of the invoice's other document.

**Tax split** (tax invoice and invoice-cum-bill of supply). The customer's state is the first two digits of a valid GSTIN, else
`customers.state_code`; the place of supply is the customer's state, else the facility's. The same state as the facility (or none): CGST
and SGST; another state: IGST. Rounding: the header tax is rounded per the charging rule first; then CGST = round(tax / 2, 2), half away
from zero, and SGST = tax - CGST, so the two add up to the tax exactly (CGST is at most one paisa more). Each line: line tax = round(taxable
value x tax % / 100, 2), split the same way. The lines can add up to less than the header by the header's rounding, as before.

Worked (made-up figures, rule `up`, facility in Gujarat): 10 bags, 12.50 a month, labour 3.00, 5 %, 1.5 months: taxable 217.50, line tax
10.88 (CGST 5.44, SGST 5.44), header tax 11 (CGST 5.50, SGST 5.50), total 229. The same customer with a Maharashtra GSTIN: IGST 11.00. With
rounding `none` a tax of 10.87 splits 5.44 and 5.43.

**Lost answer**: the kept answer of a two-document save is replayed, and `get_submission_result` finds it, only while both documents
exist. The two documents are deleted together or not at all: `delete_invoice` refuses one of a pair (`INVOICE_PAIR`) and
`delete_invoice_pair` deletes both in one transaction (a refusal of either, such as `INVOICE_HAS_PAYMENTS`, deletes neither). Cancelling
one leaves the other as it is.

**Printed documents.** The PDF of a GST document prints the title (TAX INVOICE, BILL OF SUPPLY, INVOICE-CUM-BILL OF SUPPLY, BILL), the
facility's legal name, address, GSTIN and state, the customer's name, address ("Not given" when there is none), GSTIN and state, the place
of supply and "Whether tax is payable on reverse charge: No" (tax documents), each line with its SAC, quantity, months (or One-time), rate,
labour rate, taxable value and CGST/SGST or IGST, the totals by head, "Exempt supply, no GST charged" on a bill of supply, and "For <legal
name>, Authorised signatory". The pre-printed form prints no title, and in its state field the facility's state the invoice was made with (GUJARAT, as before, for an
`invoice` or a bill of an unregistered facility); on a document made with the GST details saved, a GRN reference longer than its 10 characters keeps its end and starts with "..." (an `invoice` cuts its end, as before). It prints half the tax in SGST and CGST for an `invoice` (as always), the stored
CGST and SGST for a tax invoice or invoice-cum-bill of supply, and blank SGST, CGST and tax total for a bill or bill of supply. An IGST
invoice is not printed on the form ("IGST invoices print on plain paper."). On a document made with the GST details saved (any type but
`invoice`), a value longer than its field on the form (an amount, quantity, the state, weight, rate or months, the address, the amount in
words, the customer's GSTIN) is never cut: that invoice is not printed and is named in `skipped` with `reason` `does_not_fit` and the field;
the rest of the range prints. An `invoice` (made before the GST details) prints exactly as before: such values are cut to their fields. When every invoice of the range is skipped (cancelled, IGST
or not fitting) the answer is HTTP 422 with `code` `ALL_SKIPPED`, the message and the `skipped` list.

## Internal columns

Six columns of `invoice` are internal to the warehouse: `discount_reason`,
`discount_set_by`, `discount_set_at`, `zero_charge_reason`,
`zero_charge_set_by` and `zero_charge_set_at`.

Since migration 48 the app role's SELECT on `invoice` is a grant on the other
columns only:

- **No app role reads the six columns from the table**, administrators
  included. Administrators, supervisors and staff get them from
  `get_invoice_detail`; a customer account does not get them at all. The
  service key and the database owner read the table as before.
- **Direct reads are limited to `invoice` and `invoice_trl` (migration 123).** The other invoice tables (`invoice_discount_history`,
  `invoice_zero_charge_history`) have no app-role read; `get_invoice_detail` and the other invoice RPCs are the way to them. The RPCs
  `get_open_invoices_for_customer`, `recalculate_invoice_items` and `save_invoice(jsonb)` no longer exist.
- **A direct read of `invoice` has to name its columns.** `select=*` (also the
  default when `select` is missing, and an embedded `invoice(*)`) is answered
  HTTP 403, `permission denied for table invoice`, for every role. Filtering or
  ordering by one of the six is refused the same way. Every other column is
  read as before, within the row policies. The app reads invoices through RPCs;
  the invoice PDF function names its columns
  (`functions/_shared/document-columns.ts`).
- **A column added to `invoice` later is closed until it is granted.** The
  migration that adds it either runs `GRANT SELECT (column) ON public.invoice
  TO authenticated` or adds the column to the internal list in
  `tests/security_baseline.sql`; that test fails for a column that is neither,
  so a new column is neither exposed nor hidden without a decision.

**A version token (migration 121).** `invoice.updated_at` (`timestamptz NOT NULL DEFAULT now()`, bumped by the trigger
`trigger_invoice_updated_at` on every update) is not granted to the app role either: it is read only through `get_invoice_detail`
(`invoice.updated_at`) and `get_invoice_data` (`data.header.updated_at`), and `update_invoice` answers it after a save. It is not in
`invoiceHeaderColumns` (`functions/_shared/document-columns.ts`). An existing invoice has the migration's time until it is edited.

`invoice_trl`, `invoice_discount_history` and `invoice_zero_charge_history` are
unchanged. `tests/invoice_column_grants.sql` reads the table as a customer
account, as staff, as supervisor, as administrator and with the service key.

## Invoice numbers

An invoice number is unique within its financial year (`inv_fin_year`, the
calendar year in which the year from 1 April to 31 March starts: 2026 for April
2026 to March 2027). The client chooses the number; the server suggests one
(owner decision of 2026-10-11, migration 48):

`get_next_invoice_number(p_fin_year integer DEFAULT NULL)` returns, as plain
digits, the highest number among that year's invoice rows plus 1, and `1` for
a year that has none, so numbering starts again each April. Numbers below 1 in
the data do not count. Without a year (or with NULL)
it uses the financial year of today's date in India (`Asia/Kolkata`), which
turns at 18:30 UTC on 31 March. The app passes the financial year of the
invoice date.

**The facility's rule (migration 127).** The invoice number stays a whole number from 1 to 99999999. The facility's rule (`--invoice-numbering`, or an
administrator in the app) only chooses what is suggested: `year` (the rule above, starting again each April) or `sequence` (the highest number of
every year plus 1, so the count goes on across years; the number is still unique within its year), each with an optional first number. See
[API_CONTRACT.md](API_CONTRACT.md), "Document numbering".

**The year must be the invoice date's (migration 120).** `save_invoice` and `update_invoice` refuse
a year that is not the one of the invoice date with `The invoice date belongs to
financial year <year>, not <sent>` (SQLSTATE `WH422`). `update_invoice` checks
this only when the edit changes the invoice date or the year, so an invoice saved
earlier under another rule can still be edited with its own date and year.
When an edit moves an invoice to another receipt, the old receipt stays marked
invoiced if another live invoice still holds it.

**Range (migration 73).** An invoice number runs from 1 to 99999999
(`INVOICE_NUMBER_MAX`, eight digits so that year-prefixed numbers such as
20260929 stay valid; held by `warehouse_security.invoice_number_max()`).
`save_invoice` and `update_invoice` refuse any other number
with `Invoice number must be between 1 and 99999999` (SQLSTATE `WH422`) before
they write anything; `save_invoice` raises it, `update_invoice`
returns it in their `{"success": false, "error": ...}` answer. An edit that keeps
the invoice's own stored number is accepted, so an invoice saved earlier with a
larger number can still be edited, but not moved to another number outside the
range. The suggestion counts only numbers from 1 to 99999999, so a row above the
ceiling (earlier data, or written with the service key) does not block its year.
When the year's highest number in that range is 99999999, the call is refused with
`No invoice number is left in financial year <year>` (SQLSTATE `WH409`). Before
migration 73 that refusal came at 2147483647 and any typed number was stored, so
one invoice numbered 2147483647 blocked the suggestion for its whole year. The
user can still type a free number in the range. The suggestion is not a
reservation: two people saving at once can get the same number, and the second
save is refused by name (migration 120): `{"success": false, "error_code": "WH409",
"reason": "NUMBER_TAKEN", "number": "<the number>", "error": "Invoice number <n> is
already used in financial year <year>"}` from `save_invoice` (both signatures)
and `update_invoice`, checked before anything is written (an edit that keeps
the invoice's own number is not refused). Before migration 120 the answer was the raw
unique-constraint error (SQLSTATE `23505`, `unique_inv_no_per_year`).

**Which rows count.** Every invoice row of the year, also a soft-deleted one
(`deleted_at` set). The unique constraint `unique_inv_no_per_year` is on
`(inv_fin_year, inv_no)` without a condition, so the number of a soft-deleted
invoice is still reserved and cannot be saved again; a suggestion that ignored
such a row would be refused at every save until someone typed a higher number.
The owner's decision reads "highest number in that year + 1"; counting the
reserved numbers is what makes the suggestion one that can be saved. `delete_invoice`
(migration 146) removes the row, so the number is free again; a cancelled invoice keeps its row and its number until it is deleted, so the
number is not offered again meanwhile. No RPC an app role may call soft-deletes an invoice. Soft-deleted rows come only
from the service key, an operator in the database or earlier data. If such a
row holds 99999999, its year is refused as above.

The lines of a soft-deleted (cancelled) invoice keep their amounts when the
dispatch line they were made from is removed, by a dispatch edit or by deleting
the dispatch: `invoice_trl.disp_trl_id` is then empty (its foreign key is `ON
DELETE SET NULL`, migration 120). Only a soft-deleted invoice can have such a
line: removing or changing a dispatch line of a live invoice stays refused
(`Cannot modify invoiced items`, and deleting a dispatch with a live invoice
line), and the guards count only live invoices.

**A deleted number is free again (owner decision D7, 2026-10-20).** The number of a dispatch that was deleted
(`delete_dispatch_with_order_cleanup`: the row is removed) can be used again; an invoice's row is removed by `delete_invoice` (migration 146; a cancelled invoice keeps its number until then), and `get_next_dispatch_number` /
`get_next_invoice_number` offer it again when it is the highest or the year's next. A saved create answer of a deleted document is
not replayed (migration 120), so entering the same document again creates it. `I1` and `I0001` are different strings: an invoice
or dispatch number is compared as it is stored. (A soft-deleted invoice row (`deleted_at` set), which only the service key or an operator makes, still
reserves its number, as above; a deleted invoice's row is gone and `unique_inv_no_per_year` still refuses a second invoice with a number a live or cancelled invoice holds.)

### Optional prefix (migration 175, WH-139)

An administrator may set a prefix of up to 8 characters (`A-Z`, `0-9`, `/`, `-`; lowercase is turned into capitals) with `set_document_numbering('invoice', {scheme, start, prefix})`; empty (the default) means none. A rule that leaves `prefix` out keeps the stored one. The number stays a whole number: counting, the suggestion and uniqueness per financial year read the digits only. The full number is prefix + digits with no space (at most 8 + 8 = 16 characters), for example `SRT/12`.

- The prefix cannot change while any invoice row (live, cancelled or soft-deleted) exists in the current financial year: `{success:false, error_code:'WH409', reason:'NUMBERING_PREFIX_MID_YEAR'}`. From 1 April until the first invoice of the year it can change.
- Each invoice stores the prefix it was saved with (`invoice.inv_prefix`, set on insert from the prefix the invoice's financial year already holds, else the rule's) and keeps it. All invoices of a financial year carry one prefix: an invoice that `update_invoice` moves to another financial year (a new date) takes that year's prefix, and no other change of the stored prefix is allowed.
- Reads add `inv_prefix` and `invoice_label` (the full number) beside the unchanged `inv_no` / `invoice_number` digits: invoice list items, `get_invoice_detail` and the `get_invoice_data` header (and their `linked_invoice`), the answers of save (also each of `documents`), update, cancel, delete and `delete_invoice_pair` (and their refusals), the `invoice` object of `record_payment`, `update_payment` and `delete_payment`, the print range, and `suggest_document_number('invoice')` (`prefix`). The GRN, dispatch and customer reads and the reports carry `invoice_label` too (`invoice_labels` beside `invoice_numbers`), and every message that names an invoice uses the full number. `get_invoices_list` searches the full number (`SRT/12` and `12` both match, any case).
- Both documents of a two-document GST save carry the same prefix (they are in one financial year).
- The PDF prints the full number; the pre-printed form never cuts it: a number longer than the 12-character field moves the GSTIN right (one space after the number), and an invoice whose GSTIN would then run into the state is printed on plain paper instead (WH-151's fit check).

## Invoices only when the goods are out, and the total the user confirmed (migration 121, owner decisions D9, D18, D23)

- **No invoice while stock remains (D9).** `save_invoice` and `update_invoice` refuse, before writing, a GRN that has
  stock in any of its lots: `GRN_HAS_STOCK` (`gr_no`, `stock`, `lots`; "GRN <no> still has <stock> in stock. Dispatch it first, then
  make the invoice."). The rule is on the GRN the request names, whatever the lines of the invoice are. An invoice that already exists
  on a GRN that now holds stock (for example after a dispatch was deleted) is refused on its next edit too, until the stock is
  dispatched again or the invoice is deleted. An invoiced GRN takes no new lot in `update_grn` (`GRN_INVOICED`).
- **The total the user confirmed (D18).** The app sends `expected_total` (rupees, a number) in the invoice data of
  `save_invoice(uuid,jsonb,jsonb[])` and `update_invoice`. After `recalculate_invoice_header`, when `abs(invoice.total - expected_total)
  > 1.00` the save is rolled back and answered `TOTAL_CHANGED` with `current_total`, `expected_total` and `lines` (`disp_trl_id`,
  `duration`, `no_of_days` as the server just computed them): a date that moved, or another phone's edit, can change the days between
  the preview and the save. No `expected_total` (older apps): no check; their `total` key stays an estimate that the server ignores.
  - **The GRN date and the dispatch date and number are locked once invoiced (D2, D23).** The invoice's days are counted from them, so
  `update_grn` refuses a changed GRN date (`GRN_DATE_LOCKED`) and `update_dispatch_smart` a changed dispatch date or number
  (`DISPATCH_INVOICED`) while a live invoice holds the GRN, or a line of the dispatch. Delete or edit the invoice first.
- **A stale edit is refused (D1).** `update_invoice` compares `expected_updated_at` (the `invoice.updated_at` the form read) and answers
  `STALE_RECORD` for an invoice that changed since.

## Reproducible fixture

Receive 100 bags of 10 kg on 2026-04-01. Dispatch 20 on 2026-05-02, leaving
80 bags / 800 kg; retrying the same idempotency key leaves that stock unchanged.
Dispatch the remaining 80 on the same date. Monthly price is 5 per bag, labour
2 per bag and tax 5%. Legacy duration is 31 days / 1.5 periods.

| Quantity | Storage | Labour | Base | Line tax | Line total |
| --- | --- | --- | --- | --- | --- |
| 20 | 150 | 40 | 190 | 9.50 | 199.50 |
| 80 | 600 | 160 | 760 | 38.00 | 798.00 |

Preview subtotal is **950**, header tax **48**, and grand total **998**.
These numbers belong to the fixture dates above (31 days, 1.5 periods). With the
same prices, receiving and dispatching 100 bags on the same day bills one period:
storage 500 + labour 200 = base 700, tax 35, total **735**.
New previews require a fully dispatched, uninvoiced GRN. The tests also verify
that an invalid dispatch reference rolls back the invoice header.

## Unsupported contract

The `create_item_storage_price` helpers were removed in migration 123 (the app sets rates through the item-rate functions); the
legacy overload accepting `p_unit_price_monthly` and `p_unit_price_one_time` had always failed the required `price_type`
constraint. No combined-rate semantics or additional grants are introduced.
Tax jurisdiction, discount application, payments and production billing approval
remain business-owner decisions.
