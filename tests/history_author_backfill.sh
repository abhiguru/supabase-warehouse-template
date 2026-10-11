#!/usr/bin/env bash
# Migration 48 gives invoice_discount_history (migration 41) the column
# changed_by_name and fills it, for the rows that exist at the upgrade, with the
# name each author's profile has then. The table refuses every UPDATE, so the
# block switches the append-only trigger off for its one statement. This test
# runs that block as written in the migration file against migrations.sh's
# disposable container, on rows shaped like those of an installation that had
# discounts before the upgrade:
#   1. a row whose author still has a profile gets that profile's name;
#   2. a row without an author, and one whose author's profile is gone, stay
#      without a name;
#   3. a row that already has a name keeps it;
#   4. afterwards the trigger is on again and still refuses a change;
#   5. a second run changes nothing.
# Everything runs in one transaction that is rolled back.
# BACKFILL_MIGRATION names another copy of the migration to take the block from.
set -euo pipefail
container="${1:?disposable test container name required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
migration="${BACKFILL_MIGRATION:-$ROOT/migrations/00000000000048_owner_decisions.sql}"
export PGPASSWORD=disposable-test-database-only
scratch=$(mktemp -d "${TMPDIR:-/tmp}/history-backfill.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

awk '/^DO \$backfill\$/{inside=1} inside{print} /^END \$backfill\$;/{inside=0}' "$migration" > "$scratch/backfill.sql"
grep -q '^DO \$backfill\$' "$scratch/backfill.sql" && grep -q '^END \$backfill\$;' "$scratch/backfill.sql" || {
  echo "Migration 48's author-name backfill was not found in $migration." >&2; exit 1;
}

{
  cat <<'SQL'
BEGIN;
CREATE FUNCTION pg_temp.fill_assert(ok boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'history author backfill: %',label; END IF; END $$;
INSERT INTO public.user_profiles(id,auth_user_id,mobile,name,role,active,enrollment_status) VALUES
 ('00000000-0000-4000-8000-0000000b0001',gen_random_uuid(),'919888888838','Backfill Present Author','staff',true,'approved'),
 ('00000000-0000-4000-8000-0000000b0002',gen_random_uuid(),'919888888839','Backfill Renamed Author','staff',true,'approved');
-- Rows as migration 41 wrote them: no name.
INSERT INTO public.invoice_discount_history(invoice_id,inv_fin_year,inv_no,old_discount,new_discount,reason,changed_by,changed_by_role,changed_by_name) VALUES
 (gen_random_uuid(),2026,90001,0,5,'has a profile','00000000-0000-4000-8000-0000000b0001','staff',NULL),
 (gen_random_uuid(),2026,90002,0,5,'no author',NULL,NULL,NULL),
 (gen_random_uuid(),2026,90003,0,5,'profile gone','00000000-0000-4000-8000-0000000b0009','staff',NULL),
 (gen_random_uuid(),2026,90004,0,5,'named already','00000000-0000-4000-8000-0000000b0002','staff','Name At The Change');
SQL
  cat "$scratch/backfill.sql"
  cat <<'SQL'

SELECT pg_temp.fill_assert((SELECT jsonb_object_agg(h.inv_no, h.changed_by_name) FROM public.invoice_discount_history h WHERE h.inv_no BETWEEN 90001 AND 90004)
 = '{"90001":"Backfill Present Author","90002":null,"90003":null,"90004":"Name At The Change"}'::jsonb,
 'names after the backfill: '||(SELECT jsonb_object_agg(h.inv_no, h.changed_by_name)::text FROM public.invoice_discount_history h WHERE h.inv_no BETWEEN 90001 AND 90004));
SELECT pg_temp.fill_assert((SELECT bool_and(t.tgenabled='O') AND count(*)=2 FROM pg_trigger t
  WHERE t.tgrelid='public.invoice_discount_history'::regclass AND NOT t.tgisinternal),'both guards of the history are switched on afterwards');
DO $$ BEGIN
  BEGIN
    UPDATE public.invoice_discount_history SET changed_by_name='rewritten' WHERE inv_no=90001;
    RAISE EXCEPTION 'history author backfill: a history row could be changed after the backfill';
  EXCEPTION WHEN insufficient_privilege THEN
    IF SQLERRM <> 'Invoice discount history cannot be changed' THEN RAISE; END IF;
  END;
END $$;
-- The profile is renamed afterwards; a second run leaves every row as it is.
UPDATE public.user_profiles SET name='Backfill Later Name' WHERE id='00000000-0000-4000-8000-0000000b0001';
SQL
  cat "$scratch/backfill.sql"
  cat <<'SQL'

SELECT pg_temp.fill_assert((SELECT jsonb_object_agg(h.inv_no, h.changed_by_name) FROM public.invoice_discount_history h WHERE h.inv_no BETWEEN 90001 AND 90004)
 = '{"90001":"Backfill Present Author","90002":null,"90003":null,"90004":"Name At The Change"}'::jsonb,'a second run changes nothing');
ROLLBACK;
SQL
} | docker exec -i -e PGPASSWORD "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1
echo "Migration 48's author-name backfill names the rows it can, keeps the others, and leaves the history append-only."
