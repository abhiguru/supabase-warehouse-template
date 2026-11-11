-- The facility's charging rule (migration 164, WH-137): how storage time is counted and how invoice totals are rounded.
-- Runs only in migrations.sh's disposable, network-disabled database. Fictional figures.
--
-- Money first: the default rule bills exactly as every invoice did before the migration (the pinned figures below are the ones the migration
-- header works out from calculate_invoice_duration and recalculate_invoice_header), and every other rule gives the figures the header lists.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.cr_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'charging rule: %', label; END IF; END $$;
-- True when the statement raises an error whose text matches the pattern.
CREATE FUNCTION pg_temp.cr_raises(statement text, pattern text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE statement; EXCEPTION WHEN OTHERS THEN RETURN SQLERRM LIKE pattern; END;
  RETURN false;
END $$;
-- The months charged for a receipt on 2026-04-01 and a dispatch n days later, under a rule.
CREATE FUNCTION pg_temp.cr_months(n integer, step integer DEFAULT 15, minimum integer DEFAULT 30, mode text DEFAULT 'legacy') RETURNS numeric LANGUAGE sql AS $$
  SELECT duration FROM warehouse_security.charge_duration(DATE '2026-04-01', DATE '2026-04-01' + n, mode, step, minimum) $$;

-- 1. The defaults: a facility that never changed anything bills as before.
SELECT pg_temp.cr_assert((SELECT bool_and(CASE c.column_name
    WHEN 'step_days' THEN c.column_default = '15' WHEN 'minimum_days' THEN c.column_default = '30'
    WHEN 'days_counted' THEN c.column_default LIKE '''legacy''%' WHEN 'rounding' THEN c.column_default LIKE '''up''%' END)
  FROM information_schema.columns c WHERE c.table_schema = 'warehouse_security' AND c.table_name = 'charging_rule'
   AND c.column_name IN ('step_days', 'minimum_days', 'days_counted', 'rounding')),
 'the rule starts as 15-day steps, a 30-day minimum, days counted the legacy way, totals rounded up');
SELECT pg_temp.cr_assert((SELECT bool_and(CASE c.column_name
    WHEN 'charge_step_days' THEN c.column_default = '15' WHEN 'charge_minimum_days' THEN c.column_default = '30'
    WHEN 'total_rounding' THEN c.column_default LIKE '''up''%' END)
  FROM information_schema.columns c WHERE c.table_schema = 'public' AND c.table_name = 'invoice'
   AND c.column_name IN ('charge_step_days', 'charge_minimum_days', 'total_rounding')),
 'an invoice made before the migration is stored with the rule of today');
SELECT pg_temp.cr_assert((SELECT count(*) = 1 FROM warehouse_security.charging_rule), 'one rule row');
SELECT pg_temp.cr_assert(NOT has_table_privilege('authenticated', 'warehouse_security.charging_rule', 'SELECT')
  AND NOT has_table_privilege('anon', 'warehouse_security.charging_rule', 'SELECT'), 'no app role reads the table: get_charging_rule does');

-- 2. The months charged under today's rule, by billable days (the header's table).
SELECT pg_temp.cr_assert(pg_temp.cr_months(1) = 1 AND pg_temp.cr_months(15) = 1 AND pg_temp.cr_months(16) = 1 AND pg_temp.cr_months(30) = 1
  AND pg_temp.cr_months(31) = 1.5 AND pg_temp.cr_months(45) = 1.5 AND pg_temp.cr_months(46) = 2 AND pg_temp.cr_months(61) = 2.5,
 'days 1, 15, 16, 30 charge 1 month; 31 and 45 charge 1.5; 46 charges 2; 61 charges 2.5');
SELECT pg_temp.cr_assert(pg_temp.cr_months(0) = 1, 'a same-day dispatch is one billable day: 1 month');
-- Days counted: legacy 2026-04-01 to 2026-05-01 is 30 days (1 month); standard adds the day of receipt, 31 days (1.5).
SELECT pg_temp.cr_assert((SELECT no_of_days = 30 AND duration = 1 FROM warehouse_security.charge_duration(DATE '2026-04-01', DATE '2026-05-01', 'legacy', 15, 30))
  AND (SELECT no_of_days = 31 AND duration = 1.5 FROM warehouse_security.charge_duration(DATE '2026-04-01', DATE '2026-05-01', 'standard', 15, 30)),
 'legacy counts 30 days (1 month), standard 31 days (1.5 months)');
-- The function the old code used gives the same months (calculate_invoice_duration is unchanged).
SELECT pg_temp.cr_assert((SELECT bool_and(pg_temp.cr_months(n) = (SELECT d.duration FROM public.calculate_invoice_duration(DATE '2026-04-01', DATE '2026-04-01' + n, 'legacy') d))
  FROM generate_series(0, 120) n), 'the default rule charges what calculate_invoice_duration charges, for 0 to 120 days');

-- 3. The sample line of the migration header: 10 bags, 12.50 a month, labour 3.00, tax 5 %, receipt 2026-04-01, dispatch 2026-05-11 (40 days).
-- Default rule: 1.5 months, storage 187.50, labour 30.00, base 217.50, tax basis 10.875 -> header tax 11, grand total ceil(228.50) = 229.
SELECT pg_temp.cr_assert(pg_temp.cr_months(40) = 1.5
  AND warehouse_security.storage_amount(12.50, 10, pg_temp.cr_months(40), 40, 15, 30) = 187.50
  AND warehouse_security.round_invoice_total(10.875, 'up') = 11
  AND warehouse_security.round_invoice_total(217.50 + warehouse_security.round_invoice_total(10.875, 'up'), 'up') = 229,
 'default rule: 1.5 months, storage 187.50, tax 11, total 229');
-- Steps of a day, minimum one step: 40 days -> 1.33 months, storage worked out from the days: 10 x 12.50 x 40 / 30 = 166.67, base 196.67,
-- tax basis 9.8335: up: tax 10, total 207; nearest: tax 10, total 207; none: tax 9.83, total 206.50.
SELECT pg_temp.cr_assert(pg_temp.cr_months(40, 1, 0) = 1.33
  AND warehouse_security.storage_amount(12.50, 10, pg_temp.cr_months(40, 1, 0), 40, 1, 0) = 166.67
  AND warehouse_security.round_invoice_total(9.8335, 'up') = 10 AND warehouse_security.round_invoice_total(196.67 + 10, 'up') = 207
  AND warehouse_security.round_invoice_total(9.8335, 'nearest') = 10 AND warehouse_security.round_invoice_total(196.67 + 10, 'nearest') = 207
  AND warehouse_security.round_invoice_total(9.8335, 'none') = 9.83 AND 196.67 + warehouse_security.round_invoice_total(9.8335, 'none') = 206.50,
 'steps of a day: 1.33 months, storage 166.67 (from the days, not the rounded months), totals 207 / 207 / 206.50');
-- Steps of a month, minimum 1 month: 40 days -> 2 months, storage 250.00, base 280.00, tax 14, total 294.
SELECT pg_temp.cr_assert(pg_temp.cr_months(40, 30, 30) = 2 AND warehouse_security.storage_amount(12.50, 10, 2, 40, 30, 30) = 250.00
  AND warehouse_security.round_invoice_total(280.00 * 0.05, 'up') = 14 AND warehouse_security.round_invoice_total(280.00 + 14, 'up') = 294,
 'steps of a month: 2 months, storage 250.00, tax 14, total 294');
-- Half-month steps, minimum 2 months: 40 days -> 2 months; minimum one step: 10 days -> 0.5 months, storage 62.50.
SELECT pg_temp.cr_assert(pg_temp.cr_months(40, 15, 60) = 2 AND pg_temp.cr_months(10, 15, 0) = 0.5
  AND warehouse_security.storage_amount(12.50, 10, pg_temp.cr_months(10, 15, 0), 10, 15, 0) = 62.50,
 'half-month steps: a minimum of 2 months charges 2; no minimum charges one step (0.5 months, storage 62.50)');
-- A ONE_TIME-style flat line is not worked out from days at all: with steps of a day the days only matter for a monthly line.
SELECT pg_temp.cr_assert(warehouse_security.storage_amount(40.00, 10, 1, NULL, 1, 30) = 400.00, 'a line without days is charge x quantity x duration: 400.00');
-- Rounding of a total.
SELECT pg_temp.cr_assert(warehouse_security.round_invoice_total(1234.40, 'up') = 1235 AND warehouse_security.round_invoice_total(1234.50, 'up') = 1235
  AND warehouse_security.round_invoice_total(1234.40, 'nearest') = 1234 AND warehouse_security.round_invoice_total(1234.50, 'nearest') = 1235
  AND warehouse_security.round_invoice_total(1234.40, 'none') = 1234.40, 'rounding up: 1235 / 1235; nearest: 1234 / 1235; none: 1234.40');
-- A rule the code does not know is refused, not guessed.
SELECT pg_temp.cr_assert(pg_temp.cr_raises($$SELECT pg_temp.cr_months(10, 7, 30)$$, 'Invalid charging rule%')
  AND pg_temp.cr_raises($$SELECT pg_temp.cr_months(10, 15, 45)$$, 'Invalid charging rule%'), 'a step or minimum outside the rule is refused');

-- 4. Changing the rule: administrators only (here the service key stands in for one), every field checked, one audit row per change.
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
SET LOCAL ROLE service_role;
SELECT pg_temp.cr_assert(pg_temp.cr_raises($$SELECT public.set_charging_rule('[]'::jsonb)$$, 'Send the rule as%')
  AND pg_temp.cr_raises($$SELECT public.set_charging_rule('{"step_days":7,"minimum_days":30,"days_counted":"legacy","rounding":"up"}')$$, 'step_days must be%')
  AND pg_temp.cr_raises($$SELECT public.set_charging_rule('{"step_days":"15","minimum_days":30,"days_counted":"legacy","rounding":"up"}')$$, 'step_days must be%')
  AND pg_temp.cr_raises($$SELECT public.set_charging_rule('{"step_days":15,"minimum_days":45,"days_counted":"legacy","rounding":"up"}')$$, 'minimum_days must be%')
  AND pg_temp.cr_raises($$SELECT public.set_charging_rule('{"step_days":30,"minimum_days":15,"days_counted":"legacy","rounding":"up"}')$$, 'The minimum charge is shorter than one step%')
  AND pg_temp.cr_raises($$SELECT public.set_charging_rule('{"step_days":15,"minimum_days":30,"days_counted":"other","rounding":"up"}')$$, 'days_counted must be%')
  AND pg_temp.cr_raises($$SELECT public.set_charging_rule('{"step_days":15,"minimum_days":30,"days_counted":"legacy","rounding":"down"}')$$, 'rounding must be%'),
 'a wrong rule is refused with its own message');
RESET ROLE;
SELECT pg_temp.cr_assert((SELECT step_days = 15 AND minimum_days = 30 AND days_counted = 'legacy' AND rounding = 'up' FROM warehouse_security.charging_rule WHERE id),
 'a refused rule changes nothing');
SELECT count(*) AS audit_before FROM public.audit_log WHERE table_name = 'charging_rule' \gset
SET LOCAL ROLE service_role;
SELECT public.set_charging_rule('{"step_days":30,"minimum_days":60,"days_counted":"standard","rounding":"nearest"}') AS changed \gset
SELECT public.set_charging_rule('{"step_days":30,"minimum_days":60,"days_counted":"standard","rounding":"nearest"}') AS again \gset
SELECT public.get_charging_rule() AS shown \gset
RESET ROLE;
SELECT pg_temp.cr_assert((:'changed'::jsonb->>'changed')::boolean AND (:'again'::jsonb->>'changed')::boolean IS FALSE
  AND :'changed'::jsonb#>'{previous_rule,step_days}' = '15'::jsonb AND :'changed'::jsonb#>>'{previous_rule,rounding}' = 'up',
 'a change says it changed and what the rule was; the same rule again changes nothing');
SELECT pg_temp.cr_assert(:'shown'::jsonb#>'{rule,step_days}' = '30'::jsonb AND :'shown'::jsonb#>'{rule,minimum_days}' = '60'::jsonb
  AND :'shown'::jsonb#>>'{rule,days_counted}' = 'standard' AND :'shown'::jsonb#>>'{rule,rounding}' = 'nearest', 'get_charging_rule shows the new rule');
SELECT pg_temp.cr_assert((SELECT count(*) = :audit_before + 1 FROM public.audit_log WHERE table_name = 'charging_rule'),
 'one audit row for the change, none for the same rule again');
-- The rule is the facility's for the invoice form and for a new invoice; an invoice keeps its own (the columns above), so changing the rule
-- rewrites no invoice.
SELECT pg_temp.cr_assert((SELECT count(*) = 0 FROM public.invoice i WHERE i.charge_step_days = 30 OR i.total_rounding = 'nearest'), 'no invoice was rewritten by the change');
ROLLBACK;
SELECT 'Charging rule: defaults, pinned figures, validation and audit passed.' AS charging_rule;
