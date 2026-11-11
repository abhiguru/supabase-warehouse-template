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
SUPPORT_ARG=''
LETTERHEAD_ARG=''
CENTRAL_ISSUER_ARG=''
CENTRAL_TRUST_ARG=''
CONFIG_ARGS=()
SMS_HOURLY=''
SMS_DAILY=''
INGRESS_ARG=''
BUNDLE_FILE=''
while (($#)); do
  case "$1" in
    --state-dir|--api-url|--app-url|--company|--provider-env|--admin-phone|--admin-name|--central-issuer|--central-jwks-url|--central-jwks-file|--central-local-code|--central-admin-trust|--alert-webhook-file|--sensor-webhook-file|--heartbeat-url-file|--support-link-file|--letterhead-file|--gateway-port|--db-memory|--ingress|--proxy-address|--proxy-header|--from-bundle)
      if (($# < 2)); then echo "Missing value for $1" >&2; exit 1; fi
      case "$1" in
        --state-dir) STATE="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --admin-phone) ADMIN_PHONE="$2" ;;
        --admin-name) ADMIN_NAME="$2" ;;
        --central-issuer) CENTRAL_ISSUER_ARG="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --central-admin-trust) CENTRAL_TRUST_ARG="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --from-bundle) BUNDLE_FILE="$2" ;;   # WH-146: the offline bundle (scripts/offline-bundle.sh); verified and loaded below
        --ingress) INGRESS_ARG="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --company) COMPANY_ARG="$2"; CONFIG_ARGS+=("$1" "$2") ;;
        --alert-webhook-file) ALERT_ARG="$2"; if [[ "$2" != ask ]]; then CONFIG_ARGS+=("$1" "$2"); fi ;;
        --support-link-file) SUPPORT_ARG="$2" ;;   # WH-159: file, ask or off; the gate below decides what configure gets
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
    --sms-hourly-ceiling|--sms-daily-ceiling)
      # The SMS spending ceilings live in the database (docs/OPERATOR_INSTALL.md, "SMS spending ceiling"): checked here, stored after the migrations.
      if (($# < 2)); then echo "Missing value for $1" >&2; exit 1; fi
      case "$1" in
        --sms-hourly-ceiling) SMS_HOURLY="$2" ;;
        --sms-daily-ceiling) SMS_DAILY="$2" ;;
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
# WH-146: how requests reach this installation. The option wins on a first install; a rerun or an upgrade passes none and the state decides.
INGRESS_NOW="$INGRESS_ARG"
if [[ -z "$INGRESS_NOW" && -f "$STATE/config/compose.env" ]]; then
  INGRESS_NOW="$(sed -n 's/^INGRESS=//p' "$STATE/config/compose.env" | head -n 1)"
fi
INGRESS_NOW="${INGRESS_NOW:-cloudflare-tunnel}"
LOCAL_ONLY=''
if [[ "$INGRESS_NOW" == local-only ]]; then
  LOCAL_ONLY=1
  # A local-only facility has no other protection than signed requests on the warehouse network: it must not start without them.
  if ! grep -q '^  lan-signer:' "$ROOT/docker/docker-compose.yml"; then
    echo 'Refusing: --ingress local-only needs the signed warehouse network (WH-133, the lan-signer service), and this release does not have it. Nothing was changed.' >&2
    exit 1
  fi
  if [[ -n "$SMS_HOURLY$SMS_DAILY" ]]; then echo 'Refusing: a local-only facility sends no SMS; leave out --sms-hourly-ceiling and --sms-daily-ceiling.' >&2; exit 1; fi
fi
# shellcheck source=scripts/require-node.sh
. "$ROOT/scripts/require-node.sh"
node "$ROOT/scripts/doctor.mjs" --host-preflight
# The offline bundle (WH-146): checked and unpacked before anything is changed. upgrade.sh opens it itself and passes it on in the environment.
# This checkout must be the bundle's own release (clone it from the bundle's source.bundle: docs/OPERATOR_INSTALL.md, "Local-only facility").
BUNDLE_DIR=''
if [[ -n "$BUNDLE_FILE" && -z "${WAREHOUSE_OFFLINE_BUNDLE:-}" ]]; then
  BUNDLE_DIR="$(dirname "$STATE")/.warehouse-bundle.$$"
  trap 'rm -rf -- "$BUNDLE_DIR"' EXIT
  bash "$ROOT/scripts/offline-bundle.sh" open "$BUNDLE_FILE" "$BUNDLE_DIR" || exit 1
  if [[ "$(bash "$ROOT/scripts/offline-bundle.sh" field "$BUNDLE_DIR" commit)" != "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" ]]; then
    echo 'Refusing: this checkout is not the commit of the bundle. Clone the source from the bundle (git clone --branch <release> source.bundle) and run its setup.sh. Nothing was changed.' >&2
    exit 1
  fi
  export WAREHOUSE_OFFLINE_BUNDLE="$BUNDLE_DIR"
fi
# The numbering rules given on the command line (scripts/numbering.mjs): a rule that is refused changes nothing. The database checks them again.
NUMBERING_VARS=()
for numbering in grn dispatch invoice; do
  given="${numbering^^}_NUMBERING"
  if [[ -n "${!given+x}" ]]; then
    rule="$(node "$ROOT/scripts/numbering.mjs" rule "$numbering" "${!given}")" || exit 1
    NUMBERING_VARS+=(-v "${numbering}_numbering=$rule")
  fi
done
# The SMS spending ceilings (WH-119): SMS sends an hour and a day (MSG91 requests) for the whole facility. Offered 60 and 300 on a new install
# (Enter accepts each); with no terminal, or with the option given, nothing is asked. A rerun or upgrade asks nothing and keeps what is
# stored (scripts/configure-sms-ceiling.sql decides what is stored; a value given here always replaces the stored one).
if [[ -z "$LOCAL_ONLY" && ! -d "$STATE/config" && ( -z "$SMS_HOURLY" || -z "$SMS_DAILY" ) && -t 0 && -t 1 ]]; then
  if [[ -z "$SMS_HOURLY" ]]; then
    read -r -p 'SMS sends this facility may make in one hour (Enter for 60): ' SMS_HOURLY || true
    SMS_HOURLY="${SMS_HOURLY:-60}"
  fi
  if [[ -z "$SMS_DAILY" ]]; then
    read -r -p 'SMS sends this facility may make in one day, 24 hours (Enter for 300): ' SMS_DAILY || true
    SMS_DAILY="${SMS_DAILY:-300}"
  fi
fi
if [[ -n "$SMS_HOURLY" && ! "$SMS_HOURLY" =~ ^[1-9][0-9]{0,5}$ ]]; then
  echo 'The hourly SMS ceiling (--sms-hourly-ceiling) must be a whole number from 1 to 999999.' >&2
  exit 1
fi
if [[ -n "$SMS_DAILY" && ! "$SMS_DAILY" =~ ^[1-9][0-9]{0,6}$ ]]; then
  echo 'The daily SMS ceiling (--sms-daily-ceiling) must be a whole number from 1 to 9999999.' >&2
  exit 1
fi
# The central sign-in trust question (WH-148): whenever --central-issuer names an issuer, setup needs the answer to one question, by
# --central-admin-trust yes|no or, on a terminal, by asking. The default is yes (today's rule for members); with no terminal and no
# flag setup uses yes and says so once. A rerun keeps the stored answer unless the flag is given, so nothing is asked when compose.env
# already holds one.
if [[ -n "$CENTRAL_ISSUER_ARG" && "$CENTRAL_ISSUER_ARG" != off && -z "$CENTRAL_TRUST_ARG" ]] \
   && ! grep -qE '^CENTRAL_ADMIN_TRUST=(yes|no)$' "$STATE/config/compose.env" 2>/dev/null; then
  TRUST_QUESTION="May a sign-in from $CENTRAL_ISSUER_ARG alone open this facility's administrator accounts? Yes: the association's sign-in is enough (today's rule for members). No: administrators must also enter a code this facility sends by SMS."
  if [[ -t 0 && -t 1 ]]; then
    while :; do
      read -r -p "$TRUST_QUESTION [yes/no, Enter for yes]: " CENTRAL_TRUST_ANSWER || CENTRAL_TRUST_ANSWER=''
      CENTRAL_TRUST_ANSWER="${CENTRAL_TRUST_ANSWER:-yes}"
      case "${CENTRAL_TRUST_ANSWER,,}" in
        yes|y) CENTRAL_TRUST_ARG=yes; break ;;
        no|n) CENTRAL_TRUST_ARG=no; break ;;
        *) echo 'Answer yes or no.' >&2 ;;
      esac
    done
  else
    CENTRAL_TRUST_ARG=yes
    echo "$TRUST_QUESTION" >&2
    echo 'No terminal and no --central-admin-trust: using yes. Rerun with --central-admin-trust no to change it.' >&2
  fi
  CONFIG_ARGS+=(--central-admin-trust "$CENTRAL_TRUST_ARG")
fi
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
trap 'rm -f "$WEBHOOK_TMP"; [[ -z "$BUNDLE_DIR" ]] || rm -rf -- "$BUNDLE_DIR"' EXIT
PROMPT_COMPANY="$COMPANY_ARG"
if [[ -z "$PROMPT_COMPANY" && -f "$STATE/public/instance.json" ]]; then
  PROMPT_COMPANY="$(node -e 'const fs=require("fs"); console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).companyName)' "$STATE/public/instance.json")"
fi
# A local-only facility has no Slack or any outside channel (WH-146): nothing is asked and none is stored; its alerts show in the app.
if [[ -z "$LOCAL_ONLY" ]]; then
  node "$ROOT/scripts/alert-webhook.mjs" gate --state-dir "$STATE" --company "${PROMPT_COMPANY:-this facility}" --given "$ALERT_ARG" --out "$WEBHOOK_TMP" || exit 1
elif [[ -n "$ALERT_ARG" && "$ALERT_ARG" != off ]]; then
  echo 'Refusing: a local-only facility has no outside alert channel; leave out --alert-webhook-file.' >&2; exit 1
fi
if [[ -s "$WEBHOOK_TMP" ]]; then
  CONFIG_ARGS+=(--alert-webhook-file "$WEBHOOK_TMP")
fi
# The support link (WH-159, docs/MONITORING.md, "The support link"): asked on a terminal when no answer is recorded yet (Enter means no; nothing is
# switched on without being asked), or with --support-link-file ask; --support-link-file <file> or off answers without asking. A local-only facility has no way out.
SUPPORT_TMP="$(umask 077; mktemp "${TMPDIR:-/tmp}/warehouse-support-link.XXXXXX")"
trap 'rm -f "$WEBHOOK_TMP" "$SUPPORT_TMP"; [[ -z "$BUNDLE_DIR" ]] || rm -rf -- "$BUNDLE_DIR"' EXIT
if [[ -z "$LOCAL_ONLY" ]]; then
  SUPPORT_RESULT="$(node "$ROOT/scripts/support-link.mjs" gate --state-dir "$STATE" --given "$SUPPORT_ARG" --out "$SUPPORT_TMP")" || exit 1
  case "$SUPPORT_RESULT" in
    given) CONFIG_ARGS+=(--support-link-file "$SUPPORT_ARG") ;;
    file) CONFIG_ARGS+=(--support-link-file "$SUPPORT_TMP") ;;
    off) CONFIG_ARGS+=(--support-link-file off) ;;
  esac
elif [[ -n "$SUPPORT_ARG" && "$SUPPORT_ARG" != off ]]; then
  echo 'Refusing: a local-only facility has no way out for a support link; leave out --support-link-file.' >&2; exit 1
fi
# The PDF letterhead (docs/OPERATOR_INSTALL.md, "Letterhead image (optional)"). Without --letterhead-file, a terminal is
# asked for the path of a JPEG or PNG (Enter means plain PDFs) on a fresh install; with no terminal setup refuses, so
# whoever runs it for the installer has to ask. A rerun without the option asks nothing and keeps what is there
# (`--letterhead-file ask` asks anyway). It runs after the webhook question, so after the host checks and the lock of an existing state, for the same reason.
# scripts/letterhead.mjs decides (and prints the refusal); the answer reaches configure.mjs through a temporary file.
LETTERHEAD_TMP="$(umask 077; mktemp "${TMPDIR:-/tmp}/warehouse-letterhead.XXXXXX")"
trap 'rm -f "$WEBHOOK_TMP" "$SUPPORT_TMP" "$LETTERHEAD_TMP"; [[ -z "$BUNDLE_DIR" ]] || rm -rf -- "$BUNDLE_DIR"' EXIT
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
# A release with signed images (docker/images-signed) is checked with cosign: install the pinned one into the state when the host has none.
# Not being able to is a warning; build-images.sh then builds the images here (unsigned) unless the operator accepted unsigned images.
if [[ -f "$ROOT/docker/images-signed" ]] && ! command -v cosign >/dev/null && [[ ! -x "$STATE/bin/cosign" ]]; then
  bash "$ROOT/scripts/install-cosign.sh" "$STATE" || echo 'Warning: cosign could not be installed, so the signatures of the release images cannot be checked (message above).' >&2
fi
if [[ -n "${WAREHOUSE_OFFLINE_BUNDLE:-}" && -z "${WAREHOUSE_OFFLINE_BUNDLE_LOADED:-}" ]]; then
  bash "$ROOT/scripts/offline-bundle.sh" load "$WAREHOUSE_OFFLINE_BUNDLE"
fi
bash "$ROOT/scripts/build-images.sh" --from-release
# A state that already has containers is about to have them recreated (an upgrade, or a rerun), and a recreated container starts with an
# empty log: keep the last 48 hours of each service first (best effort, redacted; <state>/diagnostics/pre-setup-*). A first install has none.
if [[ -n "$(bash "$ROOT/scripts/compose.sh" ps -a -q 2>/dev/null || true)" ]]; then
  node "$ROOT/scripts/service-diagnostics.mjs" save setup || true
fi
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
# facility also asks for its own SMS code at every sign-in (--central-local-code on; default off), and whether a central sign-in alone may
# open an administrator's profile (--central-admin-trust yes|no; default yes).
# The lines are read, never sourced; configure.mjs stores no quotes, spaces, $ or #.
CENTRAL_ISSUER_VALUE="$(sed -n 's/^CENTRAL_ISSUER=//p' "$STATE/config/compose.env" | head -n 1)"
CENTRAL_LOCAL_CODE_VALUE="$(sed -n 's/^CENTRAL_LOCAL_CODE=//p' "$STATE/config/compose.env" | head -n 1)"
CENTRAL_ADMIN_TRUST_VALUE="$(sed -n 's/^CENTRAL_ADMIN_TRUST=//p' "$STATE/config/compose.env" | head -n 1)"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v central_issuer="$CENTRAL_ISSUER_VALUE" -v central_local_code="$CENTRAL_LOCAL_CODE_VALUE" -v central_admin_trust="$CENTRAL_ADMIN_TRUST_VALUE" < "$ROOT/scripts/configure-central.sql"
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 < "$ROOT/scripts/configure-sms.sql"
# The way requests reach this installation (WH-146), for the pairing functions of migration 170.
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v ingress_mode="$INGRESS_NOW" < "$ROOT/scripts/configure-ingress.sql"
# The SMS spending ceilings: a given value is stored; a new install without one gets 60 an hour and 300 a day; a facility that already
# sent codes keeps what it has (scripts/configure-sms-ceiling.sql).
bash "$ROOT/scripts/compose.sh" exec -T db psql -X -q -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -v sms_hourly="$SMS_HOURLY" -v sms_daily="$SMS_DAILY" < "$ROOT/scripts/configure-sms-ceiling.sql"
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
if [[ -n "$LOCAL_ONLY" ]]; then
  # The warehouse network listener is this facility's only address (WH-146): it is turned on here, and a fault is a failure, not a warning.
  if ! grep -qx 'LAN_ENABLED=true' "$STATE/config/compose.env"; then
    bash "$ROOT/scripts/lan.sh" on auto || { echo 'The warehouse network listener could not be turned on, and a local-only facility has no other address. Fix the cause above and run this command again.' >&2; exit 1; }
  else
    bash "$ROOT/scripts/lan.sh" start
  fi
else
  bash "$ROOT/scripts/lan.sh" start || echo 'Warning: the LAN fallback was not started (message above). The public services are up.' >&2
fi
# Optional services (printing, sensors, pooler) are not part of that start; the LAN fallback was started by lan.sh above.
# Replace the running ones whose image or configuration changed.
bash "$ROOT/scripts/build-images.sh" --replace-optional || echo 'Warning: a running optional service was not replaced (message above). The core services are up.' >&2
# The neutral Android app from the offline bundle (WH-146) goes where the facility's own download page serves it (GET /app on the warehouse network).
if [[ -n "${WAREHOUSE_OFFLINE_BUNDLE:-}" && -n "$LOCAL_ONLY" ]]; then
  apk="$(bash "$ROOT/scripts/offline-bundle.sh" field "$WAREHOUSE_OFFLINE_BUNDLE" apk)"
  if [[ -n "$apk" ]]; then
    mkdir -p -- "$STATE/public/app"
    cp -- "$WAREHOUSE_OFFLINE_BUNDLE/$apk" "$STATE/public/app/neutral.apk.tmp"
    chmod 0644 -- "$STATE/public/app/neutral.apk.tmp"
    ( cd "$STATE/public/app" && sha256sum neutral.apk.tmp | sed 's/neutral.apk.tmp/neutral.apk/' > neutral.apk.sha256.tmp && chmod 0644 neutral.apk.sha256.tmp \
      && mv -f neutral.apk.tmp neutral.apk && mv -f neutral.apk.sha256.tmp neutral.apk.sha256 )
    chmod 0755 -- "$STATE/public/app"
    echo "The neutral app is served at /app on the warehouse network."
  else
    echo 'Note: the bundle has no neutral app, so the facility download page at /app has no file.' >&2
  fi
fi
# The edge functions (functions/, including functions/_shared/) are bind-mounted into the functions container and the edge
# runtime keeps the modules it has loaded, so a new checkout reaches neither through the `up` above (it recreates a container
# only when its definition changed) nor through the image: new SQL would run under old function code. Recreate the container on
# every run (a few seconds; --no-deps leaves the other services alone) so that the code on disk is the code that runs. Doing it
# here, not in upgrade.sh, means the release being moved to decides how, and a hand-made upgrade gets it too.
bash "$ROOT/scripts/compose.sh" up -d --force-recreate --no-deps --wait --wait-timeout 180 functions
# The sensor-webhook advice is printed once, at the end (sensor-notice), not also by this run.
export WAREHOUSE_SETUP_SENSOR_NOTICE=yes
node "$ROOT/scripts/doctor.mjs" --local
unset WAREHOUSE_SETUP_SENSOR_NOTICE
# The monitoring checker (scripts/watch.mjs: checks every 5 minutes, Slack alerts) and the daily backup and retention run
# from systemd timers (two: the checker's and the daily one). Installing a unit needs root, which setup never uses: like the
# tunnel service and the USB backup, the operator runs the printed command. They also run without a Slack webhook
# (--alert-webhook-file off): the checks and the daily backup still run, only the Slack posts are off.
echo
# hint prints the install command when the timer is missing and "refresh" when it runs another checkout.
WAREHOUSE_STATE_DIR="$STATE" bash "$ROOT/scripts/watch-timer.sh" hint || true
# A notice (not an error) when sensors are on and Slack alerts are on but no separate sensor webhook is stored.
if [[ -z "$LOCAL_ONLY" ]]; then node "$ROOT/scripts/alert-webhook.mjs" sensor-notice --state-dir "$STATE" || true; fi
if [[ -n "$LOCAL_ONLY" ]]; then
  echo 'Local-only facility is healthy on the warehouse network. There is no tunnel or public address to set up. Next: bash scripts/lan.sh status for the address, a reserved address in the router, a time source for the clock, and the USB backup (docs/OPERATOR_INSTALL.md, "Local-only facility").'
  exit 0
fi
echo 'Operator services are healthy on the local gateway. Configure the Cloudflare Tunnel connector and its DNS route (deploy/cloudflared-config.example.yml; scripts/tunnel.sh install-service writes the service), then run node scripts/doctor.mjs for external verification.'
