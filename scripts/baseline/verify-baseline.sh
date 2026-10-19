#!/usr/bin/env bash
# Proves that the baseline equals the chain: builds one database from the migration chain and one from the baseline
# (plus any migrations that come after it), compares them by catalog and seed-row hashes (catalog-diff.mjs) and exits 0
# only when nothing differs beyond scripts/baseline/allowed-differences.txt.
#
#   verify-baseline.sh [--baseline <file>] [--chain-root <dir>] [--baseline-image <ref>] [--chain-image <ref>]
#                      [--allow <file>] [--bootstrap <dir>] [--storage-image <ref>] [--chain-container <name>] [--keep]
#
#   (no options)  release mode: the baseline is migrations/00000000000000_baseline.sql of this checkout; the chain is
#                 the files of git tag migrations-pre-baseline, plus any migration newer than the baseline.
#   --baseline    trial mode: use this file as the only baseline migration (no later migrations), and the chain of
#                 this checkout (migrations/*.sql) as the chain.
#   --chain-root  a directory with a migrations/ folder to use as the chain instead.
#   --baseline-image / --chain-image  database images (default: the one tests/migrations.sh pins). For another image
#                 set DB_COMMAND if its server command differs (see lib.sh).
#   --bootstrap   postgres:17 mode: the baseline database is --baseline-image (a postgres:17 image) started with the
#                 init scripts in <dir> (docker/volumes/db of the new-image branch). The chain database stays on the
#                 OLD image (the chain only runs there). Storage runs against BOTH databases after their migrations,
#                 as setup.sh does, so storage.* compares like for like (on the facilities Storage 1.80.2 runs on the
#                 old image too); the two databases and Storage share a throwaway --internal network.
#   --storage-image  the Storage image (default: the pin in docker/storage/Dockerfile).
#   --chain-container  trial mode only: use this running chain database as A instead of building one (it is not
#                 removed), and compare seed rows unmasked: the baseline was dumped from it, so even ids and
#                 timestamps must match.
#   --keep        leave both containers running (names are printed).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
here="$(dirname "${BASH_SOURCE[0]}")"
baseline_file='' chain_root='' b_image="$DEFAULT_DB_IMAGE" c_image="$DEFAULT_DB_IMAGE" allow='' keep=false bootstrap='' storage_ref='' chain_given=''
while (($#)); do
  case "$1" in
    --baseline) baseline_file="$2"; shift 2 ;;
    --chain-root) chain_root="$2"; shift 2 ;;
    --baseline-image) b_image="$2"; shift 2 ;;
    --chain-image) c_image="$2"; shift 2 ;;
    --allow) allow="$2"; shift 2 ;;
    --bootstrap) bootstrap="$2"; shift 2 ;;
    --storage-image) storage_ref="$2"; shift 2 ;;
    --chain-container) chain_given="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
work=$(mktemp -d "${TMPDIR:-/tmp}/baseline-verify.XXXXXX")
chain_c='' base_c='' net=''
# Only containers and the network this run made are removed (a given --chain-container is never touched).
cleanup() {
  if [[ "$keep" == false ]]; then
    for c in $chain_c $base_c; do [[ "$c" == "$chain_given" ]] || docker rm -f -v "$c" >/dev/null 2>&1 || true; done
    [[ -z "$net" ]] || docker network rm "$net" >/dev/null 2>&1 || true
  else
    echo "Kept containers: $chain_c $base_c (network ${net:-none})" >&2
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# --- the chain root and the baseline root -------------------------------------------------------------------
baseline_name=00000000000000_baseline.sql
mkdir -p "$work/baseline/migrations" "$work/chain/migrations"
if [[ -n "$baseline_file" ]]; then
  cp "$baseline_file" "$work/baseline/migrations/$baseline_name"
  if [[ -z "$chain_root" ]]; then chain_root="$BASELINE_ROOT"; fi
  cp "$chain_root"/migrations/*.sql "$work/chain/migrations/"
else
  [[ -f "$BASELINE_ROOT/migrations/$baseline_name" ]] || { echo "No migrations/$baseline_name in this checkout (use --baseline <file> for a trial)." >&2; exit 2; }
  cp "$BASELINE_ROOT"/migrations/*.sql "$work/baseline/migrations/"
  if [[ -n "$chain_root" ]]; then
    cp "$chain_root"/migrations/*.sql "$work/chain/migrations/"
  else
    git -C "$BASELINE_ROOT" rev-parse --verify -q refs/tags/migrations-pre-baseline >/dev/null \
      || { echo 'Tag migrations-pre-baseline does not exist; create it before verifying (or pass --chain-root).' >&2; exit 2; }
    git -C "$BASELINE_ROOT" archive migrations-pre-baseline migrations | tar -x -C "$work/chain"
    # migrations that came after the baseline apply to both databases
    for f in "$BASELINE_ROOT"/migrations/*.sql; do
      n=$(basename "$f")
      if [[ "$n" != "$baseline_name" && ! -e "$work/chain/migrations/$n" ]]; then cp "$f" "$work/chain/migrations/"; fi
    done
  fi
fi
echo "Chain: $(ls "$work/chain/migrations" | wc -l) files; baseline side: $(ls "$work/baseline/migrations" | wc -l) file(s)" >&2

# --- the two databases --------------------------------------------------------------------------------------
image_kind=supabase
[[ -z "$bootstrap" ]] || image_kind=pg17
[[ -z "$chain_given" || "$image_kind" == supabase ]] || { echo '--chain-container works with the old image only (Storage needs the shared network)' >&2; exit 2; }
if [[ -n "$chain_given" ]]; then chain_c="$chain_given"; else chain_c=$(new_name chain); fi
base_c=$(new_name base)
if [[ "$image_kind" == pg17 ]]; then
  net=$(create_net)
  [[ -n "$storage_ref" ]] || storage_ref=$(storage_image)
fi
# psql prints the plan's progress; keep it in a log and show it only when a step fails.
log="$work/steps.log"
step() { "$@" >>"$log" 2>&1 || { echo "Step failed: $*" >&2; tail -40 "$log" >&2; exit 1; }; }
chain_net=()
[[ -z "$net" ]] || chain_net=(--net "$net")
[[ -n "$chain_given" ]] || step "$here/build-chain-db.sh" --image "$c_image" --root "$work/chain" --name "$chain_c" "${chain_net[@]}"
b_args=(--image "$b_image" --empty --name "$base_c")
[[ "$image_kind" == supabase ]] || b_args+=(--bootstrap "$bootstrap" --net "$net")
step "$here/build-chain-db.sh" "${b_args[@]}"
# The old image has default privileges in public that the new bootstrap does not: take them away before the baseline.
# On any other image the bootstrap must have none, or the baseline's explicit ACLs would be widened and this run would
# not notice (review M5).
if [[ "$image_kind" == supabase ]]; then
  step db_psql "$base_c" -f - < "$here/image-as-bootstrap.sql"
else
  [[ "$(db_psql "$base_c" -At -c 'SELECT count(*) FROM pg_default_acl')" = 0 ]] \
    || { echo 'The bootstrap defines default privileges (pg_default_acl is not empty); the baseline is written relative to the built-in defaults.' >&2; exit 1; }
fi
# A probe migration straight after the baseline (it sorts right behind 00000000000000_baseline.sql; same psql session) checks that the baseline's header leaked no setting:
# unqualified names must resolve, function bodies must be checked, triggers must fire (design 13, M2).
cat > "$work/baseline/migrations/00000000000000_leak_probe.sql" <<'PROBE'
DO $$ BEGIN
  IF current_setting('search_path') = '' THEN RAISE EXCEPTION 'The baseline left search_path empty'; END IF;
  IF current_setting('check_function_bodies') <> 'on' THEN RAISE EXCEPTION 'The baseline left check_function_bodies off'; END IF;
  IF current_setting('session_replication_role') <> 'origin' THEN RAISE EXCEPTION 'The baseline left session_replication_role changed'; END IF;
  IF current_setting('row_security') <> 'on' THEN RAISE EXCEPTION 'The baseline left row_security off'; END IF;
  IF EXISTS (SELECT 1 FROM pg_settings WHERE source = 'session') THEN
    RAISE EXCEPTION 'The baseline left session-level settings: %', (SELECT string_agg(name, ', ') FROM pg_settings WHERE source = 'session');
  END IF;
  PERFORM 1 FROM user_profiles LIMIT 1;
END $$;
PROBE
apply_plan() { plan_of "$work/baseline" | db_psql "$base_c"; }
step apply_plan
# Second pass: the runner must skip the unchanged baseline (ledger check) without error.
step apply_plan

# --- compare ------------------------------------------------------------------------------------------------
if [[ "$image_kind" == pg17 ]]; then
  # Production order (setup.sh): database up, migrations, then Storage builds its tables. Both sides, same Storage.
  step run_storage "$chain_c" "$net" "$storage_ref"
  step run_storage "$base_c" "$net" "$storage_ref"
fi
args=("$chain_c" "$base_c" --image "$image_kind")
[[ -z "$allow" ]] || args+=(--allow "$allow")
[[ -z "$chain_given" ]] || args+=(--unmasked)
node "$here/catalog-diff.mjs" "${args[@]}"
