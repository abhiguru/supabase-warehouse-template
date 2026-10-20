# Invoice rules

This describes the database contract in `calculate_invoice_duration`,
`build_invoice_recalculation_rows` and `save_invoice(jsonb)`. The invoice form's preview
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
(used by `build_invoice_recalculation_rows` / `recalculate_invoice_items`, and reported by `get_grn_item_rates`; never by the preview). Missing prices are reported to the caller.

A rate typed for one GRN only (migration 86, `grn_rates`) sits between the two: a line's rent,
labour and tax come from one source, in this order, never mixed: the stored invoice figure (used by `build_invoice_recalculation_rows` /
`recalculate_invoice_items`, and reported by `get_grn_item_rates`; never by the preview), then
the GRN's own rate whose weight band holds the line's weight (the narrowest band wins), then the
item's rate. Once the invoice is saved its figures win; if the invoice is deleted, the GRN's own
rate applies again.

## Header rounding and save contract

Preview subtotal sums line bases. Header tax is the ceiling of the sum of
**unrounded** line tax bases; grand total is the ceiling of subtotal plus header
tax. Consequently the sum of displayed line totals can differ from the header.

Since migration 24 the header money columns are server-computed for every
save path (`save_invoice(jsonb)`, `save_invoice(uuid,jsonb,jsonb[])` and
`update_invoice`) and for every role. Client-supplied `labour`, `tax_amount`
and `total` are ignored; `warehouse_security.recalculate_invoice_header`
derives them from the saved lines. Those three RPCs and `delete_invoice` are the
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

A dispatch line is invoiced once (migration 41). Both `save_invoice` signatures
refuse a receipt that is already marked invoiced (`GRN is already invoiced`)
and a line that is on another invoice (`A dispatch line is already on another
invoice`); `update_invoice` refuses to move an invoice onto an invoiced receipt
or to take a line from another invoice. Two saves for the same receipt run one
after the other, so the second is refused even under a new invoice number.
`delete_invoice` removes the invoice and its lines and frees the receipt, after
which it can be invoiced again; it refuses an invoice that payments refer to
(`Cannot delete an invoice that has payments`). Invoices saved before this rule
are not checked; applying the migration prints a warning when dispatch lines
are already on more than one invoice, and such an invoice can still be edited
with the lines it has.

`get_invoice_items_detailed` computes each line as the header does (one-time
storage without duration or labour; storage and labour rounded separately; line
tax rounded on that base), so its lines differ from the header only by the
header's single tax ceiling.

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

**The year must be the invoice date's (migration 120).** `save_invoice(jsonb)`,
when it is sent no year, takes the financial year of the invoice date in India
(it took today's), and both `save_invoice` signatures and `update_invoice` refuse
a year that is not the one of the invoice date with `The invoice date belongs to
financial year <year>, not <sent>` (SQLSTATE `WH422`). `update_invoice` checks
this only when the edit changes the invoice date or the year, so an invoice saved
earlier under another rule can still be edited with its own date and year.
When an edit moves an invoice to another receipt, the old receipt stays marked
invoiced if another live invoice still holds it.

**Range (migration 73).** An invoice number runs from 1 to 99999999
(`INVOICE_NUMBER_MAX`, eight digits so that year-prefixed numbers such as
20260929 stay valid; held by `warehouse_security.invoice_number_max()`).
`save_invoice` (both signatures) and `update_invoice` refuse any other number
with `Invoice number must be between 1 and 99999999` (SQLSTATE `WH422`) before
they write anything; the three-argument `save_invoice` raises it, the other two
return it in their `{"success": false, "error": ...}` answer. An edit that keeps
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
reserved numbers is what makes the suggestion one that can be saved. No RPC an
app role may call soft-deletes an invoice: `delete_invoice` removes the row,
and the number of a removed invoice is free again, so deleting the year's
last invoice makes its number the next suggestion. Soft-deleted rows come only
from the service key, an operator in the database or earlier data. If such a
row holds 99999999, its year is refused as above.

The lines of a soft-deleted (cancelled) invoice keep their amounts when the
dispatch line they were made from is removed, by a dispatch edit or by deleting
the dispatch: `invoice_trl.disp_trl_id` is then empty (its foreign key is `ON
DELETE SET NULL`, migration 120). Only a soft-deleted invoice can have such a
line: removing or changing a dispatch line of a live invoice stays refused
(`Cannot modify invoiced items`, and deleting a dispatch with a live invoice
line), and the guards count only live invoices.

**A deleted number is free again (owner decision D7, 2026-10-20).** The number of a dispatch or an invoice that was deleted
(`delete_dispatch_with_order_cleanup`, `delete_invoice`: the row is removed) can be used again, and `get_next_dispatch_number` /
`get_next_invoice_number` offer it again when it is the highest or the year's next. A saved create answer of a deleted document is
not replayed (migration 120), so entering the same document again creates it. `I1` and `I0001` are different strings: an invoice
or dispatch number is compared as it is stored. (A soft-deleted invoice row, which only the service key or an operator makes, still
reserves its number, as above.)

## Invoices only when the goods are out, and the total the user confirmed (migration 121, owner decisions D9, D18, D23)

- **No invoice while stock remains (D9).** `save_invoice` (both signatures) and `update_invoice` refuse, before writing, a GRN that has
  stock in any of its lots: `GRN_HAS_STOCK` (`gr_no`, `stock`, `lots`; "GRN <no> still has <stock> in stock. Dispatch it first, then
  make the invoice."). The rule is on the GRN the request names, whatever the lines of the invoice are. An invoice that already exists
  on a GRN that now holds stock (for example after a dispatch was deleted) is refused on its next edit too, until the stock is
  dispatched again or the invoice is deleted. An invoiced GRN takes no new lot in `update_grn` (`GRN_INVOICED`).
- **The total the user confirmed (D18).** The app sends `expected_total` (rupees, a number) in the invoice data of
  `save_invoice(uuid,jsonb,jsonb[])` and `update_invoice`. After `recalculate_invoice_header`, when `abs(invoice.total - expected_total)
  > 1.00` the save is rolled back and answered `TOTAL_CHANGED` with `current_total`, `expected_total` and `lines` (`disp_trl_id`,
  `duration`, `no_of_days` as the server just computed them): a date that moved, or another phone's edit, can change the days between
  the preview and the save. No `expected_total` (older apps): no check; their `total` key stays an estimate that the server ignores.
  `save_invoice(jsonb)` is not checked.
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

`create_item_storage_price` takes `p_price_type` and `p_unit_price`. The mobile
client does not call it (it sets rates through the item-rate functions). The
legacy overload accepting `p_unit_price_monthly` and `p_unit_price_one_time`
always failed the required `price_type` constraint and has been dropped. No
combined-rate semantics or additional grants are introduced.
Tax jurisdiction, discount application, payments and production billing approval
remain business-owner decisions.
