-- Migration 151 (WH-109): dispatch print ranges in natural order, and a unique request id per print job.
--   * get_dispatch_range_for_print reads a disp_no as <letters><digits><letters> and compares the number as a number, so A998..A1002
--     matches (as text 'A998' is above 'A1002'), a number with leading zeros sorts by value, A1000..A1001 includes A1000B, and a number
--     stored with a trailing space is found by its own number and answered trimmed. Ends with different letters, or that do not
--     parse, fall back to the trimmed, upper-cased text comparison. Rows come back in natural order.
--   * print_jobs.request_id (uuid, NULL) with a unique index on (user_id, request_id): a second row with the same pair fails, rows
--     without an id never collide, the same id for another user is allowed.
-- Fictional data; runs only in migrations.sh's disposable, network-disabled database; rolls back.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION pg_temp.r_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'print range / request id 151: %',label; END IF; END $$;
-- The disp_no values of an answer, in the order the function returned them.
CREATE FUNCTION pg_temp.r_range(a text, b text, lim integer DEFAULT 100) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(x->>'disp_no' ORDER BY ord), ARRAY[]::text[])
  FROM jsonb_array_elements(public.get_dispatch_range_for_print(a, b, lim)->'data') WITH ORDINALITY AS t(x, ord) $$;
CREATE FUNCTION pg_temp.r_dup(statement text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE statement; RETURN 'inserted';
EXCEPTION WHEN unique_violation THEN RETURN 'unique_violation'; END $$;

-- Grants are those of the function before the migration: the service role only.
SELECT pg_temp.r_assert((SELECT count(*) FROM pg_proc WHERE proname = 'get_dispatch_range_for_print') = 1, 'one get_dispatch_range_for_print');
SELECT pg_temp.r_assert(has_function_privilege('service_role', 'public.get_dispatch_range_for_print(text,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.get_dispatch_range_for_print(text,text,integer)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.get_dispatch_range_for_print(text,text,integer)', 'EXECUTE'), 'grants unchanged');

-- Fixture: dispatches in four prefixes. QA has numbers of 3 and 4 digits, a suffix and a stored trailing space.
INSERT INTO public.customers(name, mobile, active) VALUES ('Range Order Cold Storage', '9766600151', true);
INSERT INTO public.dispatch(disp_no, disp_date, customer_id, customer_name)
  SELECT v.n, now(), c.id, c.name
  FROM public.customers c, (VALUES ('QA998'), ('QA999'), ('QA1000'), ('QA1000B'), ('QA1001'), ('QA1002'), ('QA1003 '),
    ('QB0007'), ('QB08'), ('QB9'), ('QB10'), ('QC9999'), ('QC10000')) v(n)
  WHERE c.name = 'Range Order Cold Storage';
SELECT pg_temp.r_assert((SELECT disp_no FROM public.dispatch WHERE disp_no LIKE 'QA1003%') = 'QA1003 ', 'fixture: the trailing space is stored');

-- A range that crosses a digit count (the case that matched nothing as text).
SELECT pg_temp.r_assert(pg_temp.r_range('QA998', 'QA1002') = ARRAY['QA998', 'QA999', 'QA1000', 'QA1000B', 'QA1001', 'QA1002'], 'QA998..QA1002 in natural order, with the suffixed number between its neighbours: ' || pg_temp.r_range('QA998', 'QA1002')::text);
SELECT pg_temp.r_assert(pg_temp.r_range('QC9999', 'QC10000') = ARRAY['QC9999', 'QC10000'], 'QC9999..QC10000: ' || pg_temp.r_range('QC9999', 'QC10000')::text);
-- An ordinary range inside one digit count, and a single number.
SELECT pg_temp.r_assert(pg_temp.r_range('QA999', 'QA1000') = ARRAY['QA999', 'QA1000'], 'QA999..QA1000 stops at QA1000, not QA1000B: ' || pg_temp.r_range('QA999', 'QA1000')::text);
SELECT pg_temp.r_assert(pg_temp.r_range('QA1001', 'QA1001') = ARRAY['QA1001'], 'a range of one number');
SELECT pg_temp.r_assert(pg_temp.r_range('QA1004', 'QA1009') = ARRAY[]::text[], 'a range with no dispatch is empty');
SELECT pg_temp.r_assert(public.get_dispatch_range_for_print('QA1004', 'QA1009')->'data' = '[]'::jsonb
  AND (public.get_dispatch_range_for_print('QA1004', 'QA1009')->>'success')::boolean, 'empty is an empty list inside a success answer');
-- A suffix: the range A1000..A1001 includes A1000B.
SELECT pg_temp.r_assert(pg_temp.r_range('QA1000', 'QA1001') = ARRAY['QA1000', 'QA1000B', 'QA1001'], 'QA1000..QA1001 includes QA1000B: ' || pg_temp.r_range('QA1000', 'QA1001')::text);
SELECT pg_temp.r_assert(pg_temp.r_range('QA1000B', 'QA1000B') = ARRAY['QA1000B'], 'the suffixed number alone');
SELECT pg_temp.r_assert(pg_temp.r_range('QA1000B', 'QA1002') = ARRAY['QA1000B', 'QA1001', 'QA1002'], 'a range that starts at the suffixed number');
-- A stored trailing space: found by its own number, answered trimmed; spaces and case in the request do not matter.
SELECT pg_temp.r_assert(pg_temp.r_range('QA1003', 'QA1003') = ARRAY['QA1003'], 'QA1003 stored with a trailing space is found by QA1003 and answered trimmed: ' || pg_temp.r_range('QA1003', 'QA1003')::text);
SELECT pg_temp.r_assert(pg_temp.r_range('QA1002', 'QA1003') = ARRAY['QA1002', 'QA1003'], 'a range ending at the number with the trailing space');
SELECT pg_temp.r_assert(pg_temp.r_range('  qa1003 ', 'qa1003') = ARRAY['QA1003'], 'spaces and lower case in the request');
-- Leading zeros and digit counts do not matter; the number is compared as a number.
SELECT pg_temp.r_assert(pg_temp.r_range('QB7', 'QB10') = ARRAY['QB0007', 'QB08', 'QB9', 'QB10'], 'QB7..QB10: ' || pg_temp.r_range('QB7', 'QB10')::text);
SELECT pg_temp.r_assert(pg_temp.r_range('QB0008', 'QB009') = ARRAY['QB08', 'QB9'], 'zeros on the ends: ' || pg_temp.r_range('QB0008', 'QB009')::text);
-- Another prefix is never mixed in.
SELECT pg_temp.r_assert(NOT EXISTS (SELECT 1 FROM unnest(pg_temp.r_range('QA1', 'QA99999')) n WHERE n NOT LIKE 'QA%'), 'only the requested letters');
-- The limit applies in natural order.
SELECT pg_temp.r_assert(pg_temp.r_range('QA998', 'QA1002', 2) = ARRAY['QA998', 'QA999'], 'limit 2 keeps the first two in natural order');
SELECT pg_temp.r_assert(pg_temp.r_range('QA998', 'QA1002', 4) = ARRAY['QA998', 'QA999', 'QA1000', 'QA1000B'], 'limit 4');

-- Different letters at the two ends: the text comparison on trimmed, upper-cased values (the old rule), rows still in natural order.
SELECT pg_temp.r_assert(pg_temp.r_range('QA1000', 'QB5') = ARRAY['QA998', 'QA999', 'QA1000', 'QA1000B', 'QA1001', 'QA1002', 'QA1003', 'QB0007', 'QB08', 'QB10'],
  'mixed prefixes fall back to text: ' || pg_temp.r_range('QA1000', 'QB5')::text);
-- An end that does not parse: the same fallback.
SELECT pg_temp.r_assert(pg_temp.r_range('QA1000', 'QA1001!') = ARRAY['QA1000', 'QA1000B', 'QA1001'], 'an unparsable end falls back to text: ' || pg_temp.r_range('QA1000', 'QA1001!')::text);

-- The payload keeps its shape: trimmed number, date, customer name, an empty item list and a zero total for a dispatch with no lines.
SELECT pg_temp.r_assert((SELECT x FROM jsonb_array_elements(public.get_dispatch_range_for_print('QA1003', 'QA1003')->'data') AS t(x))
  @> jsonb_build_object('disp_no', 'QA1003', 'customer_name', 'Range Order Cold Storage', 'items', '[]'::jsonb, 'total_qty', 0)
  AND (SELECT x->'customer'->>'id' FROM jsonb_array_elements(public.get_dispatch_range_for_print('QA1003', 'QA1003')->'data') AS t(x))
    = (SELECT id::text FROM public.customers WHERE name = 'Range Order Cold Storage'), 'payload shape');

-- print_jobs.request_id
SELECT pg_temp.r_assert((SELECT data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'print_jobs' AND column_name = 'request_id') = 'uuid'
  AND (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'print_jobs' AND column_name = 'request_id') = 'YES', 'request_id is a nullable uuid');
SELECT pg_temp.r_assert((SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'print_jobs_user_request_id_key')
  ~ 'UNIQUE INDEX .*\(user_id, request_id\) WHERE \(request_id IS NOT NULL\)', 'the unique index is on (user_id, request_id), not for NULL ids');

SELECT gen_random_uuid() AS user_a, gen_random_uuid() AS user_b, gen_random_uuid() AS req \gset
-- A row written the old way (no request_id) still works and has none.
INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id) VALUES ('Dispatch', 'QA998', 'QA1002', :'user_a');
SELECT pg_temp.r_assert((SELECT request_id IS NULL AND status = 'queued' FROM public.print_jobs WHERE user_id = :'user_a'::uuid), 'a row without request_id is unchanged');
INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id, request_id) VALUES ('GRN', 'QG1', 'QG2', :'user_a', :'req');
-- The same pair fails; the same id for another user, and another id for the same user, do not.
SELECT pg_temp.r_assert(pg_temp.r_dup(format($s$INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id, request_id) VALUES ('GRN', 'QG1', 'QG2', %L, %L)$s$, :'user_a', :'req')) = 'unique_violation', 'a second row with the same user and request_id fails');
SELECT pg_temp.r_assert(pg_temp.r_dup(format($s$INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id, request_id) VALUES ('GRN', 'QG1', 'QG2', %L, %L)$s$, :'user_b', :'req')) = 'inserted', 'the same request_id for another user is allowed');
SELECT pg_temp.r_assert(pg_temp.r_dup(format($s$INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id, request_id) VALUES ('GRN', 'QG1', 'QG2', %L, gen_random_uuid())$s$, :'user_a')) = 'inserted', 'another request_id for the same user is allowed');
-- Rows without a request_id never collide, as many as there are.
SELECT pg_temp.r_assert(pg_temp.r_dup(format($s$INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id) VALUES ('Invoice', '1', '2', %L), ('Invoice', '1', '2', %L)$s$, :'user_a', :'user_a')) = 'inserted', 'NULL request_ids do not collide');
SELECT pg_temp.r_assert((SELECT count(*) FROM public.print_jobs WHERE user_id = :'user_a'::uuid AND request_id IS NULL) = 3, 'three rows without a request_id');
-- The claim of a failed row (print-request.ts) updates the row; its pair stays unique.
UPDATE public.print_jobs SET status = 'failed' WHERE user_id = :'user_a'::uuid AND request_id = :'req'::uuid;
SELECT pg_temp.r_assert(pg_temp.r_dup(format($s$INSERT INTO public.print_jobs(job_type, document_range_start, document_range_end, user_id, request_id) VALUES ('GRN', 'QG1', 'QG2', %L, %L)$s$, :'user_a', :'req')) = 'unique_violation', 'a failed row still holds its pair');
ROLLBACK;
\echo 'Print range and request id (migration 151) checks passed.'
