#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An update (git pull) writes files with the caller's umask; restore the modes of a
# umask 022 clone so the containers can read them and the root-run helpers accept them.
bash "$ROOT/scripts/checkout-permissions.sh" --quiet
bash "$ROOT/scripts/check-readiness.sh" "${1:-}"
shift
STATE=''
ADMIN_PHONE=''
ADMIN_NAME=''
COMPANY_ARG=''
ALERT_ARG=''
CONFIG_ARGS=()
while (($#)); do
  case "$1" in
    --state-dir|--api-url|--app-url|--company|--provider-env|--admin-phone|--admin-name|--central-issuer|--central-jwks-url|--central-jwks-file|--central-local-code|--alert-webhook-file|--gateway-port)
      if (($# < 2)); then echo "Missing value for $1" >&2; exit 1; fi
      case "$1" in
        --state-dir) STATE="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --admin-phone) ADMIN_PHONE="$2" ;;
        --admin-name) ADMIN_NAME="$2" ;;
        --company) COMPANY_ARG="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --alert-webhook-file) ALERT_ARG="$2"; if [[ "$2" != ask ]]; then CONFIG_ARGS+=("$1" "$2"); fi ;;
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
if [[ "$(realpath -m "$STATE")" != "$(realpath -ms "$STATE")" ]]; then
  echo 'State directory path must not use a symlink.' >&2
  exit 1
fi
STATE="$(realpath -ms "$STATE")"
export WAREHOUSE_STATE_DIR="$STATE"
node "$ROOT/scripts/doctor.mjs" --host-preflight
# A rerun may rewrite compose.env (provider replacement), so hold the operator
# lock before configure.mjs whenever the state already exists; a first install
# can only take it once configure.mjs has created the state directory.
LOCKED=''
if [[ -d "$STATE/config" ]]; then
  exec 9>"$STATE/config/operator.lock"
  if ! flock -n 9; then echo 'Another operator setup, start, stop, backup, restore or key rotation is running for this state.' >&2; exit 1; fi
  LOCKED=1
fi
# Alerts go to the facility's own Slack channel (docs/MONITORING.md, "Alert delivery"). Without
# --alert-webhook-file, a terminal is asked for the webhook URL (typed without echo, passed to
# configure.mjs through a private temporary file that is deleted when setup ends); with no terminal setup
# refuses. A rerun that already has a stored URL asks nothing (`--alert-webhook-file ask` asks anyway and
# replaces it). `off` is for a non-production install. It runs after the host checks and after the lock is held,
# so nothing is asked of an operator whose install would be refused anyway.
# scripts/alert-webhook.mjs decides (and prints the refusal or the warning).
WEBHOOK_TMP="$(umask 077; mktemp "${TMPDIR:-/tmp}/warehouse-slack-webhook.XXXXXX")"
trap 'rm -f "$WEBHOOK_TMP"' EXIT
PROMPT_COMPANY="$COMPANY_ARG"
if [[ -z "$PROMPT_COMPANY" && -f "$STATE/public/instance.json" ]]; then
  PROMPT_COMPANY="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).companyName)' "$STATE/public/instance.json")"
fi
node "$ROOT/scripts/alert-webhook.mjs" gate --state-dir "$STATE" --company "${PROMPT_COMPANY:-this facility}" --given "$ALERT_ARG" --out "$WEBHOOK_TMP" || exit 1
if [[ -s "$WEBHOOK_TMP" ]]; then
  CONFIG_ARGS+=(--alert-webhook-file "$WEBHOOK_TMP")
fi
node "$ROOT/scripts/configure.mjs" "${CONFIG_ARGS[@]}"
rm -f "$WEBHOOK_TMP"
if [[ -z "$LOCKED" ]]; then
  exec 9>"$STATE/config/operator.lock"
  if ! flock -n 9; then echo 'Another operator setup, start, stop, backup, restore or key rotation is running for this state.' >&2; exit 1; fi
fi
node "$ROOT/scripts/doctor.mjs" --preflight
bash "$ROOT/scripts/compose.sh" config --quiet
# Before anything is changed: Docker must be able to allocate the subnet of the internal renderer network.
bash "$ROOT/scripts/network-preflight.sh"
# `up` builds only a missing image. Rebuild those whose recipes changed, so that
# an upgraded checkout does not keep the images of the first installation.
bash "$ROOT/scripts/build-images.sh"
# Release 105 runs the db with wal_level=replica, which refuses to start while a logical slot exists: drop idle ones
# (and refuse if one is in use) while the db still runs with its old settings.
bash "$ROOT/scripts/drop-logical-slots.sh"
# --remove-orphans stops the old realtime container before migration 105 drops its schemas.
bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180 db
bash "$ROOT/scripts/migrate.sh" --operator
# Every service login has its own password (docs/CONTAINER_SECURITY.md, "Database
# passwords"). docker/volumes/db/roles.sql sets them only on an empty data directory;
# this sets them on every run, so an upgraded installation gets them here. Running
# services keep their open connections until the start below recreates them.
bash "$ROOT/scripts/db-roles.sh" apply
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-auth.sql"
# Central sign-in: the trusted issuer from compose.env (--central-issuer), or off, and whether this
# facility also asks for its own SMS code at every sign-in (--central-local-code on; default off).
# The lines are read, never sourced; configure.mjs stores no quotes, spaces, $ or #.
CENTRAL_ISSUER_VALUE="$(sed -n 's/^CENTRAL_ISSUER=//p' "$STATE/config/compose.env" | head -n 1)"
CENTRAL_LOCAL_CODE_VALUE="$(sed -n 's/^CENTRAL_LOCAL_CODE=//p' "$STATE/config/compose.env" | head -n 1)"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v central_issuer="$CENTRAL_ISSUER_VALUE" -v central_local_code="$CENTRAL_LOCAL_CODE_VALUE" < "$ROOT/scripts/configure-central.sql"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-sms.sql"
# Storage owns its schema upgrades; wait for them before creating private buckets
# and access policies. This starts only storage and its internal dependencies.
bash "$ROOT/scripts/compose.sh" up -d --wait --wait-timeout 180 storage
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-storage.sql"
EXISTING_ADMIN="$(bash "$ROOT/scripts/compose.sh" exec -T db psql -X -A -t -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -c "SELECT warehouse_security.installer_admin_state('$ADMIN_PHONE')")"
if [[ "$EXISTING_ADMIN" == none ]]; then
  bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v phone="$ADMIN_PHONE" -v name="$ADMIN_NAME" < "$ROOT/scripts/bootstrap-admin.sql"
elif [[ "$EXISTING_ADMIN" != match ]]; then
  echo 'An admin already exists with a different phone; setup cannot replace it.' >&2
  exit 1
fi
COMPANY="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).companyName)' "$STATE/public/instance.json")"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v company="$COMPANY" < "$ROOT/scripts/configure-operator.sql"
# --remove-orphans also removes the containers of services that were removed from the Compose file (see CHANGELOG.md).
# Services of a profile (printing, sensors, pooler) are disabled services, not
# orphans, so they are kept.
bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180
# Optional services (printing, sensors, pooler) are not part of that start.
# Replace the running ones whose image or configuration changed.
bash "$ROOT/scripts/build-images.sh" --replace-optional || echo 'Warning: a running optional service was not replaced (message above). The core services are up.' >&2
node "$ROOT/scripts/doctor.mjs" --local
# The monitoring checker (scripts/watch.mjs: checks every 5 minutes, Slack alerts, the daily backup and retention) runs
# from a systemd timer. Installing a unit needs root, which setup never uses: like the tunnel service and the USB backup,
# the operator runs the printed command. It also runs without a Slack webhook (--alert-webhook-file off): the checks
# and the daily backup still run, only the Slack posts are off.
echo
# hint prints the install command when the timer is missing and "refresh" when it runs another checkout.
WAREHOUSE_STATE_DIR="$STATE" bash "$ROOT/scripts/watch-timer.sh" hint || true
echo 'Operator services are healthy on the local gateway. Configure the Cloudflare Tunnel connector and its DNS route (deploy/cloudflared-config.example.yml; scripts/tunnel.sh install-service writes the service), then run node scripts/doctor.mjs for external verification.'
