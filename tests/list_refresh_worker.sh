#!/usr/bin/env bash
# Migration 91 (TW-BE-016, TW-BE-023) on committed data, with the real worker procedure. Runs only
# against migrations.sh's disposable container, after the configuration block seeded admin
# 919888888899 with a live operator session.
#   1. A committed dispatch is not listed until the worker runs; the worker runs as the runner role
#      over 127.0.0.1 without a password, as pg_cron does.
#   2. Lost-refresh races:
#      a. writer A holds its transaction open on a clean list: the worker does not wait for it and
#         lists nothing of it; A commits; the next run lists A's dispatch.
#      b. a list is dirty and writer B is still marking it: the worker waits for B, then lists B.
#      c. a mark arrives while the worker refreshes that list: the list stays dirty, and the next run
#         lists the late dispatch (a refresh never clears a mark it did not cover).
#   3. Five parallel dispatches under statement_timeout = 8s all commit; after one run the seven lists
#      equal their defining queries.
#   4. The pg_cron job alone lists a committed dispatch within the 15 s bound.
# The job is paused for 1-3 and resumed (by scripts/configure-list-refresh.sql) for 4 and on exit.
set -euo pipefail
container="${1:?disposable test container name required}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGPASSWORD=disposable-test-database-only
work="$(mktemp -d "${TMPDIR:-/tmp}/list-refresh-worker.XXXXXX")"
psql_exec() { docker exec -i -e PGPASSWORD "$container" psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 "$@"; }
value() { psql_exec -At "$@" | tail -n1; }
# The worker as pg_cron runs it: the runner role over 127.0.0.1 (trust inside the container), no password.
worker() { docker exec "$container" psql -X -q -h 127.0.0.1 -U warehouse_list_refresher -d postgres -v ON_ERROR_STOP=1 \
  -c 'CALL warehouse_security.refresh_dirty_lists_worker()'; }
resume_job() { psql_exec < "$ROOT/scripts/configure-list-refresh.sql" >/dev/null 2>&1 || true; }
cleanup() { status=$?; trap - EXIT; resume_job; rm -rf "$work"; exit "$status"; }
trap cleanup EXIT
fail() { echo "list_refresh_worker.sh: $*" >&2; exit 1; }
listed() { value -v no="$1" <<'SQL'
SELECT count(*) FROM public.mv_dispatch_list WHERE disp_no = :'no';
SQL
}
dirty() { value <<'SQL'
SELECT needs_refresh FROM public.mv_refresh_queue WHERE mv_name = 'mv_dispatch_list';
SQL
}
ms() { date +%s%3N; }
# Document numbers of this run (disp_no holds 8 characters; the script can run twice on one database).
run=$(openssl rand -hex 2)

claims=$(value <<'SQL'
SELECT jsonb_build_object('role','authenticated','sub',p.auth_user_id,'session_id',s.id)::text
FROM public.user_profiles p JOIN warehouse_security.refresh_sessions s ON s.user_id=p.auth_user_id
WHERE p.mobile='919888888899' AND s.expires_at>now() ORDER BY s.created_at DESC LIMIT 1;
SQL
)
[[ -n "$claims" ]] || fail 'needs the configuration admin session.'

# Pause the job and wait until no run is in progress, so that only this script runs the worker.
psql_exec -At >/dev/null <<'SQL'
SELECT cron.alter_job(jobid, active := false) FROM cron.job WHERE jobname = 'warehouse-list-refresh';
SQL
for ((i = 0; i < 40; i++)); do
  [[ "$(value -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'warehouse_list_refresher'")" = 0 ]] && break
  sleep 0.5
done
[[ "$(value -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'warehouse_list_refresher'")" = 0 ]] || fail 'a worker run did not finish.'

lot=$(value -v claims="$claims" -v grn_no="LW${run}" <<'SQL'
INSERT INTO public.customers(name,mobile) VALUES ('List Worker Customer','9888888876') ON CONFLICT DO NOTHING;
INSERT INTO public.items(name,packaging) VALUES ('List Worker Potatoes','Bag') ON CONFLICT DO NOTHING;
SELECT set_config('request.jwt.claims',:'claims',false);
SET ROLE authenticated;
SELECT (public.save_grn(p_gr_no=>:'grn_no',p_date=>now(),p_customer_id=>(SELECT id FROM public.customers WHERE name='List Worker Customer'),
  p_customer_name=>'List Worker Customer',p_items=>jsonb_build_array(jsonb_build_object(
  'item_id',(SELECT id FROM public.items WHERE name='List Worker Potatoes'),'item_name','List Worker Potatoes','packaging','Bag','qty',100,'weight',5)),
  p_idempotency_key=>'list-worker-receipt-'||:'grn_no'))->>'success';
RESET ROLE;
SELECT t.id FROM public.goodsreceived_trl t JOIN public.goodsreceived g ON g.id = t.gr_id WHERE g.gr_no = :'grn_no';
SQL
)
[[ "$lot" =~ ^[0-9a-f-]{36}$ ]] || fail "fixture lot missing: $lot"
# The SQL of one dispatch of one bag, as the administrator, under the app roles' 8 s statement timeout.
dispatch_sql() {
  cat <<SQL
SET statement_timeout = '8s';
SELECT set_config('request.jwt.claims','$claims',false);
SET ROLE authenticated;
SELECT public.create_dispatch_with_stock_check(jsonb_build_object('disp_no','$1','disp_date',now(),
  'customer_id',(SELECT id FROM public.customers WHERE name='List Worker Customer'),'customer_name','List Worker Customer',
  'supervisor_id',(SELECT id FROM public.user_profiles WHERE mobile='919888888899'),'supervisor_name','Configuration Test'),
  ARRAY[jsonb_build_object('gr_trl_id','$lot','disp_qty',1)],0,'list-worker-$1')->>'success';
SQL
}
dispatch() { dispatch_sql "$1" | psql_exec -At | tail -n1; }
worker
[[ "$(value -c "SELECT count(*) FROM public.mv_refresh_queue WHERE needs_refresh")" = 0 ]] || fail 'the queue is not clean after a run.'

# 1. Not listed until the worker runs.
[[ "$(dispatch "LWD0$run")" = true ]] || fail 'dispatch LWD0 failed.'
[[ "$(listed "LWD0$run")" = 0 && "$(dirty)" = t ]] || fail 'a committed dispatch was listed before the worker ran, or did not mark the list.'
worker
[[ "$(listed "LWD0$run")" = 1 && "$(value -c "SELECT count(*) FROM public.mv_refresh_queue WHERE needs_refresh")" = 0 ]] \
  || fail 'the worker did not list LWD0 or left the queue dirty.'
echo 'list refresh worker: a committed dispatch is listed only after the worker runs, as the runner role.'

# 2a. Writer A on a clean list, open across a worker run.
{ printf 'BEGIN;\n'; dispatch_sql "LWD1$run"; printf "SELECT pg_sleep(5);\nCOMMIT;\n"; } | psql_exec -At > "$work/a.out" &
holder=$!
sleep 1.5
started=$(ms); worker; took=$(( $(ms) - started ))
kill -0 "$holder" 2>/dev/null || fail 'writer A finished before the worker ran; the race was not exercised.'
(( took < 2500 )) || fail "the worker waited ${took} ms for a writer of a clean list."
[[ "$(listed "LWD1$run")" = 0 ]] || fail 'an uncommitted dispatch was listed.'
wait "$holder" || fail 'writer A failed.'
grep -qx true "$work/a.out" || fail "writer A's dispatch failed: $(cat "$work/a.out")"
[[ "$(dirty)" = t ]] || fail "writer A's mark was lost when it committed after the worker's run."
worker
[[ "$(listed "LWD1$run")" = 1 ]] || fail "the next run did not list writer A's dispatch."
echo "list refresh worker: race a: the worker did not wait for an open writer (${took} ms), and listed it on the next run."

# 2b. A dirty list and writer B still marking it: the worker waits for B and covers it.
[[ "$(dispatch "LWD2$run")" = true ]] || fail 'dispatch LWD2 failed.'
{ printf 'BEGIN;\n'; dispatch_sql "LWD3$run"; printf "SELECT pg_sleep(4);\nCOMMIT;\n"; } | psql_exec -At > "$work/b.out" &
holder=$!
sleep 1
worker > "$work/worker-b.out" 2>&1 &
runner=$!
sleep 1.5
waiting=$(value -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'warehouse_list_refresher' AND wait_event_type = 'Lock'")
[[ "$waiting" = 1 ]] || fail "the worker did not wait for writer B (sessions waiting on a lock: $waiting)."
wait "$holder" || fail 'writer B failed.'
wait "$runner" || fail "the worker failed: $(cat "$work/worker-b.out")"
[[ "$(listed "LWD2$run")" = 1 && "$(listed "LWD3$run")" = 1 && "$(dirty)" = f ]] || fail 'the worker run that waited for writer B did not list both dispatches.'
echo 'list refresh worker: race b: the worker waited for the writer still marking a dirty list, then listed it.'

# 2c. A mark while the worker refreshes mv_dispatch_list (held back: another session holds the view's
#     refresh lock, which LOCK TABLE cannot take on a materialized view).
[[ "$(dispatch "LWD4$run")" = true ]] || fail 'dispatch LWD4 failed.'
claimed=$(value -c "SELECT mark_seq FROM public.mv_refresh_queue WHERE mv_name = 'mv_dispatch_list'")
psql_exec -At <<'SQL' > /dev/null &
BEGIN;
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_dispatch_list;
SELECT pg_sleep(4);
COMMIT;
SQL
holder=$!
sleep 0.5
worker > "$work/worker-c.out" 2>&1 &
runner=$!
for ((i = 0; i < 20; i++)); do
  [[ "$(value -c "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid WHERE a.usename = 'warehouse_list_refresher' AND NOT l.granted AND l.relation = 'public.mv_dispatch_list'::regclass")" = 1 ]] && break
  sleep 0.2
done
(( i < 20 )) || fail 'the worker did not reach the refresh of mv_dispatch_list.'
[[ "$(dispatch "LWD5$run")" = true ]] || fail 'dispatch LWD5 (during the refresh) failed.'
wait "$holder"; wait "$runner" || fail "the worker failed: $(cat "$work/worker-c.out")"
[[ "$(listed "LWD4$run")" = 1 ]] || fail 'the held-back refresh did not list LWD4.'
late_listed=$(listed "LWD5$run")
[[ "$(dirty)" = t && "$(value -c "SELECT mark_seq > $claimed FROM public.mv_refresh_queue WHERE mv_name = 'mv_dispatch_list'")" = t ]] \
  || fail "a mark that arrived during the refresh was cleared (LWD5 listed by that refresh: $late_listed)."
worker
[[ "$(listed "LWD5$run")" = 1 && "$(dirty)" = f ]] || fail 'the next run did not list the dispatch committed during the refresh.'
echo "list refresh worker: race c: a mark during the refresh kept the list dirty (late dispatch in that refresh: $late_listed), the next run listed it."

# 3. Five parallel dispatches under the 8 s statement timeout.
pids=()
for n in 1 2 3 4 5; do
  ( started=$(ms); result=$(dispatch "LWP$n$run" 2>&1 || true); echo "$result $(( $(ms) - started ))" > "$work/p$n.out" ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done
for n in 1 2 3 4 5; do
  read -r result took < "$work/p$n.out" || true
  [[ "$result" = true ]] || fail "parallel dispatch LWP$n did not commit: $(cat "$work/p$n.out")"
  echo "list refresh worker: parallel dispatch LWP$n committed in ${took} ms."
done
worker
[[ "$(value -c "SELECT count(*) FROM public.mv_dispatch_list WHERE disp_no LIKE 'LWP_$run'")" = 5 ]] || fail 'the five parallel dispatches are not all listed after one run.'
diff=$(value <<'SQL'
CREATE FUNCTION pg_temp.view_diff(view_name text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE def text; cols text; n bigint;
BEGIN
  def := rtrim(btrim(pg_get_viewdef(('public.'||view_name)::regclass)), ';');
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum) INTO cols FROM pg_attribute a
   WHERE a.attrelid = ('public.'||view_name)::regclass AND a.attnum > 0 AND NOT a.attisdropped AND a.attname <> 'last_refreshed';
  EXECUTE format('SELECT (SELECT count(*) FROM (SELECT %1$s FROM public.%2$I EXCEPT ALL SELECT %1$s FROM (%3$s) d) a)
    + (SELECT count(*) FROM (SELECT %1$s FROM (%3$s) d EXCEPT ALL SELECT %1$s FROM public.%2$I) b)', cols, view_name, def) INTO n;
  RETURN n;
END $$;
SELECT string_agg(v || '=' || pg_temp.view_diff(v), ',' ORDER BY v) FROM unnest(warehouse_security.list_refresh_views()) v;
SQL
)
[[ "$diff" =~ ^(mv_[a-z_]+=0,){6}mv_[a-z_]+=0$ ]] || fail "a list differs from its defining query after one run: $diff"
[[ "$(value -c "SELECT count(*) FROM public.mv_refresh_queue WHERE needs_refresh OR last_error_code IS NOT NULL")" = 0 ]] || fail 'the queue is not clean after the parallel dispatches.'
echo 'list refresh worker: five parallel dispatches committed under statement_timeout 8s; all seven lists equal their definitions after one run.'

# 4. The pg_cron job alone, within the bound.
psql_exec < "$ROOT/scripts/configure-list-refresh.sql"
[[ "$(dispatch "LWC1$run")" = true ]] || fail 'dispatch LWC1 failed.'
committed=$(ms)
for ((i = 0; i < 60; i++)); do
  [[ "$(listed "LWC1$run")" = 1 ]] && break
  sleep 0.5
done
delay=$(( $(ms) - committed ))
[[ "$(listed "LWC1$run")" = 1 ]] || fail 'the pg_cron job did not list a committed dispatch within 30 s.'
(( delay <= 15000 )) || fail "the pg_cron job listed a committed dispatch after ${delay} ms, beyond the 15 s bound."
[[ "$(value -c "SELECT count(*) FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid WHERE j.jobname = 'warehouse-list-refresh' AND d.username = 'warehouse_list_refresher' AND d.status = 'succeeded'")" -ge 1 ]] \
  || fail 'no succeeded run of the job as the runner role is recorded.'
echo "list refresh worker: the pg_cron job listed a committed dispatch after ${delay} ms (bound 15 s)."
