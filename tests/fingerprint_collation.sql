-- The data fingerprint (scripts/data-fingerprint.sh) sorts with COLLATE "C". The two orderings below must
-- differ under en_US, so a sort by the database default would give another fingerprint than a sort by C.
-- Runs after all migrations; writes nothing.
\set ON_ERROR_STOP on
DO $$
DECLARE c text; en text;
BEGIN
  SELECT string_agg(x, ',' ORDER BY x COLLATE "C"), string_agg(x, ',' ORDER BY x COLLATE "en_US.utf8")
    INTO c, en FROM (VALUES ('a'), ('B'), ('a-b'), ('ab')) v(x);
  IF c IS DISTINCT FROM 'B,a,a-b,ab' THEN RAISE EXCEPTION 'fingerprint collation: C order is %', c; END IF;
  IF en IS NOT DISTINCT FROM c THEN RAISE EXCEPTION 'fingerprint collation: en_US gives the same order as C (%), the test cannot tell them apart', en; END IF;
END $$;
