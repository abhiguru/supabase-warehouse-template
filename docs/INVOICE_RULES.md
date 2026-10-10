# Demo invoice rules

This describes the existing database contract in `calculate_invoice_duration`,
`build_invoice_recalculation_rows` and `save_invoice(jsonb)`. It is a compatibility
reference for the demo, not a new pricing policy. The API fixtures in
`tests/review-core.mjs` and boundary fixtures in `tests/invoice_duration.sql`
assert explicit expected values.

## Duration and monthly charges

The receipt date and the dispatch date are read as calendar dates in India
(`Asia/Kolkata`), whatever time zone the database session uses (migration 41,
`warehouse_security.business_date`; there is no per-facility time-zone setting
yet). A receipt recorded at 02:00 on 1 April in India is stored as 20:30 UTC on
31 March and counts as 1 April. Before migration 41 the dates were taken in the
session time zone (UTC), which added a day to such a receipt. Legacy mode counts
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
GRN date and pricing mode; existing invoice line rates take precedence when
previewing an existing invoice. Missing prices are reported to the caller.

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
number, customer, old and new discount, reason, profile, role, time), which
administrators and supervisors can read and nobody can change, and which stays
when the invoice is deleted. `get_invoice_detail` returns `discount_reason`,
`discount_set_by`, `discount_set_by_name` and `discount_set_at` to
administrators, supervisors and staff; a customer account does not receive
them. `get_invoice_data` does not return them yet. The
three-argument path still validates that the submitted header numbers are
non-negative before they are discarded. Every save validates line ownership,
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

Use `create_item_storage_price` with `p_price_type` and `p_unit_price`, as the
mobile client does. The legacy overload accepting `p_unit_price_monthly` and
`p_unit_price_one_time` fails the existing required `price_type` constraint and
is unsupported. No combined-rate semantics or additional grants are introduced.
Tax jurisdiction, discount application, payments and production billing approval
remain maintainer/business-owner decisions outside this developer demo.
