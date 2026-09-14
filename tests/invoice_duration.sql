-- Explicit boundary fixtures for the existing half-month/minimum-month rule.
-- Runs only in the disposable migration database. No grants are needed or added.
DO $$
DECLARE
  fixture record;
  actual record;
BEGIN
  FOR fixture IN SELECT * FROM (VALUES
    ('legacy',   '2026-04-01'::date,  0,  1, 1.0::numeric),
    ('legacy',   '2026-04-16'::date, 15, 15, 1.0::numeric),
    ('legacy',   '2026-05-01'::date, 30, 30, 1.0::numeric),
    ('legacy',   '2026-05-02'::date, 31, 31, 1.5::numeric),
    ('legacy',   '2026-05-16'::date, 45, 45, 1.5::numeric),
    ('legacy',   '2026-05-17'::date, 46, 46, 2.0::numeric),
    ('standard', '2026-04-01'::date,  1,  1, 1.0::numeric),
    ('standard', '2026-04-30'::date, 30, 30, 1.0::numeric),
    ('standard', '2026-05-01'::date, 31, 31, 1.5::numeric)
  ) AS cases(mode, dispatched, days, billable, periods) LOOP
    SELECT * INTO STRICT actual FROM public.calculate_invoice_duration('2026-04-01', fixture.dispatched, fixture.mode);
    IF ROW(actual.no_of_days, actual.billable_days, actual.duration)
       IS DISTINCT FROM ROW(fixture.days, fixture.billable, fixture.periods) THEN
      RAISE EXCEPTION 'Invoice duration boundary failed: % / %', fixture.mode, fixture.dispatched;
    END IF;
  END LOOP;
END;
$$;
