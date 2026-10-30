#!/usr/bin/env bash
# One command to move an installed facility to a tagged release (docs/OPERATOR_INSTALL.md, "Rerun and upgrade").
#
#   export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
#   bash upgrade.sh [--dry-run] [--yes] vX.Y.Z [-- SETUP_OPTION VALUE ...]
#   bash upgrade.sh [--dry-run] [--yes] --ref COMMIT_OR_BRANCH    (tests and development only; no support)
#
# Under the operator lock, from start to end:
#   0. run scripts/upgrade-preflight.sh of the NEW release (read out of its commit with `git archive`): it prints the operator
#      actions of CHANGELOG.md for the whole span (and, when there are some, standard input is a terminal and --yes was not given,
#      waits for Enter: the moment to do what says "before"), checks the host minimums and the oldest release it accepts an upgrade
#      from, and checks that the way back would fit on the disk. It may refuse; nothing has been changed then. A release from before
#      the preflight has none, and only the checks of this script are made
#   1. close the API to phones (scripts/maintenance.sh on: both gateways answer 503 "upgrading", so nothing is written from here until step 3
#      has finished), back up (scripts/backup.sh) and prove the backup restores (scripts/verify-restore.sh), on the OLD release; the verified
#      backup goes on config/backups-verified.list (scripts/watch.mjs record-verified), so the daily pruning treats it like a nightly one
#   2. tag the images the running services use as <project>-<service>:pre-<old release> (scripts/pre-images.sh; the way back puts
#      them back instead of building them again), fetch the tags and check the tag out (detached HEAD, the same as the "Major
#      PostgreSQL upgrade" procedure)
#   3. rerun `setup.sh --operator` of the NEW release with this installation's own values. Setup also recreates the
#      `functions` container (its code is bind-mounted and the edge runtime keeps what it loaded) and ends with
#      `doctor --local`: everything that depends on the release being moved to lives in that release's setup.sh,
#      because from the checkout on, this script is the OLD release's, still running from memory
#      then open the API again (scripts/maintenance.sh off, of the new release, which also runs the health check)
#   4. print what CHANGELOG.md asks of the operator between the old and the new release
#   5. append one line to $WAREHOUSE_STATE_DIR/config/upgrades.log, and drop the pre-* image tags of earlier upgrades
#
# Before anything is changed it refuses: running as root, a dirty working tree, untracked files the release would overwrite, a name
# that is not a release tag on origin, a release the checkout is already past (it only moves forward), a release that changes the
# PostgreSQL major (that is the separate "Major PostgreSQL upgrade" procedure), a database whose migration ledger names migrations the
# release does not contain (a new baseline, or a downgrade), a stored Slack webhook file that setup would not accept, a release
# without upgrade.sh, whatever the release's own preflight refuses, and a psql session open on the database from outside the stack
# (fas-sync writes straight to the database that way: pause it first; see "Write freeze" below).
#
# Write freeze. From before the backup to the end of setup nothing may write to the database, or the way back (an in-place restore of the
# backup) would lose it without a trace. The API is closed by maintenance mode (scripts/maintenance.sh: the marker config/maintenance, which
# scripts/compose.sh turns into WAREHOUSE_MAINTENANCE=upgrading for every Compose command, so that no step of the upgrade recreates a gateway
# that is open); fas-sync is not part of the stack and is paused by the operator: the check above can only partly confirm it (it sees a session that
# is open at that moment, and fas-sync opens one per statement, so it is usually not seen; it catches a psql left open). When a step fails after
# the checkout has moved the API STAYS closed (the facility may be half upgraded: the way forward and the way back, printed, end with the command
# that opens it); until then, while nothing of the facility was changed (a refused check, a failed backup or proof) it is opened again at once.
#
# An interrupted upgrade can be finished or undone. Before the first change the script writes $WAREHOUSE_STATE_DIR/config/
# upgrade-in-progress (mode 0600; scripts/upgrade-record.mjs reads it): the old commit, the target, the setup inputs and the
# current step, whether the release had a preflight (preflight=ok|absent) and the tag of the saved images (pre_images=); once the
# backup is verified, also the backup's path. A rerun of the same command (the database may be down)
# reads it, reuses that backup and takes no new one of the half-upgraded database, and names the right old commit. Success deletes
# it; doctor, start.sh and the status commands report it while it exists. When a step fails the script prints the way forward and
# the complete way back (the old commit, stop, the saved images put back, the in-place restore of that backup with --restore-config,
# the old release's setup, the functions recreate, doctor).
#
# Setup arguments. setup.sh needs --state-dir, --admin-phone and --admin-name; everything else is optional on a rerun and
# keeps what the state holds (identity, URLs, provider lines, central sign-in, gateway port, letterhead, signing keys).
# --state-dir is $WAREHOUSE_STATE_DIR. The administrator is read from the database (any active approved administrator
# matches setup's check; --admin-name is only used when none exists), or given with --admin-phone and --admin-name. The one
# value a state cannot show is "no Slack webhook" (--alert-webhook-file off): when none is stored, `off` is passed again, so
# setup does not stop to ask on a rerun. Options after `--` go to setup.sh as they are and win over those defaults.
#
# --dry-run runs every check, the release's preflight included, and prints the plan. It does fetch the tags (git's object store
# only); nothing in the working tree, the state or the containers changes, and no line is written to upgrades.log. Run it first: it
# is how the operator actions of the release are read before the real run (which pauses for them only at a terminal).
# --yes: do not pause after the operator actions the preflight prints (a run without a terminal on standard input never pauses).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bash upgrade.sh [--dry-run] [--yes] [--admin-phone 91XXXXXXXXXX --admin-name NAME] vX.Y.Z [-- SETUP_OPTION VALUE ...]
       bash upgrade.sh [--dry-run] [--yes] --ref COMMIT_OR_BRANCH [...]      (tests and development only)
--dry-run changes nothing and prints what the release asks of you: run it first. --yes: no pause after that list.
WAREHOUSE_STATE_DIR must name the installed operator state. docs/OPERATOR_INSTALL.md, "Rerun and upgrade".
EOF
}

SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
LOGGING=no
STEP='checks before anything is changed'
# Where the run is, for what a failure may say about the facility: checks, backup (nothing changed yet), checkout, setup, done.
STAGE=checks
BACKUP_DIR=''
BACKUP_OUT=''
DB_ERR=''
FROM_SHA=''
FROM_LABEL=''
FROM_TAG=''
TO_SHA=''
TO_LABEL=''
STATE=''
ROOT=''
RECORD=''
RECORD_LIVE=no
RECORD_STARTED=''
VERIFIED=no
RESUME=no
ADMIN_PHONE=''
ADMIN_NAME=''
WEBHOOK_OFF=no
ASSUME_YES=no
# What the release's own preflight said (ok, or absent when the release has none) and the tag the running images got (pre-<label>,
# or none): both go into the record.
PREFLIGHT=absent
PRE_IMAGES=none
# Whether this run has put the gateways in maintenance mode (on, or none): it goes into the record, so that the report of an interrupted
# upgrade can say that the API is closed and that nothing was recorded by phones after the backup.
MAINTENANCE=none
PREFLIGHT_TREE=''
CMD_TEXT=''
ORIG_ARGS=()
# What load_record found: none, unverified (the old release was only being backed up), verified, invalid.
REC=none
R_FROM_SHA='' R_FROM_LABEL='' R_FROM_TAG='' R_TO_SHA='' R_TO_LABEL='' R_BACKUP='' R_STARTED='' R_STEP='' R_ADMIN_PHONE='' R_ADMIN_NAME='' R_WEBHOOK_OFF='' R_PREFLIGHT='' R_PRE_IMAGES=''

say() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
# A refusal changes nothing. While an interrupted upgrade is recorded, the report of that upgrade follows it.
refuse() {
  printf 'Refusing: %s\n' "$*" >&2
  if [[ "$REC" == verified ]]; then
    printf '\nThis run changed nothing. The interrupted upgrade is still recorded:\n' >&2
    interrupted_report >&2
  fi
  exit 1
}
step() {
  STEP="$1"
  printf '\n==> %s\n' "$1"
  if [[ "$RECORD_LIVE" == yes ]]; then record_write || warn "could not update $RECORD"; fi
}
one_line() { local text="$1"; text="${text//$'\n'/ }"; text="${text//$'\r'/ }"; printf '%s' "${text//$'\t'/ }"; }

# The record of this upgrade (scripts/upgrade-record.mjs reads it). Plain key=value lines, mode 0600, replaced whole by a rename.
record_write() {
  [[ -n "$RECORD" ]] || return 0
  local tmp
  tmp="$(umask 077; mktemp "$STATE/config/.upgrade-in-progress.XXXXXX")" || return 1
  {
    printf 'format=1\n'
    printf 'started=%s\n' "$RECORD_STARTED"
    printf 'from_sha=%s\n' "$FROM_SHA"
    printf 'from_label=%s\n' "$(one_line "$FROM_LABEL")"
    printf 'from_tag=%s\n' "$(one_line "$FROM_TAG")"
    printf 'to_sha=%s\n' "$TO_SHA"
    printf 'to_label=%s\n' "$(one_line "$TO_LABEL")"
    printf 'command=%s\n' "$(one_line "$CMD_TEXT")"
    printf 'admin_phone=%s\n' "$ADMIN_PHONE"
    printf 'admin_name=%s\n' "$(one_line "$ADMIN_NAME")"
    printf 'webhook_off=%s\n' "$WEBHOOK_OFF"
    printf 'verified=%s\n' "$VERIFIED"
    printf 'backup=%s\n' "$(one_line "$BACKUP_DIR")"
    printf 'preflight=%s\n' "$PREFLIGHT"
    printf 'pre_images=%s\n' "$(one_line "$PRE_IMAGES")"
    printf 'maintenance=%s\n' "$MAINTENANCE"
    printf 'step=%s\n' "$(one_line "$STEP")"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  sync -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

record_remove() {
  [[ "$RECORD_LIVE" == yes ]] || return 0
  rm -f -- "$RECORD" || warn "could not remove $RECORD; remove it by hand once the facility is healthy"
  RECORD_LIVE=no
}

# Reads $RECORD into the R_* variables and sets REC. A record that cannot be trusted is REC=invalid.
load_record() {
  REC=none
  if [[ -L "$RECORD" ]] || [[ -e "$RECORD" && ! -f "$RECORD" ]]; then REC=invalid; return 0; fi
  [[ -f "$RECORD" ]] || return 0
  rec_get() { sed -n "s/^$1=//p" "$RECORD" | head -n 1; }
  R_FROM_SHA="$(rec_get from_sha)"; R_FROM_LABEL="$(rec_get from_label)"; R_FROM_TAG="$(rec_get from_tag)"
  R_TO_SHA="$(rec_get to_sha)"; R_TO_LABEL="$(rec_get to_label)"; R_BACKUP="$(rec_get backup)"
  R_STARTED="$(rec_get started)"; R_STEP="$(rec_get step)"
  R_ADMIN_PHONE="$(rec_get admin_phone)"; R_ADMIN_NAME="$(rec_get admin_name)"; R_WEBHOOK_OFF="$(rec_get webhook_off)"
  R_PREFLIGHT="$(rec_get preflight)"; R_PRE_IMAGES="$(rec_get pre_images)"
  if ! [[ "$R_FROM_SHA" =~ ^[0-9a-f]{40}$ && "$R_TO_SHA" =~ ^[0-9a-f]{40}$ ]]; then REC=invalid; return 0; fi
  if [[ "$(rec_get verified)" == yes ]]; then
    [[ "$R_BACKUP" == /* ]] || { REC=invalid; return 0; }
    REC=verified
  else
    REC=unverified
  fi
}

# What to do about an upgrade that stopped half way: the report of scripts/upgrade-record.mjs (the way forward, the complete way
# back), or a short note if that script cannot run.
interrupted_report() {
  node "$ROOT/scripts/upgrade-record.mjs" report 2>/dev/null && return 0
  echo "An upgrade from ${FROM_LABEL:-the old release} (${FROM_SHA:-unknown}) to ${TO_LABEL:-the new one} is recorded in $RECORD."
  echo "The backup taken before it: ${BACKUP_DIR:-see the record}. Run the same command again to continue, or read the rollback in docs/OPERATOR_INSTALL.md (\"If it stops\")."
}

# True while nothing of the facility was changed by this run: the checks, the backup, or a checkout that did not move HEAD.
facility_unchanged() {
  case "$STAGE" in
    checks|backup) return 0 ;;
    checkout) [[ "$FROM_SHA" != "$TO_SHA" && "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)" == "$FROM_SHA" ]] ;;
    *) return 1 ;;
  esac
}

log_line() {
  local detail="from ${FROM_SHA:0:12}"
  [[ -z "$BACKUP_DIR" ]] || detail+=", backup $BACKUP_DIR"
  [[ "$RESUME" != yes ]] || detail+=', resumed'
  if ! (umask 077; printf '%s %s -> %s (%s) %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FROM_LABEL" "$TO_LABEL" "$detail" "$1" >> "$STATE/config/upgrades.log") 2>/dev/null; then
    warn "could not write $STATE/config/upgrades.log"
  fi
}

finish() {
  local code=$?
  trap - EXIT
  rm -f -- "$BACKUP_OUT" "$DB_ERR"
  if [[ "$LOGGING" == yes ]]; then
    local result=ok
    ((code == 0)) || result="failed at: $STEP (exit $code)"
    log_line "$result"
    if ((code == 0)); then
      record_remove
    else
      # Nothing of the facility changed: no half-done upgrade to report, and a rerun takes a fresh backup. The API this run closed is opened again
      # (a facility that is as it was must not stay closed for a refusal); once the checkout has moved it stays closed with the record. A record is
      # removed only when the API is not left closed by it: while it is, the record is what makes the checker say so (upgrade_interrupted).
      if facility_unchanged; then
        reopen_unchanged_api
        [[ "$MAINTENANCE" == on ]] || record_remove
      fi
      recovery_text >&2
    fi
  fi
  exit "$code"
}

recovery_text() {
  echo
  echo "The upgrade stopped at: $STEP."
  if facility_unchanged; then
    [[ -z "$BACKUP_DIR" ]] || echo "The backup taken first: $BACKUP_DIR"
    echo "The checkout was not changed (still at $FROM_LABEL). Fix the cause shown above and run the same command again: bash upgrade.sh $CMD_TEXT"
    if [[ "$MAINTENANCE" == on ]]; then
      echo 'The API is still closed to phones (maintenance mode): the same command goes on with it closed, and this opens it: bash scripts/maintenance.sh off'
    fi
    return 0
  fi
  local head
  head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$head" == "$TO_SHA" && "$FROM_SHA" != "$TO_SHA" ]]; then echo "This checkout is now at $TO_LABEL; it was at $FROM_LABEL ($FROM_SHA)."
  elif [[ "$head" == "$FROM_SHA" ]]; then echo "This checkout is at $FROM_LABEL ($FROM_SHA)."
  else echo "This checkout is at ${head:0:12}; it was at $FROM_LABEL ($FROM_SHA), and the target is $TO_LABEL."; fi
  echo "Fix the cause shown above, then continue or go back:"
  echo
  interrupted_report
}

# The release's own preflight. This script is the script of the release the facility runs now, so it cannot know what the release it
# moves to needs: a higher host minimum, the oldest release that one accepts an upgrade from, room for the way back. The release
# carries scripts/upgrade-preflight.sh for that. It is read out of the target's commit with `git archive`, as scripts/pg-major.sh reads
# db-image.sh, together with the files that script names on its `# needs:` line (a directory counts), and run from a temporary copy
# before anything is changed, in --dry-run too. It prints what CHANGELOG.md asks of the operator (and may wait for Enter after it: standard
# input is this script's) and exits non-zero to refuse. A release from before the preflight has none: PREFLIGHT stays `absent` and the
# checks of this script are all there are.
run_target_preflight() {
  local dry="$1" needs path tree code=0
  local -a words=() paths=()
  PREFLIGHT=absent
  if ! git cat-file -e "$TO_SHA:scripts/upgrade-preflight.sh" 2>/dev/null; then
    say "Preflight:    $TO_LABEL has no scripts/upgrade-preflight.sh (it is from before the release preflight), so only the checks above were made."
    return 0
  fi
  needs="$(git show "$TO_SHA:scripts/upgrade-preflight.sh" | sed -n 's/^# needs:[[:space:]]*//p' | head -n 1)"
  read -r -a words <<< "$needs"
  for path in "${words[@]+"${words[@]}"}"; do
    [[ "$path" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && "$path" != *..* ]] || refuse "the preflight of $TO_LABEL names a file this script will not read from it ('$path'). Nothing was changed."
    paths+=("$path")
  done
  tree="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-preflight.XXXXXX")" || refuse 'could not make a temporary directory for the preflight of the release. Nothing was changed.'
  PREFLIGHT_TREE="$tree"
  if ! git archive "$TO_SHA" scripts/upgrade-preflight.sh "${paths[@]+"${paths[@]}"}" | tar -x -C "$tree"; then
    refuse "the preflight of $TO_LABEL names a file that release does not contain (message above). Nothing was changed."
  fi
  say "Preflight:    running scripts/upgrade-preflight.sh of $TO_LABEL"
  (cd "$tree" && STATE="$STATE" FROM_SHA="$FROM_SHA" FROM_LABEL="$FROM_LABEL" FROM_TAG="$FROM_TAG" TO_SHA="$TO_SHA" TO_LABEL="$TO_LABEL" DRY="$dry" ASSUME_YES="$ASSUME_YES" bash scripts/upgrade-preflight.sh) || code=$?
  rm -rf -- "$tree"
  PREFLIGHT_TREE=''
  ((code == 0)) || refuse "the preflight of $TO_LABEL stopped this upgrade (exit $code; its message is above). Nothing was changed."
  PREFLIGHT=ok
}

# Before the checkout: the images the running services use get the tag <project>-<service>:pre-<this release>, so that the way back
# puts them back and builds nothing (scripts/pre-images.sh). Not being able to is a warning, not a refusal: the way back then builds the
# old images again, as it always did, and that needs the network.
tag_running_images() {
  local code=0
  bash "$ROOT/scripts/pre-images.sh" tag "$FROM_LABEL" || code=$?
  case "$code" in
    0) PRE_IMAGES="$(bash "$ROOT/scripts/pre-images.sh" name "$FROM_LABEL")" ;;
    3) PRE_IMAGES=none ;;
    *) PRE_IMAGES=none; warn "could not tag the running images as pre-$FROM_LABEL (message above). The upgrade goes on; if you have to go back, the old release's setup builds its images again, which needs the network." ;;
  esac
  record_write || warn "could not update $RECORD"
}

# 0 when setup would find a Slack webhook in the state, 3 when none is stored, 5 when a file is there that setup would not accept
# as one, 4 when this checkout cannot tell. The URL is a secret and never leaves the process.
webhook_stored() {
  # Paths go in the environment, not in argv: a module that finds its own path in argv[1] would run as a command.
  UPGRADE_MODULE="$ROOT/scripts/alert-webhook.mjs" UPGRADE_STATE="$STATE" node -e '
    import(require("url").pathToFileURL(process.env.UPGRADE_MODULE).href).then(m => {
      const fs = require("fs"), path = require("path"), state = process.env.UPGRADE_STATE;
      if (m.storedWebhook(state) !== null) process.exit(0);
      const there = [m.WEBHOOK_FILE, m.LEGACY_WEBHOOK_FILE].some(f => { try { return fs.lstatSync(path.join(state, f)).isFile(); } catch { return false; } });
      process.exit(there ? 5 : 3);
    }).catch(() => process.exit(4))'
}

# The answer on stdout; whatever the command says on stderr goes to $DB_ERR, so a warning never reads as an answer.
db_query() {
  bash "$ROOT/scripts/compose.sh" exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "$1" < /dev/null 2> "$DB_ERR"
}

# The psql sessions on the facility's database that are not this command's own, one line each ("user state age"), at most five; nothing when there
# are none. fas-sync writes straight to the database with `docker exec ... psql`, and so does anyone who left a psql open. The services of the
# stack connect under their own application names (PostgREST, Storage, the function runtime), and the operator scripts that run psql in the
# container are not running: this command holds the operator lock. Fails when the database does not answer.
outside_psql_sessions() {
  db_query "SELECT usename || ' ' || coalesce(state, 'unknown') || ' ' || (extract(epoch FROM now() - backend_start))::int || 's' FROM pg_stat_activity WHERE backend_type = 'client backend' AND application_name = 'psql' AND pid <> pg_backend_pid() ORDER BY backend_start LIMIT 5"
}
# Prints the sessions found (after a short wait, so that a probe that is just finishing is not taken for fas-sync) or nothing.
find_outside_psql() {
  local found
  found="$(outside_psql_sessions)" || return 1
  if [[ -n "$found" ]]; then sleep 3; found="$(outside_psql_sessions)" || return 1; fi
  printf '%s' "$found"
}
outside_psql_text() {
  printf '%s\n' "$1" | sed 's/^/  /'
  echo "That is a psql session on the database from outside the stack. fas-sync writes to the database that way (pause it: let its run finish and do not start another), and so does a psql that someone left open. Nothing may write between the backup and the end of setup, or the way back to the backup would lose it."
}

# Maintenance mode, closed before the backup and opened after setup (scripts/maintenance.sh; the marker it writes makes scripts/compose.sh pass
# WAREHOUSE_MAINTENANCE=upgrading to every Compose command, so the setup of the new release cannot recreate a gateway that is open).
# MAINTENANCE goes into the record before the gateways are touched: if this process dies between the two, the report still says the API may be closed.
close_api() {
  MAINTENANCE=on
  step 'Close the API to phones (maintenance mode)'
  bash "$ROOT/scripts/maintenance.sh" on
}
# Exit status 2 of `off` is "the API is open, but the health check failed": the record then says the API is open (`opened`), not closed, because
# the report, the checker's alert and the operator read it to know whether phones can reach the facility. Any other failure leaves it closed.
open_api() {
  step 'Open the API to phones again (maintenance mode off, then the health check)'
  local code=0
  bash "$ROOT/scripts/maintenance.sh" off || code=$?
  ((code == 0)) || {
    if ((code == 2)); then
      MAINTENANCE=opened
      record_write || warn "could not update $RECORD"
    fi
    return "$code"
  }
  MAINTENANCE=none
}
# A run that is stopped before the facility was changed (a refusal after the API was closed, a backup that failed) opens the API again: the
# facility is as it was, and the same command closes it again. Not on a resumed upgrade, whose database may be half upgraded already. It
# runs in the EXIT handler: a failure here only says so (MAINTENANCE stays `on`, which keeps the record).
reopen_unchanged_api() {
  [[ "$MAINTENANCE" == on && "$RESUME" == no ]] || return 0
  local code=0
  bash "$ROOT/scripts/maintenance.sh" off >&2 || code=$?
  if ((code == 0)); then
    MAINTENANCE=none
    echo 'The API was opened again (maintenance mode off): nothing of the facility was changed.' >&2
  elif ((code == 2)); then
    MAINTENANCE=none
    echo 'The API was opened again (maintenance mode off) and nothing of the facility was changed, but the health check failed (message above): look at it before you run the command again.' >&2
  else
    echo 'Could not open the API again (message above). It is closed to phones until you run: bash scripts/maintenance.sh off' >&2
  fi
}

# A commit for REF: a name is tried as a branch of origin before a possibly stale local branch; a hexadecimal string as a commit first.
resolve_ref() {
  local ref="$1" sha
  if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
    sha="$(git rev-parse -q --verify "$ref^{commit}" || git rev-parse -q --verify "origin/$ref^{commit}" || true)"
  else
    sha="$(git rev-parse -q --verify "origin/$ref^{commit}" || git rev-parse -q --verify "$ref^{commit}" || true)"
  fi
  printf '%s' "$sha"
}

main() {
  local DRY=no REF='' TAG='' ARG
  local -a SETUP_EXTRA=()
  ORIG_ARGS=("$@")
  while (($#)); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) DRY=yes; shift ;;
      --yes) ASSUME_YES=yes; shift ;;
      --ref|--admin-phone|--admin-name)
        if (($# < 2)) || [[ -z "$2" ]]; then echo "Missing value for $1" >&2; usage; exit 2; fi
        case "$1" in --ref) REF="$2" ;; --admin-phone) ADMIN_PHONE="$2" ;; --admin-name) ADMIN_NAME="$2" ;; esac
        shift 2 ;;
      --) shift; SETUP_EXTRA=("$@"); break ;;
      -*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
      *) [[ -z "$TAG" ]] || { echo 'Give one release tag.' >&2; usage; exit 2; }; TAG="$1"; shift ;;
    esac
  done
  if [[ -n "$REF" && -n "$TAG" ]] || [[ -z "$REF" && -z "$TAG" ]]; then
    echo 'Give a release tag (bash upgrade.sh v0.7.0) or --ref, not both and not neither.' >&2
    usage; exit 2
  fi
  if [[ -n "$ADMIN_PHONE" || -n "$ADMIN_NAME" ]]; then
    [[ "$ADMIN_PHONE" =~ ^91[0-9]{10}$ && -n "$ADMIN_NAME" ]] || { echo '--admin-phone 91XXXXXXXXXX and --admin-name NAME go together.' >&2; exit 2; }
  fi
  for ARG in "${SETUP_EXTRA[@]+"${SETUP_EXTRA[@]}"}"; do
    case "$ARG" in --state-dir|--admin-phone|--admin-name|--operator) refuse "$ARG is set by upgrade.sh; leave it out of the options after --." ;; esac
  done
  for ARG in "${ORIG_ARGS[@]}"; do CMD_TEXT+="$(printf '%q' "$ARG") "; done
  CMD_TEXT="${CMD_TEXT% }"

  trap 'rm -f -- "$BACKUP_OUT" "$DB_ERR"; [[ -z "$PREFLIGHT_TREE" ]] || rm -rf -- "$PREFLIGHT_TREE"' EXIT
  DB_ERR="$(mktemp)"
  ((EUID != 0)) || refuse 'upgrade.sh must run as the installation user (the owner of this checkout and of the state, a member of the docker group), not as root and not with sudo: root cannot read the files the way the installation does, and git refuses a checkout it does not own.'
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/operator-lock.sh
  . "$ROOT/scripts/operator-lock.sh"
  # shellcheck source=scripts/upgrade-lib.sh
  . "$ROOT/scripts/upgrade-lib.sh"
  STATE="$(operator_state)" || exit 1
  export WAREHOUSE_STATE_DIR="$STATE"
  RECORD="$STATE/config/upgrade-in-progress"
  command -v git >/dev/null || refuse 'git is not installed.'
  command -v node >/dev/null || refuse 'node is not on PATH (the operator scripts need it; docs/OPERATOR_INSTALL.md, "Host prerequisites").'
  [[ -O "$ROOT" ]] || refuse "$ROOT belongs to another user than $(id -un). Run upgrade.sh as the user that owns the checkout and the state."
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || refuse "$ROOT is not a git checkout (or git does not trust it: the checkout must belong to the user running this). upgrade.sh moves a git checkout from one release to another; a source archive is replaced by cloning the release again (docs/OPERATOR_INSTALL.md, \"Recover a lost host from the USB drive\")."
  cd "$ROOT"

  operator_lock "$STATE" || exit 1
  load_record
  [[ "$REC" != invalid ]] || refuse "$RECORD is not a readable upgrade record. Read it ('cat' it): it names the old commit and the backup of an upgrade that stopped half way. If you have already dealt with that upgrade, remove the file ('rm $RECORD') and run this command again. Nothing was changed."

  # --- checks that change nothing ---------------------------------------------------------------------------------
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    git status --short --untracked-files=no >&2
    refuse "this checkout has uncommitted changes to tracked files (listed above). Nothing was changed. Keep or drop them first: 'git stash' keeps them aside, 'git checkout -- <file>' drops one. Then run this command again."
  fi
  FROM_SHA="$(git rev-parse HEAD)"
  FROM_LABEL="$(git describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || git rev-parse --short HEAD)"
  FROM_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
  git remote get-url origin >/dev/null 2>&1 || refuse "this checkout has no remote named origin. Add it: git remote add origin https://github.com/abhiguru/supabase-warehouse-template.git"

  if [[ -n "$TAG" ]] && ! [[ "$TAG" =~ $SEMVER ]]; then
    refuse "'$TAG' is not a release tag. Give a tag such as v0.7.0 (the list is on the GitHub releases page; 'git tag --list \"v*\"' after 'git fetch --tags'). Only tagged releases are supported; --ref COMMIT_OR_BRANCH is for tests and development."
  fi
  if [[ -n "$REF" ]]; then
    warn "--ref $REF is not a release tag. Only tagged releases are supported: security fixes, the support window and the upgrade notes apply to tags, and a branch can hold changes that were never released."
  fi

  say "Installation: $STATE"
  say "Now at:       $FROM_LABEL"
  step 'Fetching tags from origin'
  if ! git fetch --tags origin; then
    if [[ -n "$REF" && -n "$(resolve_ref "$REF")" ]]; then
      warn "could not fetch from origin; going on with the local $REF"
    else
      refuse "could not fetch from origin (message above). Check the network. If git says a tag 'would clobber' the local one, the tag was moved on origin: delete the local tag ('git tag -d <tag>') and run this command again. Nothing was changed."
    fi
  fi

  if [[ -n "$TAG" ]]; then
    TO_SHA="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)"
    [[ -n "$TO_SHA" ]] || refuse "origin has no tag $TAG (after 'git fetch --tags'). Check the name against the GitHub releases page. Nothing was changed."
    local remote lines peeled direct
    lines="$(git ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}")" || refuse "could not ask origin about the tag $TAG. Nothing was changed."
    peeled="$(awk '$2 ~ /\^\{\}$/ { print $1 }' <<< "$lines")"
    direct="$(awk '$2 !~ /\^\{\}$/ { print $1 }' <<< "$lines")"
    remote="${peeled:-$direct}"
    [[ -n "$remote" ]] || refuse "the tag $TAG is not on origin (a tag made only in this checkout is not a release). Nothing was changed."
    [[ "$remote" == "$TO_SHA" ]] || refuse "the local tag $TAG points to ${TO_SHA:0:12} but origin's points to ${remote:0:12}: the tag was moved. Delete the local one ('git tag -d $TAG'), fetch again, and read the release notes about why it moved. Nothing was changed."
    TO_LABEL="$TAG"
  else
    TO_SHA="$(resolve_ref "$REF")"
    [[ -n "$TO_SHA" ]] || refuse "--ref $REF is neither a commit nor a branch of origin. Nothing was changed."
    TO_LABEL="$(git rev-parse --short "$TO_SHA") (--ref $REF)"
  fi

  # An upgrade that stopped half way is finished by the same command; the record holds what the first run knew.
  if [[ "$REC" == verified ]]; then
    if [[ "$R_TO_SHA" != "$TO_SHA" ]]; then
      refuse "an upgrade from $R_FROM_LABEL to $R_TO_LABEL stopped at step \"$R_STEP\" (started $R_STARTED) and is not finished, so a move to $TO_LABEL is refused: the facility may be half upgraded. Finish that upgrade by running its command again, or go back to $R_FROM_LABEL with the commands below. The record is removed when the upgrade succeeds (or by the last line of the way back); then any upgrade can start."
    fi
    RESUME=yes
    FROM_SHA="$R_FROM_SHA"; FROM_LABEL="$R_FROM_LABEL"; FROM_TAG="$R_FROM_TAG"; BACKUP_DIR="$R_BACKUP"
    RECORD_STARTED="$R_STARTED"; VERIFIED=yes
    [[ -d "$BACKUP_DIR" ]] || refuse "the backup recorded for this upgrade is gone: $BACKUP_DIR. It is the way back to $FROM_LABEL, and a new backup of a half-upgraded database would not be. Put it back (the USB drive holds copies of recent backups), or, if you accept going on without a way back, remove $RECORD and run the command again (it then takes a new backup of the database as it is now)."
    say "Resuming:     the upgrade from $FROM_LABEL to $TO_LABEL stopped at step \"$R_STEP\" (started $R_STARTED)"
  fi

  git cat-file -e "$TO_SHA:upgrade.sh" 2>/dev/null || refuse "$TO_LABEL does not contain upgrade.sh, so its setup.sh cannot run under the lock this command holds. upgrade.sh moves to releases that ship it. For an earlier release use the manual sequence in docs/OPERATOR_INSTALL.md (\"Rerun and upgrade\", \"What upgrade.sh does\"). Nothing was changed."

  # Only forward: a release the checkout already contains, or a lower release number than the one it sits on.
  if [[ "$FROM_SHA" != "$TO_SHA" ]] && git merge-base --is-ancestor "$TO_SHA" "$FROM_SHA" 2>/dev/null; then
    refuse "this checkout ($FROM_LABEL) is already past $TO_LABEL: it contains it. upgrade.sh only moves forward; wait for the next release. Nothing was changed."
  fi
  if [[ -n "$TAG" ]]; then
    local exact='' candidate
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      if [[ -z "$exact" ]] || semver_lt "$exact" "$candidate"; then exact="$candidate"; fi
    done < <(git tag --points-at "$FROM_SHA" --list 'v[0-9]*')
    if [[ -n "$exact" ]] && semver_lt "$TAG" "$exact"; then
      refuse "this checkout is at the release $exact, which is newer than $TAG: upgrade.sh only moves forward; wait for the next release. Nothing was changed."
    fi
  fi

  # An untracked file in the way would make `git checkout` stop after the backup.
  local clash
  clash="$(LC_ALL=C comm -12 <(git ls-files --others --exclude-standard | LC_ALL=C sort) <(git ls-tree -r --name-only "$TO_SHA" | LC_ALL=C sort) | head -n 5 | paste -sd, -)"
  [[ -z "$clash" ]] || refuse "files in this checkout that git does not track are where $TO_LABEL has files of its own (for example: $clash), so the checkout would stop half way. Move them aside, or 'git clean' them if they are leftovers, and run this command again. Nothing was changed."

  local PG_FROM PG_TO
  PG_FROM="$(bash "$ROOT/scripts/pg-major.sh" "$FROM_SHA")" || exit 1
  PG_TO="$(bash "$ROOT/scripts/pg-major.sh" "$TO_SHA")" || exit 1
  if [[ "$PG_FROM" != "$PG_TO" ]]; then
    refuse "$TO_LABEL runs PostgreSQL $PG_TO and this checkout runs PostgreSQL $PG_FROM. A new PostgreSQL major cannot be applied in place: follow docs/OPERATOR_INSTALL.md, \"Major PostgreSQL upgrade\" (it also gives the way back), then use upgrade.sh for later releases. Nothing was changed."
  fi

  # What needs the running database: the migration ledger against the release's migrations, the server's own version, and the
  # administrator. An interrupted upgrade may have left the database down: setup starts it, so the rerun goes on without these.
  local DB_OK=yes DB_NOTE='' APPLIED='' LINE='' SERVER_NUM='' STATE_OF_ADMIN=''
  if ! APPLIED="$(db_query 'SELECT name FROM warehouse_migrations.applied ORDER BY name')"; then
    DB_OK=no
    DB_NOTE="the database did not answer: $(head -c 300 "$DB_ERR" | tr '\n' ' ')"
  fi
  if [[ "$DB_OK" == yes ]]; then
    local release_names missing
    release_names="$(git ls-tree --name-only "$TO_SHA" migrations/ | sed 's|^migrations/||')"
    missing="$(comm -23 <(printf '%s\n' "$APPLIED" | sed '/^$/d' | sort) <(printf '%s\n' "$release_names" | sort) | head -n 5 | paste -sd, -)"
    if [[ -n "$missing" ]]; then
      refuse "this database recorded migrations that $TO_LABEL does not contain (for example: $missing). Either the release was rebuilt on a new baseline, which cannot be applied in place (docs/OPERATOR_INSTALL.md, \"Baseline reload\"), or $TO_LABEL is older than the one that recorded them: upgrade.sh only moves forward. Nothing was changed."
    fi
    SERVER_NUM="$(db_query "SELECT current_setting('server_version_num')" || true)"
    if [[ "$SERVER_NUM" =~ ^[0-9]+$ ]] && ((SERVER_NUM / 10000 != PG_TO)); then
      refuse "the database server runs PostgreSQL $((SERVER_NUM / 10000)) but the checkout (and $TO_LABEL) say PostgreSQL $PG_TO: the checkout was moved without setup, or the data is from another major. That is the \"Major PostgreSQL upgrade\" procedure (docs/OPERATOR_INSTALL.md), not an upgrade.sh move. Nothing was changed."
    fi
    if [[ -n "$ADMIN_PHONE" ]]; then
      STATE_OF_ADMIN="$(db_query "SELECT warehouse_security.installer_admin_state('$ADMIN_PHONE')" || true)"
      [[ "$STATE_OF_ADMIN" != different ]] || refuse "the facility has an administrator with another phone number than --admin-phone, and setup would stop with 'An admin already exists with a different phone' after the checkout. Give the administrator's own number, or leave --admin-phone and --admin-name out (upgrade.sh reads them from the database). Nothing was changed."
    elif [[ "$RESUME" == yes && -n "$R_ADMIN_PHONE" ]]; then
      ADMIN_PHONE="$R_ADMIN_PHONE"; ADMIN_NAME="$R_ADMIN_NAME"
    else
      LINE="$(db_query "SELECT mobile || '|' || coalesce(nullif(btrim(name), ''), 'Administrator') FROM public.user_profiles WHERE role = 'admin' AND active AND enrollment_status = 'approved' AND NOT is_service_account ORDER BY created_at LIMIT 1" || true)"
      ADMIN_PHONE="${LINE%%|*}"
      ADMIN_NAME="${LINE#*|}"
      [[ "$ADMIN_PHONE" =~ ^91[0-9]{10}$ && -n "$ADMIN_NAME" ]] || refuse "could not read the administrator from the database (setup needs it to check that the administrator is unchanged). Give --admin-phone 91XXXXXXXXXX --admin-name NAME. Nothing was changed."
    fi
  elif [[ "$RESUME" == yes ]]; then
    warn "the database is not answering ($DB_NOTE). Going on because an interrupted upgrade is recorded: setup starts the database. Not checked: the migration ledger."
    if [[ -z "$ADMIN_PHONE" ]]; then ADMIN_PHONE="$R_ADMIN_PHONE"; ADMIN_NAME="$R_ADMIN_NAME"; fi
    [[ "$ADMIN_PHONE" =~ ^91[0-9]{10}$ && -n "$ADMIN_NAME" ]] || refuse "the database is not answering and the record does not hold the administrator. Start the database ('bash scripts/compose.sh up -d --wait db') or give --admin-phone 91XXXXXXXXXX --admin-name NAME."
  elif [[ "$DRY" == no ]]; then
    refuse "the database is not answering ($DB_NOTE). The backup needs it running and healthy: start it ('bash start.sh') and run this command again. Nothing was changed."
  fi

  local code=0
  case " ${SETUP_EXTRA[*]+"${SETUP_EXTRA[*]}"} " in
    *" --alert-webhook-file "*) WEBHOOK_OFF=no ;;
    *) if [[ "$RESUME" == yes ]]; then
         WEBHOOK_OFF="$([[ "$R_WEBHOOK_OFF" == yes ]] && echo yes || echo no)"
       else
         webhook_stored || code=$?
         case "$code" in
           3) WEBHOOK_OFF=yes
              # setup would pass '--alert-webhook-file off', and configure refuses that while a sensor webhook is stored (after the checkout).
              if [[ -e "$STATE/config/sensor-webhook-url" || -L "$STATE/config/sensor-webhook-url" ]]; then
                local sensor_off=no i
                for ((i = 0; i + 1 < ${#SETUP_EXTRA[@]}; i++)); do
                  [[ "${SETUP_EXTRA[i]}" == --sensor-webhook-file && "${SETUP_EXTRA[i + 1]}" == off ]] && sensor_off=yes
                done
                [[ "$sensor_off" == yes ]] || refuse "no facility Slack webhook is stored, but a sensor webhook file is (config/sensor-webhook-url): setup would refuse '--alert-webhook-file off' while it is there, after the checkout. Add '-- --sensor-webhook-file off' to this command to drop the sensor webhook, or '-- --alert-webhook-file /absolute/path' (a file holding the facility webhook URL). Nothing was changed."
              fi ;;
           5) refuse "the Slack webhook file in the state does not hold a Slack incoming-webhook URL (https://hooks.slack.com/services/...), so setup would ask for one and, without a terminal, stop after the checkout. Replace it ('docs/MONITORING.md', \"Alert delivery\"), or add '-- --alert-webhook-file PATH' (a file holding the URL) or '-- --alert-webhook-file off' to this command. Nothing was changed." ;;
         esac
       fi ;;
  esac

  # The release's own preflight: after the checks above (cheap, local, this script's own), before the plan, so that --dry-run shows it.
  # A rerun of an interrupted upgrade made it the first time (the record says what it found); it is not asked again.
  if [[ "$RESUME" == yes ]]; then
    # What the record holds stays as it is: a record written by an upgrade.sh from before the preflight has no preflight= line, and is not
    # turned into one that says the release had none.
    PREFLIGHT="$R_PREFLIGHT"; PRE_IMAGES="${R_PRE_IMAGES:-none}"
    case "$R_PREFLIGHT" in
      ok) say 'Preflight:    not run again: the first run of this upgrade ran the release preflight (record: preflight=ok)' ;;
      absent) say "Preflight:    not run again: $TO_LABEL had no scripts/upgrade-preflight.sh when this upgrade began (record: preflight=absent)" ;;
      *) say 'Preflight:    none: this upgrade was begun by an upgrade.sh from before the release preflight (the record has no preflight= line); setup makes the host checks' ;;
    esac
  else
    run_target_preflight "$DRY"
  fi

  # --- the plan -------------------------------------------------------------------------------------------------------
  local MASKED='(not read: the database did not answer)'
  [[ -z "$ADMIN_PHONE" ]] || MASKED="${ADMIN_PHONE:0:2}******${ADMIN_PHONE: -4}"
  say
  say "Plan: $FROM_LABEL -> $TO_LABEL (PostgreSQL $PG_FROM stays)"
  if [[ "$RESUME" == yes ]]; then say "  1. no new backup: the one taken and verified before this upgrade began is reused ($BACKUP_DIR); the database may be half upgraded"
  else say '  1. backup, then verify the backup in a disposable database'; fi
  if [[ "$FROM_SHA" == "$TO_SHA" ]]; then say '  2. no checkout: this checkout is already at the release (the rest is repeated)'
  elif [[ "$(git rev-parse HEAD)" == "$TO_SHA" ]]; then say '  2. no checkout: this checkout is already at the release (the interrupted upgrade got that far)'
  elif [[ "$RESUME" == yes ]]; then say "  2. git checkout --detach ${TO_SHA:0:12} (no image is tagged again: the first run did that, record pre_images=$PRE_IMAGES)"
  else say "  2. tag the running images <project>-<service>:pre-$FROM_LABEL (the way back uses them), then git checkout --detach ${TO_SHA:0:12}"; fi
  say "  3. setup.sh --operator --state-dir $STATE --admin-phone $MASKED --admin-name <administrator's name>$([[ "$WEBHOOK_OFF" == yes ]] && echo ' --alert-webhook-file off')${SETUP_EXTRA[*]+" ${SETUP_EXTRA[*]}"}"
  say '     (setup of the release also recreates the functions container and ends with node scripts/doctor.mjs --local)'
  say '  4. print the operator actions of CHANGELOG.md between the two releases'
  say "  5. append a line to $STATE/config/upgrades.log, remove $RECORD, and remove the pre-* image tags of earlier upgrades"
  say '  The facility is closed for the backup, its verification and the migrations: before step 1 both gateways are put in maintenance mode (phones are told the server is being updated)'
  say '  and after step 3 they are opened again. fas-sync (it writes straight to the database) has to be paused before the real run: nothing may write meanwhile, or the way back would lose it. The real run checks for a psql session and refuses to start while one is open.'
  if [[ "$DRY" == yes ]]; then
    [[ "$DB_OK" == yes ]] || warn "not checked: the migration ledger and the administrator ($DB_NOTE)"
    if [[ "$DB_OK" == yes ]]; then
      local OUTSIDE=''
      if OUTSIDE="$(find_outside_psql)"; then
        [[ -z "$OUTSIDE" ]] || { warn 'a psql session is open on the database, and the real run refuses to start while it is:'; outside_psql_text "$OUTSIDE" >&2; }
      else
        warn "could not ask the database which sessions are open ($(head -c 200 "$DB_ERR" | tr '\n' ' ')); the real run needs the answer"
      fi
    fi
    say
    say 'Dry run: nothing was changed (the tags were fetched into git, the rehearsal may have pulled the database image of the release and used a disposable directory under the state, which it removed; the working tree, the data, the configuration and the containers are as they were).'
    exit 0
  fi

  # --- fas-sync and anyone else with a psql session open: nothing may write from here to the end of setup ------------------
  # (A resumed upgrade whose database does not answer cannot be asked; setup starts it, and the API is closed again below.)
  if [[ "$DB_OK" == yes ]]; then
    local OUTSIDE=''
    OUTSIDE="$(find_outside_psql)" || refuse "could not ask the database which sessions are open ($(head -c 200 "$DB_ERR" | tr '\n' ' ')). Nothing was changed."
    if [[ -n "$OUTSIDE" ]]; then
      outside_psql_text "$OUTSIDE" >&2
      refuse "pause fas-sync (or close the session) and run this command again. Nothing was changed."
    fi
  fi

  # --- the upgrade ----------------------------------------------------------------------------------------------------
  LOGGING=yes
  trap finish EXIT
  # doctor and the status commands do not call a run in progress "interrupted".
  export WAREHOUSE_UPGRADE_RUNNING=1
  say
  say 'The facility is closed to phones from the backup to the end of setup (maintenance mode: they are told the server is being updated), and setup restarts services. The monitoring checker stays quiet while this command holds the operator lock.'
  say 'Run it in tmux or screen when you are connected over SSH: a dropped connection would stop it half way (the rerun finishes it).'

  if [[ "$RESUME" == yes ]]; then
    STAGE=checkout
    RECORD_LIVE=yes
    step "Resuming: the backup taken before the upgrade began is reused"
    say "Backup, verified before the first change: $BACKUP_DIR"
    # Closed again, whatever the first run did: an upgrade.sh from before maintenance mode did not close it, and a facility that was opened by hand
    # in between must not take writes that the backup does not hold.
    close_api
  else
    STAGE=backup
    RECORD_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    RECORD_LIVE=yes
    # Before the first change: from here on a rerun, doctor and start.sh can say what was going on. Without the record there is no start.
    STEP='Backup'
    record_write || { echo "Could not write the upgrade record $RECORD. Nothing was changed." >&2; exit 1; }
    close_api
    step 'Backup'
    BACKUP_OUT="$(mktemp)"
    bash "$ROOT/scripts/backup.sh" | tee "$BACKUP_OUT"
    BACKUP_DIR="$(sed -n 's/^Backup created at \(\/.*\)$/\1/p' "$BACKUP_OUT" | tail -n 1)"
    [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || { echo 'The backup finished but did not report its directory.' >&2; exit 1; }

    step 'Verify the backup restores'
    local verify_from=$SECONDS
    bash "$ROOT/scripts/verify-restore.sh" "$BACKUP_DIR"
    # The backup is proved: from here the record names it, and a rerun reuses it.
    VERIFIED=yes
    STAGE=checkout
    # It also goes on the list of verified backups (with how long the proof took), so that the daily pruning keeps it like the nightly ones
    # that passed their verify: for 60 days as the newest of its migration state, not seven nights. Not being able to is a warning.
    node "$ROOT/scripts/watch.mjs" record-verified "$BACKUP_DIR" "$((SECONDS - verify_from))" >/dev/null \
      || warn "could not put $BACKUP_DIR on config/backups-verified.list (message above), so the nightly pruning does not know it passed its verify; the upgrade goes on"
  fi

  if [[ "$(git rev-parse HEAD)" == "$TO_SHA" ]]; then
    step "Checkout: already at $TO_LABEL"
  else
    step "Checkout: $TO_LABEL"
    if [[ "$RESUME" == yes ]]; then
      # The first run tagged the images of the old release (or could not); whatever runs now may be the new release's, so nothing is
      # tagged again and the record keeps what it says (PRE_IMAGES came from it above).
      say "Images:       not tagged again: the first run of this upgrade did that (record: pre_images=$PRE_IMAGES)"
    else
      tag_running_images
    fi
    # umask 022 as for the first clone: files written under 0002 or 077 are refused by the root-run helpers or unreadable by the containers.
    (umask 022; git checkout --detach "$TO_SHA")
    STAGE=setup
    bash "$ROOT/scripts/checkout-permissions.sh" --quiet
  fi
  STAGE=setup

  step 'Setup (the same inputs as the installation)'
  # setup.sh of the new release; it runs under this command's lock (operator_lock_or_inherited). It recreates the functions container
  # and ends with the local doctor, so nothing of the release's own procedure is left to this script.
  local -a SETUP=(--operator --state-dir "$STATE" --admin-phone "$ADMIN_PHONE" --admin-name "$ADMIN_NAME")
  [[ "$WEBHOOK_OFF" == no ]] || SETUP+=(--alert-webhook-file off)
  bash "$ROOT/setup.sh" "${SETUP[@]}" "${SETUP_EXTRA[@]+"${SETUP_EXTRA[@]}"}"
  STAGE=done
  # The release's own scripts open the API: its maintenance.sh runs the health check that setup could not make through a closed gateway.
  open_api
  # The tags of earlier upgrades go, by exact name (never an image prune); the set of this one stays until the next upgrade succeeds.
  # scripts/pre-images.sh is the new release's copy by now: it keeps the commands that this script calls. The tag to keep is the one
  # recorded when the images were tagged (the third argument), not one worked out again by the new release's own naming.
  if [[ "$PRE_IMAGES" != none && -f "$ROOT/scripts/pre-images.sh" ]]; then
    bash "$ROOT/scripts/pre-images.sh" prune "$FROM_LABEL" "$PRE_IMAGES" || warn 'could not remove the image tags of earlier upgrades (message above); they hold disk space until you remove them by hand.'
  fi

  step "What $TO_LABEL asks of the operator"
  local CL_TO="$TAG"
  [[ -n "$TAG" ]] || CL_TO=Unreleased
  changelog_between "$ROOT/CHANGELOG.md" "$FROM_TAG" "$CL_TO" || warn 'could not print the operator actions of CHANGELOG.md; read the file before you rely on this upgrade.'

  step 'Done'
  say "Upgraded $FROM_LABEL -> $TO_LABEL. The backup taken before the upgrade: $BACKUP_DIR"
  say 'Still to do by hand when they apply:'
  say '  - a "sudo bash scripts/watch-timer.sh ..." command printed by setup above (the monitoring checker timer)'
  say "  - a USB backup drive: sudo bash scripts/backup-usb.sh setup --state \"\$WAREHOUSE_STATE_DIR\"   (it prints your earlier choices; check that line)"
  say '  - the public check: node scripts/doctor.mjs'
  say "  - the operator actions listed above"
}
main "$@"; exit $?
