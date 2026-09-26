#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$ROOT/scripts/check-readiness.sh" "${1:-}"
shift
STATE=''
ADMIN_PHONE=''
ADMIN_NAME=''
CONFIG_ARGS=()
while (($#)); do
  case "$1" in
    --state-dir|--api-url|--app-url|--company|--provider-env|--admin-phone|--admin-name)
      if (($# < 2)); then echo "Missing value for $1" >&2; exit 1; fi
      case "$1" in
        --state-dir) STATE="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --admin-phone) ADMIN_PHONE="$2" ;;
        --admin-name) ADMIN_NAME="$2" ;;
        *) CONFIG_ARGS+=("$1" "$2") ;;
      esac
      shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
if [[ "$STATE" != /* || ! "$ADMIN_PHONE" =~ ^91[0-9]{10}$ || -z "$ADMIN_NAME" ]]; then
  echo 'Required: --state-dir ABSOLUTE --admin-phone 91XXXXXXXXXX --admin-name NAME.' >&2
  exit 1
fi
STATE="$(realpath -m "$STATE")"
export WAREHOUSE_STATE_DIR="$STATE"
node "$ROOT/scripts/doctor.mjs" --host-preflight
node "$ROOT/scripts/configure.mjs" "${CONFIG_ARGS[@]}"
node "$ROOT/scripts/doctor.mjs" --preflight
bash "$ROOT/scripts/compose.sh" config --quiet
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180 db
bash "$ROOT/scripts/migrate.sh" --operator
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-auth.sql"
# Storage owns its schema upgrades; wait for them before creating private buckets
# and access policies. This starts only storage and its internal dependencies.
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180 storage
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-storage.sql"
EXISTING_ADMIN="$(bash "$ROOT/scripts/compose.sh" exec -T db psql -X -A -t -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c "SELECT COALESCE((SELECT mobile FROM public.user_profiles WHERE role='admin' LIMIT 1), '')")"
if [[ -z "$EXISTING_ADMIN" ]]; then
  bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v phone="$ADMIN_PHONE" -v name="$ADMIN_NAME" < "$ROOT/scripts/bootstrap-admin.sql"
elif [[ "$EXISTING_ADMIN" != "$ADMIN_PHONE" ]]; then
  echo 'An admin already exists with a different phone; setup cannot replace it.' >&2
  exit 1
fi
COMPANY="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).companyName)' "$STATE/public/instance.json")"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v company="$COMPANY" < "$ROOT/scripts/configure-operator.sql"
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180
node "$ROOT/scripts/doctor.mjs" --local
echo 'Operator services are healthy on the local gateway. Configure HTTPS reverse proxy and DNS, then run node scripts/doctor.mjs for external verification.'
