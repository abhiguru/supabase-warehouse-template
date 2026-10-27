#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An update (git pull) writes files with the caller's umask; restore the modes of a
# umask 022 clone so the containers can read them and the root-run helpers accept them.
bash "$ROOT/scripts/checkout-permissions.sh" --quiet
# The host prerequisites (Linux x86-64, node, npm, openssl, flock, docker compose) are checked by
# `doctor.mjs --host-preflight` below, once the state directory is known.
if [[ "${1:-}" != --operator ]]; then
  echo 'Use ./setup.sh --operator with an explicitly selected state directory. Demo installation is no longer supported.' >&2
  exit 1
fi
shift
# shellcheck source=scripts/operator-lock.sh
. "$ROOT/scripts/operator-lock.sh"
STATE=''
ADMIN_PHONE=''
ADMIN_NAME=''
COMPANY_ARG=''
ALERT_ARG=''
LETTERHEAD_ARG=''
CONFIG_ARGS=()
while (($#)); do
  case "$1" in
    --state-dir|--api-url|--app-url|--company|--provider-env|--admin-phone|--admin-name|--central-issuer|--central-jwks-url|--central-jwks-file|--central-local-code|--alert-webhook-file|--letterhead-file|--gateway-port)
      if (($# < 2)); then echo "Missing value for $1" >&2; exit 1; fi
      case "$1" in
        --state-dir) STATE="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --admin-phone) ADMIN_PHONE="$2" ;;
        --admin-name) ADMIN_NAME="$2" ;;
        --company) COMPANY_ARG="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --alert-webhook-file) ALERT_ARG="$2"; if [[ "$2" != ask ]]; then CONFIG_ARGS+=("$1" "$2"); fi ;;
        --letterhead-file) LETTERHEAD_ARG="$2"; if [[ "$2" != ask ]]; then CONFIG_ARGS+=("$1" "$2"); fi ;;
        *) CONFIG_ARGS+=("$1" "$2") ;;
      esac
      shift 2 ;;
    --grn-numbering|--dispatch-numbering|--invoice-numbering)
      # The numbering rules live in the database (docs/OPERATOR_INSTALL.md, "Document numbers"): checked below, stored after the migrations.
      if (($# < 2)); then echo "Missing value for $1" >&2; exit 1; fi
      case "$1" in
        --grn-numbering) GRN_NUMBERING="$2" ;;
        --dispatch-numbering) DISPATCH_NUMBERING="$2" ;;
        --invoice-numbering) INVOICE_NUMBERING="$2" ;;
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
# shellcheck source=scripts/require-node.sh
. "$ROOT/scripts/require-node.sh"
node "$ROOT/scripts/doctor.mjs" --host-preflight
# The numbering rules given on the command line (scripts/numbering.mjs): a rule that is refused changes nothing. The database checks them again.
NUMBERING_VARS=()
for numbering in grn dispatch invoice; do
  given="${numbering^^}_NUMBERING"
  if [[ -n "${!given+x}" ]]; then
    rule="$(node "$ROOT/scripts/numbering.mjs" rule "$numbering" "${!given}")" || exit 1
    NUMBERING_VARS+=(-v "${numbering}_numbering=$rule")
  fi
done
# A rerun may rewrite compose.env (provider replacement), so hold the operator
# lock before configure.mjs whenever the state already exists; a first install
# can only take it once configure.mjs has created the state directory.
LOCKED=''
if [[ -d "$STATE/config" ]]; then
  # upgrade.sh holds the lock for its whole run and runs this script as one step: the inherited lock counts.
  operator_lock_or_inherited "$STATE"
  LOCKED=1
fi
# An existing installation of the earlier PostgreSQL 15 release is refused here, before configure.mjs rewrites its
# compose.env (a refusal then changes no file at all). Only a refusal counts: when the check cannot run yet (the Compose
# configuration of an older state may not resolve), the same check below decides, after configure.mjs.
if [[ -n "$LOCKED" && -f "$STATE/config/compose.env" ]]; then
  if ! early="$(bash "$ROOT/scripts/db-version-preflight.sh" 2>&1)" && [[ "$early" == Refusing:* ]]; then
    echo "$early" >&2
    exit 1
  fi
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
# The PDF letterhead (docs/OPERATOR_INSTALL.md, "Letterhead image (optional)"). Without --letterhead-file, a terminal is
# asked for the path of a JPEG or PNG (Enter means plain PDFs) on a fresh install; with no terminal setup refuses, so
# whoever runs it for the installer has to ask. A rerun without the option asks nothing and keeps what is there
# (`--letterhead-file ask` asks anyway). It runs after the webhook question, so after the host checks and the lock of an existing state, for the same reason.
# scripts/letterhead.mjs decides (and prints the refusal); the answer reaches configure.mjs through a temporary file.
LETTERHEAD_TMP="$(umask 077; mktemp "${TMPDIR:-/tmp}/warehouse-letterhead.XXXXXX")"
trap 'rm -f "$WEBHOOK_TMP" "$LETTERHEAD_TMP"' EXIT
node "$ROOT/scripts/letterhead.mjs" gate --state-dir "$STATE" --company "${PROMPT_COMPANY:-this facility}" --given "$LETTERHEAD_ARG" --out "$LETTERHEAD_TMP" || exit 1
if [[ -s "$LETTERHEAD_TMP" ]]; then
  CONFIG_ARGS+=(--letterhead-file "$(<"$LETTERHEAD_TMP")")
fi
node "$ROOT/scripts/configure.mjs" "${CONFIG_ARGS[@]}"
rm -f "$WEBHOOK_TMP" "$LETTERHEAD_TMP"
if [[ -z "$LOCKED" ]]; then
  operator_lock_or_inherited "$STATE"
fi
node "$ROOT/scripts/doctor.mjs" --preflight
bash "$ROOT/scripts/compose.sh" config --quiet
# Before anything is changed: Docker must be able to allocate the subnet of the internal renderer network.
bash "$ROOT/scripts/network-preflight.sh"
# Before the image is rebuilt or the db container recreated: a PostgreSQL 15 database must go through the baseline reload.
bash "$ROOT/scripts/db-version-preflight.sh"
# `up` builds only a missing image. Rebuild those whose recipes changed, so that
# an upgraded checkout does not keep the images of the first installation. A checkout at a release tag pulls the images the
# release workflow built and scanned (by digest) where the recipe is the released one, and builds the rest here.
bash "$ROOT/scripts/build-images.sh" --from-release
# Setup brings the stack up: the boot unit and the checker's self-healing may act again (stop.sh wrote this file).
rm -f -- "$STATE/config/stopped-by-operator"
# --remove-orphans stops the old realtime container before the baseline reload's cluster replaces the old one.
bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180 db
bash "$ROOT/scripts/migrate.sh" --operator
# What this backend tells the app about itself (get-public-config): the release, the commit, the newest applied migration, and the oldest
# app build it answers (app-compat.json). Written on every run, after the migrations, so they describe the code that now runs.
WAREHOUSE_STATE_DIR="$STATE" bash "$ROOT/scripts/release-info.sh"
# The pooler is off unless it was turned on (bash scripts/pooler.sh on). An installation made before it had a switch is
# decided once here: a supavisor container means it is in use; otherwise its unused role, schema and empty _supabase
# database and its secrets are removed. If the pooler was used (the database holds data), the clean-up refuses, changes
# nothing and setup goes on.
bash "$ROOT/scripts/pooler.sh" cleanup || echo 'Warning: the pooler clean-up did not run (message above). Setup goes on; nothing was changed.' >&2
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
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v company="$COMPANY" ${NUMBERING_VARS[@]+"${NUMBERING_VARS[@]}"} < "$ROOT/scripts/configure-operator.sql"
# --remove-orphans also removes the containers of services that were removed from the Compose file (see CHANGELOG.md).
# Services of a profile (printing, sensors, pooler) are disabled services, not
# orphans, so they are kept.
# The LAN fallback (gateway-lan) is left out of this start (WAREHOUSE_COMPOSE_WITHOUT_LAN, scripts/compose.sh): a fault of the fallback never
# stops a setup or an upgrade, so this waits for the public services only, and lan.sh starts gateway-lan on its own, where a fault is a warning.
WAREHOUSE_COMPOSE_WITHOUT_LAN=1 bash "$ROOT/scripts/compose.sh" up -d --remove-orphans --wait --wait-timeout 180
bash "$ROOT/scripts/lan.sh" start || echo 'Warning: the LAN fallback was not started (message above). The public services are up.' >&2
# Optional services (printing, sensors, pooler) are not part of that start; the LAN fallback was started by lan.sh above.
# Replace the running ones whose image or configuration changed.
bash "$ROOT/scripts/build-images.sh" --replace-optional || echo 'Warning: a running optional service was not replaced (message above). The core services are up.' >&2
# The edge functions (functions/, including functions/_shared/) are bind-mounted into the functions container and the edge
# runtime keeps the modules it has loaded, so a new checkout reaches neither through the `up` above (it recreates a container
# only when its definition changed) nor through the image: new SQL would run under old function code. Recreate the container on
# every run (a few seconds; --no-deps leaves the other services alone) so that the code on disk is the code that runs. Doing it
# here, not in upgrade.sh, means the release being moved to decides how, and a hand-made upgrade gets it too.
bash "$ROOT/scripts/compose.sh" up -d --force-recreate --no-deps --wait --wait-timeout 180 functions
node "$ROOT/scripts/doctor.mjs" --local
# The monitoring checker (scripts/watch.mjs: checks every 5 minutes, Slack alerts) and the daily backup and retention run
# from systemd timers (two: the checker's and the daily one). Installing a unit needs root, which setup never uses: like the
# tunnel service and the USB backup, the operator runs the printed command. They also run without a Slack webhook
# (--alert-webhook-file off): the checks and the daily backup still run, only the Slack posts are off.
echo
# hint prints the install command when the timer is missing and "refresh" when it runs another checkout.
WAREHOUSE_STATE_DIR="$STATE" bash "$ROOT/scripts/watch-timer.sh" hint || true
echo 'Operator services are healthy on the local gateway. Configure the Cloudflare Tunnel connector and its DNS route (deploy/cloudflared-config.example.yml; scripts/tunnel.sh install-service writes the service), then run node scripts/doctor.mjs for external verification.'
