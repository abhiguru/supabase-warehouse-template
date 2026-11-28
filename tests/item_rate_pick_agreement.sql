-- WH-344 (guards WH-311): the item rate that Customer dues picks for each GRN line, set-based for all GRNs at once inside
-- warehouse_security.not_invoiced_grns (customer_dues_speed.sql, CTE item_rates), is the rate public.find_storage_price picks for the
-- same item, customer, weight, GRN day (business_date of the GRN's date) and price type (lower(pricing_mode)).
--
-- The set-based pick is not a function of its own, so it is compared through what it feeds: the line's amount and has_rate in
-- not_invoiced_grns(.., p_lots := true).store_lots. For every case line, in order:
--   1. the reference rate is find_storage_price(...), called here the way the old per-line code called it;
--   2. a "twin" GRN of a rate-less customer, same date, pricing mode, item, weight and quantity, is given that reference rate as its OWN
--      GRN rate (grn_rates, a path that does not use item_rates), so the twin's amount is what the dues figure must be when the
--      reference rate is used, worked out by the very same query (storage_amount, labour, tax, rounding stay out of this check);
--   3. the case GRN's lot must show the twin's amount and has_rate = (find_storage_price found a rate). A case whose reference
--      finds no rate must show has_rate false and no amount.
-- Every rate field differs between the rate rows (unit price, labour, tax %), so choosing another row changes the amount.
--
-- Branches of find_storage_price covered (case numbers in the case list below):
--   customer-own rate vs item default; own rate beating a narrower default band; another customer's own rate not leaking;
--   own rate not reaching back before its start day; default starting on / ending on the GRN day; the item's first default rate
--   (migration 129) reaching back, with several bands, and a later default rate not reaching back; several candidate rates (narrowest
--   band, then latest start, then row id for an exact tie); weight on a band edge, outside every band, 0, NULL; NULL GRN date;
--   GRN day from the India date near midnight; price types monthly and one_time, a NULL pricing mode (monthly), a type with no rate;
--   an item with no rate at all.
-- Not covered: the 'one-time' spelling (the pricing_mode column only holds ONE_TIME and MONTHLY) and the GRN's own rate (it is not
-- find_storage_price's rule; WH-188's suite compares it with the invoice form).
--
-- Mutation for Test to run in migrations.sh (each must make this suite fail naming case lines; undo it after):
--   * customer_dues_speed.sql, item_rates ORDER BY: drop "(c.customer_id IS NULL), " (default beats own rate), or change
--     "c.effective_from DESC" to "c.effective_from" (earliest start wins), or drop "(c.weight_max - c.weight_min), ";
--   * item_rates: change "gr.grn_date <= f.effective_to" to "gr.grn_date < f.effective_to" (cases on an end day);
--   * item_rates: remove the second UNION ALL branch's "OR (gr.grn_date < f.effective_from AND f.effective_from = fd.first_from)";
--   * in find_storage_price (baseline + migration 129, redefine in a scratch copy of the migration): change "p_weight <= isp.weight_max"
--     to "p_weight < isp.weight_max", or "isp.effective_from <= p_dispatch_date" to "isp.effective_from < p_dispatch_date".
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolled back at the end.
\set ON_ERROR_STOP on
BEGIN;

CREATE TEMP TABLE rp_item(key text PRIMARY KEY, id uuid);
CREATE TEMP TABLE rp_cust(key text PRIMARY KEY, id uuid);
CREATE TEMP TABLE rp_case(n integer PRIMARY KEY, label text, item text, cust text, weight integer, ts timestamptz, mode text);
CREATE TEMP TABLE rp_ref(n integer PRIMARY KEY, gr_no text, twin_no text, rate_id uuid, unit_price numeric, price_type text);

INSERT INTO public.customers(name, mobile) VALUES ('Rate Pick Alpha', '9888888941') RETURNING id AS ca \gset
INSERT INTO public.customers(name, mobile) VALUES ('Rate Pick Beta', '9888888942') RETURNING id AS cb \gset
INSERT INTO public.customers(name, mobile) VALUES ('Rate Pick Twin', '9888888943') RETURNING id AS cc \gset
INSERT INTO rp_cust VALUES ('A', :'ca'), ('B', :'cb'), ('C', :'cc');
INSERT INTO public.items(name, packaging) VALUES ('Rate Pick Item 1', 'Bag') RETURNING id AS i1 \gset
INSERT INTO public.items(name, packaging) VALUES ('Rate Pick Item 2', 'Bag') RETURNING id AS i2 \gset
INSERT INTO public.items(name, packaging) VALUES ('Rate Pick Item 3', 'Bag') RETURNING id AS i3 \gset
INSERT INTO public.items(name, packaging) VALUES ('Rate Pick Item 4', 'Bag') RETURNING id AS i4 \gset
INSERT INTO public.items(name, packaging) VALUES ('Rate Pick Item 5', 'Bag') RETURNING id AS i5 \gset
INSERT INTO public.items(name, packaging) VALUES ('Rate Pick Item 6', 'Bag') RETURNING id AS i6 \gset
INSERT INTO rp_item VALUES ('i1', :'i1'), ('i2', :'i2'), ('i3', :'i3'), ('i4', :'i4'), ('i5', :'i5'), ('i6', :'i6');

-- One rate row: unit price, labour and tax % are all different from row to row (u, l, t).
CREATE FUNCTION pg_temp.rp_rate(p_item text, p_cust text, p_type text, p_min integer, p_max integer, p_from date, p_to date,
                                u numeric, l numeric, t numeric) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.item_storage_prices(item_id, customer_id, price_type, unit_price, unit_price_one_time, unit_price_monthly,
                                         weight_min, weight_max, labour_rate, tax_percent, effective_from, effective_to)
  SELECT (SELECT id FROM rp_item WHERE key = p_item), (SELECT id FROM rp_cust WHERE key = p_cust), p_type, u, u, u, p_min, p_max, l, t, p_from, p_to
$$;

-- Item 1: item defaults only. D1, D6 are the first default rates (2026-02-01); the others start later.
SELECT pg_temp.rp_rate('i1', NULL, 'monthly',   0, 100, '2026-02-01', '2026-03-31', 110, 1, 5);   -- D1
SELECT pg_temp.rp_rate('i1', NULL, 'monthly', 101, 200, '2026-02-01', '2026-02-28', 160, 6, 18);  -- D6
SELECT pg_temp.rp_rate('i1', NULL, 'monthly',   0, 100, '2026-04-01', NULL,         120, 2, 12);  -- D2
SELECT pg_temp.rp_rate('i1', NULL, 'monthly',  40,  60, '2026-04-01', NULL,         130, 3, 0);   -- D3 (narrower)
SELECT pg_temp.rp_rate('i1', NULL, 'monthly',   0, 100, '2026-04-01', '2026-05-31', 140, 4, 18);  -- D4 (tie with D2 on band and start)
SELECT pg_temp.rp_rate('i1', NULL, 'monthly',   0, 100, '2026-05-15', NULL,         150, 5, 5);   -- D5 (later start)
-- Item 2: defaults and customer A's own rates.
SELECT pg_temp.rp_rate('i2', NULL, 'monthly',   0, 100, '2026-01-01', NULL,         200, 7, 5);   -- E1
SELECT pg_temp.rp_rate('i2', NULL, 'monthly',  45,  55, '2026-01-01', NULL,         230, 8, 12);  -- E2 (narrow default)
SELECT pg_temp.rp_rate('i2', 'A',  'monthly',   0, 100, '2026-03-01', '2026-04-30', 210, 9, 18);  -- F1
SELECT pg_temp.rp_rate('i2', 'A',  'monthly',   0, 100, '2026-05-01', NULL,         220, 10, 0);  -- F2
SELECT pg_temp.rp_rate('i2', 'A',  'monthly',  40,  60, '2026-05-10', NULL,         225, 11, 5);  -- F3 (narrower own)
-- Item 3: both price types, and customer B's own one-time rate.
SELECT pg_temp.rp_rate('i3', NULL, 'monthly',   0, 100, '2026-01-01', NULL,         300, 3, 5);   -- G1
SELECT pg_temp.rp_rate('i3', NULL, 'one_time',  0, 100, '2026-01-01', NULL,         310, 9, 12);  -- G2
SELECT pg_temp.rp_rate('i3', 'B',  'one_time',  0, 100, '2026-04-01', NULL,         320, 12, 18); -- G3
-- Item 4: only customer A's own monthly rate. Item 5: no rate at all.
SELECT pg_temp.rp_rate('i4', 'A',  'monthly',   0, 100, '2026-01-01', NULL,         400, 4, 18);  -- H1
-- Item 6: the first default rate (J1) and a later one (J2) that must not reach back; customer A's own K1 in between.
SELECT pg_temp.rp_rate('i6', NULL, 'monthly',   0, 100, '2026-03-01', '2026-04-30', 500, 13, 5);  -- J1
SELECT pg_temp.rp_rate('i6', NULL, 'monthly',   0, 100, '2026-05-01', NULL,         510, 14, 12); -- J2
SELECT pg_temp.rp_rate('i6', 'A',  'monthly',   0, 100, '2026-04-01', '2026-04-30', 520, 15, 18); -- K1

-- The lines. GRN day = India day of ts (noon, except cases 15 and 16).
INSERT INTO rp_case(n, label, item, cust, weight, ts, mode)
SELECT n, label, item, cust, weight, CASE WHEN d IS NULL THEN NULL ELSE (d || ' 12:00:00+05:30')::timestamptz END, mode
  FROM (VALUES
   (1,  'i1 B w50 before the first default',            'i1','B', 50, '2026-01-15', 'MONTHLY'),
   (2,  'i1 B w150 first default, second band, back',   'i1','B',150, '2026-01-15', 'MONTHLY'),
   (3,  'i1 B w150 second band expired, no rate',       'i1','B',150, '2026-03-15', 'MONTHLY'),
   (4,  'i1 B w50 on the first start day',              'i1','B', 50, '2026-02-01', 'MONTHLY'),
   (5,  'i1 B w50 on the end day of D1',                'i1','B', 50, '2026-03-31', 'MONTHLY'),
   (6,  'i1 B w50 on a start day, narrower band',       'i1','B', 50, '2026-04-01', 'MONTHLY'),
   (7,  'i1 B w20 tie on band and start',               'i1','B', 20, '2026-04-01', 'MONTHLY'),
   (8,  'i1 B w20 on the end day of D4',                'i1','B', 20, '2026-05-31', 'MONTHLY'),
   (9,  'i1 B w20 day after D4, later start wins',      'i1','B', 20, '2026-06-01', 'MONTHLY'),
   (10, 'i1 B w20 three candidates, latest start',      'i1','B', 20, '2026-05-20', 'MONTHLY'),
   (11, 'i1 B w100 on the band edge',                   'i1','B',100, '2026-06-10', 'MONTHLY'),
   (12, 'i1 B w101 outside every band, no rate',        'i1','B',101, '2026-06-10', 'MONTHLY'),
   (13, 'i1 B no weight, no rate',                      'i1','B', NULL, '2026-06-10', 'MONTHLY'),
   (14, 'i1 B w0 inside band 0..100',                   'i1','B',  0, '2026-06-10', 'MONTHLY'),
   (15, 'i1 B w50 just after midnight India time',      'i1','B', 50, '2026-04-01', 'MONTHLY'),
   (16, 'i1 B w50 no GRN date, no rate',                'i1','B', 50, NULL,         'MONTHLY'),
   (17, 'i1 A w50 customer without own rate on item',   'i1','A', 50, '2026-06-10', 'MONTHLY'),
   (18, 'i2 A w50 own not started, narrow default',     'i2','A', 50, '2026-02-15', 'MONTHLY'),
   (19, 'i2 A w20 own not started, wide default',       'i2','A', 20, '2026-02-15', 'MONTHLY'),
   (20, 'i2 A w50 on own start day',                    'i2','A', 50, '2026-03-01', 'MONTHLY'),
   (21, 'i2 A w50 on own end day',                      'i2','A', 50, '2026-04-30', 'MONTHLY'),
   (22, 'i2 A w50 own next rate starts',                'i2','A', 50, '2026-05-01', 'MONTHLY'),
   (23, 'i2 A w50 narrower own band',                   'i2','A', 50, '2026-05-20', 'MONTHLY'),
   (24, 'i2 A w20 wide own band',                       'i2','A', 20, '2026-05-20', 'MONTHLY'),
   (25, 'i2 A w70 own wide band beats default',         'i2','A', 70, '2026-03-10', 'MONTHLY'),
   (26, 'i2 B w50 default only, narrow band',           'i2','B', 50, '2026-03-10', 'MONTHLY'),
   (27, 'i2 B w50 default only, other own not leaking', 'i2','B', 50, '2026-05-20', 'MONTHLY'),
   (28, 'i2 B w20 before the first default',            'i2','B', 20, '2025-12-31', 'MONTHLY'),
   (29, 'i3 B w50 monthly',                             'i3','B', 50, '2026-03-10', 'MONTHLY'),
   (30, 'i3 B w50 one time, default',                   'i3','B', 50, '2026-03-10', 'ONE_TIME'),
   (31, 'i3 B w50 one time, own rate',                  'i3','B', 50, '2026-04-10', 'ONE_TIME'),
   (32, 'i3 B w50 monthly, own is one time only',       'i3','B', 50, '2026-04-10', 'MONTHLY'),
   (33, 'i3 B w50 no pricing mode is monthly',          'i3','B', 50, '2026-03-10', NULL),
   (34, 'i3 A w50 one time, B''s own rate not leaking', 'i3','A', 50, '2026-04-10', 'ONE_TIME'),
   (35, 'i4 A w50 own rate only',                       'i4','A', 50, '2026-03-10', 'MONTHLY'),
   (36, 'i4 A w50 own rate, other price type, no rate', 'i4','A', 50, '2026-03-10', 'ONE_TIME'),
   (37, 'i4 B w50 only A has a rate, no rate',          'i4','B', 50, '2026-03-10', 'MONTHLY'),
   (38, 'i4 A w50 own rate never reaches back',         'i4','A', 50, '2025-12-15', 'MONTHLY'),
   (39, 'i5 B w50 item with no rate',                   'i5','B', 50, '2026-03-10', 'MONTHLY'),
   (40, 'i6 A w50 first default reaches back past own', 'i6','A', 50, '2026-02-10', 'MONTHLY'),
   (41, 'i6 B w50 first default reaches back',          'i6','B', 50, '2026-02-10', 'MONTHLY'),
   (42, 'i6 A w50 own rate in force',                   'i6','A', 50, '2026-04-15', 'MONTHLY'),
   (43, 'i6 A w50 own rate over, later default',        'i6','A', 50, '2026-06-01', 'MONTHLY'),
   (44, 'i6 B w50 first default in force',              'i6','B', 50, '2026-04-15', 'MONTHLY'),
   (45, 'i6 B w50 later default on its start day',      'i6','B', 50, '2026-05-01', 'MONTHLY')
  ) v(n, label, item, cust, weight, d, mode);
-- Case 15 is just after midnight India time: 2026-04-01 00:30 IST is 2026-03-31 19:00 UTC, still the India day 2026-04-01.
UPDATE rp_case SET ts = '2026-04-01 00:30:00+05:30'::timestamptz WHERE n = 15;

-- Build the case GRNs, the reference answer of find_storage_price, and a twin GRN for each line the reference prices.
DO $build$
DECLARE
  r record; v_gr uuid; v_twin uuid; fp public.item_storage_prices;
  v_item uuid; v_cust uuid; v_cc uuid := (SELECT id FROM rp_cust WHERE key = 'C');
BEGIN
  FOR r IN SELECT * FROM rp_case ORDER BY n LOOP
    v_item := (SELECT id FROM rp_item WHERE key = r.item);
    v_cust := (SELECT id FROM rp_cust WHERE key = r.cust);
    INSERT INTO public.goodsreceived(gr_no, date, customer_id, customer_name, pricing_mode)
      VALUES ('RP' || lpad(r.n::text, 3, '0'), r.ts, v_cust, 'Rate Pick', r.mode) RETURNING id INTO v_gr;
    INSERT INTO public.goodsreceived_trl(gr_id, item_id, item_name, packaging, qty, stock, weight)
      VALUES (v_gr, v_item, 'Rate Pick Lot', 'Bag', 10, 10, r.weight);
    -- The reference: what the per-line code asked, with the GRN's India day and lower(pricing_mode).
    fp := public.find_storage_price(v_item, v_cust, r.weight, warehouse_security.business_date(r.ts), lower(r.mode));
    INSERT INTO rp_ref VALUES (r.n, 'RP' || lpad(r.n::text, 3, '0'), 'TW' || lpad(r.n::text, 3, '0'), fp.id, fp.unit_price, fp.price_type);
    IF fp.id IS NOT NULL THEN
      INSERT INTO public.goodsreceived(gr_no, date, customer_id, customer_name, pricing_mode)
        VALUES ('TW' || lpad(r.n::text, 3, '0'), r.ts, v_cc, 'Rate Pick Twin', r.mode) RETURNING id INTO v_twin;
      INSERT INTO public.goodsreceived_trl(gr_id, item_id, item_name, packaging, qty, stock, weight)
        VALUES (v_twin, v_item, 'Rate Pick Lot', 'Bag', 10, 10, r.weight);
      INSERT INTO public.grn_rates(gr_id, item_id, price_type, weight_min, weight_max, unit_price, labour_rate, tax_percent)
        VALUES (v_twin, v_item, fp.price_type, 0, 100000, fp.unit_price, fp.labour_rate, fp.tax_percent);
    END IF;
  END LOOP;
END
$build$;

-- The dues figure of every line: the set-based query, for the three customers, lots asked for.
CREATE TEMP TABLE rp_got AS
SELECT n.gr_no::text AS gr_no, (n.store_lots -> 0 ->> 'has_rate')::boolean AS has_rate,
       (n.store_lots -> 0 ->> 'amount')::numeric AS amount, jsonb_array_length(n.store_lots) AS lots
  FROM (SELECT cid FROM (VALUES (:'ca'::uuid), (:'cb'::uuid), (:'cc'::uuid)) c(cid)) c
 CROSS JOIN LATERAL warehouse_security.not_invoiced_grns(c.cid, '2026-06-30'::date, true) n;

DO $check$
DECLARE
  v_bad text; v_rated integer; v_norate integer; v_picked integer;
BEGIN
  -- The fixture reaches the edges: enough lines with a reference rate, with none, and enough different rate rows picked.
  SELECT count(*) FILTER (WHERE rate_id IS NOT NULL), count(*) FILTER (WHERE rate_id IS NULL), count(DISTINCT rate_id)
    INTO v_rated, v_norate, v_picked FROM rp_ref;
  IF v_norate < 8 OR v_rated < 30 OR v_picked < 17 THEN
    RAISE EXCEPTION 'item rate pick: the fixture is too thin (rated %, no rate %, distinct rates picked %)', v_rated, v_norate, v_picked;
  END IF;

  -- Every case line and every twin has exactly one dues row with exactly one lot.
  SELECT string_agg(x.gr_no, ', ' ORDER BY x.gr_no) INTO v_bad FROM (
    SELECT gr_no FROM rp_ref UNION ALL SELECT twin_no FROM rp_ref WHERE rate_id IS NOT NULL) x
   WHERE (SELECT count(*) FROM rp_got g WHERE g.gr_no = x.gr_no) <> 1 OR (SELECT max(g.lots) FROM rp_got g WHERE g.gr_no = x.gr_no) <> 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'item rate pick: no single dues row with one lot for %', v_bad; END IF;

  -- A twin is a priced line (otherwise equal NULLs would hide a difference).
  SELECT string_agg(t.twin_no, ', ' ORDER BY t.twin_no) INTO v_bad
    FROM rp_ref t JOIN rp_got g ON g.gr_no = t.twin_no
   WHERE t.rate_id IS NOT NULL AND (g.has_rate IS NOT TRUE OR g.amount IS NULL OR g.amount <= 0);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'item rate pick: the twin line has no amount for %', v_bad; END IF;

  -- The comparison: has_rate follows find_storage_price, and the amount is the one the reference rate gives.
  SELECT string_agg(format('%s (%s: find_storage_price gives %s, dues give has_rate %s amount %s, reference amount %s)',
                           c.label, r.gr_no, COALESCE(r.unit_price::text, 'no rate'), g.has_rate, COALESCE(g.amount::text, 'none'),
                           COALESCE(w.amount::text, 'none')), '; ' ORDER BY r.n)
    INTO v_bad
    FROM rp_ref r
    JOIN rp_case c ON c.n = r.n
    JOIN rp_got g ON g.gr_no = r.gr_no
    LEFT JOIN rp_got w ON w.gr_no = r.twin_no
   WHERE g.has_rate IS DISTINCT FROM (r.rate_id IS NOT NULL)
      OR (r.rate_id IS NULL AND g.amount IS NOT NULL)
      OR (r.rate_id IS NOT NULL AND g.amount IS DISTINCT FROM w.amount);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'item rate pick: Customer dues and find_storage_price choose different rates for: %', v_bad; END IF;
END
$check$;

ROLLBACK;
\echo 'The set-based item rate pick in Customer dues agrees with find_storage_price on every line.'
