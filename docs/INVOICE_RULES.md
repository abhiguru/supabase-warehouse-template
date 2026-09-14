# Demo invoice rules

This describes the existing database contract in `calculate_invoice_duration`,
`build_invoice_recalculation_rows` and `save_invoice(jsonb)`. It is a compatibility
reference for the demo, not a new pricing policy. The API fixtures in
`tests/review-core.mjs` and boundary fixtures in `tests/invoice_duration.sql`
assert explicit expected values.

## Duration and monthly charges

Dates are converted to database dates before calculation. Legacy mode counts
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

`save_invoice(jsonb)` accepts client-supplied header totals: total and tax are
each rounded upward to whole units, while discount is preserved. It validates
line ownership, GRN/customer consistency and dispatch references and calculates
line duration. It does **not** recompute all financial values or apply a new
discount formula. For example, supplied total 116.01, tax 5.01 and discount 2.5
are stored as 117, 6 and 2.5. Treat server-authoritative financial recalculation
as a separate contract change requiring a specified business policy.

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
New previews require a fully dispatched, uninvoiced GRN. The tests also verify
that an invalid dispatch reference rolls back the invoice header.

## Unsupported contract

Use `create_item_storage_price` with `p_price_type` and `p_unit_price`, as the
mobile client does. The legacy overload accepting `p_unit_price_monthly` and
`p_unit_price_one_time` fails the existing required `price_type` constraint and
is unsupported. No combined-rate semantics or additional grants are introduced.
Tax jurisdiction, discount application, payments and production billing approval
remain maintainer/business-owner decisions outside this developer demo.
