#!/usr/bin/env bash
# One command to move an installed facility to a tagged release (docs/OPERATOR_INSTALL.md, "Rerun and upgrade").
#
#   export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
#   bash upgrade.sh [--dry-run] vX.Y.Z [-- SETUP_OPTION VALUE ...]
#   bash upgrade.sh [--dry-run] --ref COMMIT_OR_BRANCH            (tests and development only; no support)
#
# Under the operator lock, from start to end:
#   1. back up (scripts/backup.sh) and prove the backup restores (scripts/verify-restore.sh)
#   2. fetch the tags and check the tag out (detached HEAD, the same as the "Major PostgreSQL upgrade" procedure)
#   3. rerun `setup.sh --operator` with this installation's own values
#   4. recreate the functions container (its code is bind-mounted and the edge runtime keeps what it loaded)
#   5. node scripts/doctor.mjs --local
#   6. print what CHANGELOG.md asks of the operator between the old and the new release
#   7. append one line to $WAREHOUSE_STATE_DIR/config/upgrades.log
#
# Before anything is changed it refuses: a dirty working tree, a name that is not a release tag on origin, a release
# that changes the PostgreSQL major (that is the separate "Major PostgreSQL upgrade" procedure), a database whose migration
# ledger names migrations the release does not contain (a new baseline, or a downgrade), and a release without upgrade.sh.
#
# Setup arguments. setup.sh needs --state-dir, --admin-phone and --admin-name; everything else is optional on a rerun and
# keeps what the state holds (identity, URLs, provider lines, central sign-in, gateway port, letterhead, signing keys).
# --state-dir is $WAREHOUSE_STATE_DIR. The administrator is read from the database (any active approved administrator
# matches setup's check; --admin-name is only used when none exists), or given with --admin-phone and --admin-name. The one
# value a state cannot show is "no Slack webhook" (--alert-webhook-file off): when none is stored, `off` is passed again, so
# setup does not stop to ask on a rerun. Options after `--` go to setup.sh as they are and win over those defaults.
#
# --dry-run runs every check and prints the plan. It does fetch the tags (git's object store only); nothing in the
# working tree, the state or the containers changes, and no line is written to upgrades.log.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: bash upgrade.sh [--dry-run] [--admin-phone 91XXXXXXXXXX --admin-name NAME] vX.Y.Z [-- SETUP_OPTION VALUE ...]
       bash upgrade.sh [--dry-run] --ref COMMIT_OR_BRANCH [...]      (tests and development only)
WAREHOUSE_STATE_DIR must name the installed operator state. docs/OPERATOR_INSTALL.md, "Rerun and upgrade".
EOF
}

SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
LOGGING=no
STEP='checks before anything is changed'
BACKUP_DIR=''
BACKUP_OUT=''
CHECKED_OUT=no
FROM_SHA=''
FROM_LABEL=''
TO_SHA=''
TO_LABEL=''
STATE=''

say() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
refuse() { printf 'Refusing: %s\n' "$*" >&2; exit 1; }
step() { STEP="$1"; printf '\n==> %s\n' "$1"; }

finish() {
  local code=$?
  trap - EXIT
  [[ -z "$BACKUP_OUT" ]] || rm -f "$BACKUP_OUT"
  if [[ "$LOGGING" == yes ]]; then
    local result=ok
    ((code == 0)) || result="failed at: $STEP (exit $code)"
    if ! (umask 077; printf '%s %s -> %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FROM_LABEL" "$TO_LABEL" "$result" >> "$STATE/config/upgrades.log") 2>/dev/null; then
      warn "could not write $STATE/config/upgrades.log"
    fi
    if ((code != 0)); then recovery_text >&2; fi
  fi
  exit "$code"
}

recovery_text() {
  echo
  echo "The upgrade stopped at: $STEP."
  [[ -z "$BACKUP_DIR" ]] || echo "The backup taken before the upgrade: $BACKUP_DIR"
  if [[ "$CHECKED_OUT" == yes ]]; then
    echo "This checkout is now at $TO_LABEL; it was at $FROM_LABEL ($FROM_SHA)."
    echo "Fix the cause shown above and run the same command again: it is safe to repeat."
    echo "To go back instead: (umask 022; git checkout --detach $FROM_SHA), then restore the backup above with the in-place"
    echo "restore (docs/OPERATOR_INSTALL.md, \"In-place restore of the same instance\")."
  else
    echo "The checkout was not changed (still at $FROM_LABEL). Fix the cause shown above and run the same command again."
  fi
}

# The CHANGELOG.md sections from the new release down to (not including) the old one: for each, its "Operator actions"
# subsection in full and the titles of the other subsections. A section without subsections is printed whole.
changelog_between() {
  local file="$1" from="$2" to="$3" only_one=0
  [[ -f "$file" ]] || { say 'This release has no CHANGELOG.md.'; return 0; }
  [[ "$from" != "$to" ]] || { say "Already at $to: nothing new to read."; return 0; }
  if ! grep -Eq "^## ${to}( |\$)" "$file"; then
    say "CHANGELOG.md has no section for $to. Read the release notes of $to on GitHub before you rely on this upgrade."
    return 0
  fi
  if [[ -z "$from" ]] || ! grep -Eq "^## ${from}( |\$)" "$file"; then only_one=1; fi
  awk -v from="$from" -v to="$to" -v only_one="$only_one" '
    function flush(   i, has_sub, in_ops, ops, others, t) {
      if (!open) return
      has_sub = 0
      for (i = 1; i <= sec_n; i++) if (sec[i] ~ /^### /) has_sub = 1
      print "== " heading
      if (!has_sub) {
        for (i = 1; i <= sec_n; i++) print sec[i]
      } else {
        in_ops = 0; ops = 0; others = ""
        for (i = 1; i <= sec_n; i++) {
          if (sec[i] ~ /^### /) {
            in_ops = (sec[i] ~ /^### Operator actions[[:space:]]*$/)
            if (in_ops) { ops = 1; print sec[i] }
            else { t = sec[i]; sub(/^### /, "", t); others = others (others == "" ? "" : ", ") t }
            continue
          }
          if (in_ops) print sec[i]
        }
        if (!ops) print "(no operator actions listed)"
        if (others != "") print "Also in this release: " others " (read CHANGELOG.md)."
      }
      print ""
      open = 0
      if (only_one) inrange = 0
    }
    /^## / {
      flush()
      name = $2
      if (name == to) inrange = 1
      else if (inrange && (name == from || name == "Older")) inrange = 0
      if (inrange) { open = 1; heading = substr($0, 4); sec_n = 0 }
      next
    }
    open { sec[++sec_n] = $0 }
    END { flush() }
  ' "$file"
}

# 0 when setup would find a Slack webhook in the state, 3 when none is stored, 4 when this checkout cannot tell.
webhook_stored() {
  # Paths go in the environment, not in argv: a module that finds its own path in argv[1] would run as a command.
  UPGRADE_MODULE="$ROOT/scripts/alert-webhook.mjs" UPGRADE_STATE="$STATE" \
    node -e 'import(require("url").pathToFileURL(process.env.UPGRADE_MODULE).href).then(m => process.exit(m.storedWebhook(process.env.UPGRADE_STATE) === null ? 3 : 0), () => process.exit(4))'
}

db_query() {
  bash "$ROOT/scripts/compose.sh" exec -T db psql -X -A -t -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "$1" < /dev/null
}

main() {
  local DRY=no REF='' TAG='' ADMIN_PHONE='' ADMIN_NAME='' ARG
  local -a SETUP_EXTRA=()
  while (($#)); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --dry-run) DRY=yes; shift ;;
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

  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/operator-lock.sh
  . "$ROOT/scripts/operator-lock.sh"
  STATE="$(operator_state)" || exit 1
  export WAREHOUSE_STATE_DIR="$STATE"
  command -v git >/dev/null || refuse 'git is not installed.'
  command -v node >/dev/null || refuse 'node is not on PATH (the operator scripts need it; docs/OPERATOR_INSTALL.md, "Host prerequisites").'
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || refuse "$ROOT is not a git checkout. upgrade.sh moves a git checkout from one release to another; a source archive is replaced by cloning the release again (docs/OPERATOR_INSTALL.md, \"Recover a lost host from the USB drive\")."
  cd "$ROOT"

  # --- checks that change nothing ---------------------------------------------------------------------------------
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    git status --short --untracked-files=no >&2
    refuse "this checkout has uncommitted changes to tracked files (listed above). Nothing was changed. Keep or drop them first: 'git stash' keeps them aside, 'git checkout -- <file>' drops one. Then run this command again."
  fi
  FROM_SHA="$(git rev-parse HEAD)"
  FROM_LABEL="$(git describe --tags --exact-match HEAD 2>/dev/null || git rev-parse --short HEAD)"
  local FROM_TAG
  FROM_TAG="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
  git remote get-url origin >/dev/null 2>&1 || refuse "this checkout has no remote named origin. Add it: git remote add origin https://github.com/abhiguru/supabase-warehouse-template.git"

  if [[ -n "$TAG" ]] && ! [[ "$TAG" =~ $SEMVER ]]; then
    refuse "'$TAG' is not a release tag. Give a tag such as v0.7.0 (the list is on the GitHub releases page; 'git tag --list \"v*\"' after 'git fetch --tags'). Only tagged releases are supported; --ref COMMIT_OR_BRANCH is for tests and development."
  fi
  if [[ -n "$REF" ]]; then
    warn "--ref $REF is not a release tag. Only tagged releases are supported: security fixes, the support window and the upgrade notes apply to tags, and a branch can hold changes that were never released."
  fi

  operator_lock "$STATE" || exit 1

  say "Installation: $STATE"
  say "Now at:       $FROM_LABEL"
  step 'Fetching tags from origin'
  if ! git fetch --tags origin; then
    if [[ -n "$REF" ]] && git rev-parse -q --verify "$REF^{commit}" >/dev/null; then
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
    TO_SHA="$(git rev-parse -q --verify "$REF^{commit}" || git rev-parse -q --verify "origin/$REF^{commit}" || true)"
    [[ -n "$TO_SHA" ]] || refuse "--ref $REF is neither a commit nor a branch of origin. Nothing was changed."
    TO_LABEL="$(git rev-parse --short "$TO_SHA") (--ref $REF)"
  fi

  git cat-file -e "$TO_SHA:upgrade.sh" 2>/dev/null || refuse "$TO_LABEL does not contain upgrade.sh, so its setup.sh cannot run under the lock this command holds. upgrade.sh moves to releases that ship it. For an earlier release use the manual sequence in docs/OPERATOR_INSTALL.md (\"Rerun and upgrade\", \"What upgrade.sh does\"). Nothing was changed."

  local PG_FROM PG_TO
  PG_FROM="$(bash "$ROOT/scripts/pg-major.sh")" || exit 1
  PG_TO="$(bash "$ROOT/scripts/pg-major.sh" "$TO_SHA")" || exit 1
  if [[ "$PG_FROM" != "$PG_TO" ]]; then
    refuse "$TO_LABEL runs PostgreSQL $PG_TO and this checkout runs PostgreSQL $PG_FROM. A new PostgreSQL major cannot be applied in place: follow docs/OPERATOR_INSTALL.md, \"Major PostgreSQL upgrade\" (it also gives the way back), then use upgrade.sh for later releases. Nothing was changed."
  fi

  # What needs the running database: the migration ledger against the release's migrations, and the administrator.
  local DB_OK=yes DB_NOTE='' APPLIED='' LINE=''
  if ! APPLIED="$(db_query 'SELECT name FROM warehouse_migrations.applied ORDER BY name' 2>&1)"; then
    DB_OK=no
    DB_NOTE="the database did not answer: ${APPLIED:0:300}"
  fi
  if [[ "$DB_OK" == yes ]]; then
    local release_names missing
    release_names="$(git ls-tree --name-only "$TO_SHA" migrations/ | sed 's|^migrations/||')"
    missing="$(comm -23 <(printf '%s\n' "$APPLIED" | sed '/^$/d' | sort) <(printf '%s\n' "$release_names" | sort) | head -n 5 | paste -sd, -)"
    if [[ -n "$missing" ]]; then
      refuse "this database recorded migrations that $TO_LABEL does not contain (for example: $missing). Either the release was rebuilt on a new baseline, which cannot be applied in place (docs/OPERATOR_INSTALL.md, \"Baseline reload\"), or $TO_LABEL is older than the one that recorded them: upgrade.sh only moves forward. Nothing was changed."
    fi
    if [[ -z "$ADMIN_PHONE" ]]; then
      LINE="$(db_query "SELECT mobile || '|' || coalesce(nullif(btrim(name), ''), 'Administrator') FROM public.user_profiles WHERE role = 'admin' AND active AND enrollment_status = 'approved' AND NOT is_service_account ORDER BY created_at LIMIT 1" 2>/dev/null || true)"
      ADMIN_PHONE="${LINE%%|*}"
      ADMIN_NAME="${LINE#*|}"
      [[ "$ADMIN_PHONE" =~ ^91[0-9]{10}$ && -n "$ADMIN_NAME" ]] || refuse "could not read the administrator from the database (setup needs it to check that the administrator is unchanged). Give --admin-phone 91XXXXXXXXXX --admin-name NAME. Nothing was changed."
    fi
  elif [[ "$DRY" == no ]]; then
    refuse "the database is not answering ($DB_NOTE). The backup needs it running and healthy: start it ('bash start.sh') and run this command again. Nothing was changed."
  fi

  local WEBHOOK_OFF=no code=0
  case " ${SETUP_EXTRA[*]+"${SETUP_EXTRA[*]}"} " in
    *" --alert-webhook-file "*) ;;
    *) webhook_stored || code=$?
       [[ "$code" -ne 3 ]] || WEBHOOK_OFF=yes ;;
  esac

  # --- the plan -------------------------------------------------------------------------------------------------------
  local MASKED='(not read: the database did not answer)'
  [[ -z "$ADMIN_PHONE" ]] || MASKED="${ADMIN_PHONE:0:2}******${ADMIN_PHONE: -4}"
  say
  say "Plan: $FROM_LABEL -> $TO_LABEL (PostgreSQL $PG_FROM stays)"
  say '  1. backup, then verify the backup in a disposable database'
  if [[ "$FROM_SHA" == "$TO_SHA" ]]; then say '  2. no checkout: this checkout is already at the release (the rest is repeated; this is how an interrupted upgrade is finished)'
  else say "  2. git checkout --detach ${TO_SHA:0:12}"; fi
  say "  3. setup.sh --operator --state-dir $STATE --admin-phone $MASKED --admin-name <administrator's name>$([[ "$WEBHOOK_OFF" == yes ]] && echo ' --alert-webhook-file off')${SETUP_EXTRA[*]+" ${SETUP_EXTRA[*]}"}"
  say '  4. docker compose up -d --force-recreate --no-deps functions'
  say '  5. node scripts/doctor.mjs --local'
  say '  6. print the operator actions of CHANGELOG.md between the two releases'
  say "  7. append a line to $STATE/config/upgrades.log"
  if [[ "$DRY" == yes ]]; then
    [[ "$DB_OK" == yes ]] || warn "not checked: the migration ledger and the administrator ($DB_NOTE)"
    say
    say 'Dry run: nothing was changed (the tags were fetched into git; the working tree, the state and the containers are as they were).'
    exit 0
  fi

  # --- the upgrade ----------------------------------------------------------------------------------------------------
  LOGGING=yes
  trap finish EXIT
  say
  say 'The facility is unavailable for part of this: the backup pauses the API, and setup restarts services. The monitoring checker stays quiet while this command holds the operator lock.'

  step 'Backup'
  BACKUP_OUT="$(mktemp)"
  bash "$ROOT/scripts/backup.sh" | tee "$BACKUP_OUT"
  BACKUP_DIR="$(sed -n 's/^Backup created at \(\/.*\)$/\1/p' "$BACKUP_OUT" | tail -n 1)"
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || { echo 'The backup finished but did not report its directory.' >&2; exit 1; }

  step 'Verify the backup restores'
  bash "$ROOT/scripts/verify-restore.sh" "$BACKUP_DIR"

  if [[ "$FROM_SHA" == "$TO_SHA" ]]; then
    step "Checkout: already at $TO_LABEL"
  else
    step "Checkout: $TO_LABEL"
    # umask 022 as for the first clone: files written under 0002 or 077 are refused by the root-run helpers or unreadable by the containers.
    (umask 022; git checkout --detach "$TO_SHA")
    bash "$ROOT/scripts/checkout-permissions.sh" --quiet
  fi
  CHECKED_OUT=yes

  step 'Setup (the same inputs as the installation)'
  # setup.sh of the new release; it runs under this command's lock (operator_lock_or_inherited).
  local -a SETUP=(--operator --state-dir "$STATE" --admin-phone "$ADMIN_PHONE" --admin-name "$ADMIN_NAME")
  [[ "$WEBHOOK_OFF" == no ]] || SETUP+=(--alert-webhook-file off)
  bash "$ROOT/setup.sh" "${SETUP[@]}" "${SETUP_EXTRA[@]+"${SETUP_EXTRA[@]}"}"

  step 'Recreate the functions container'
  bash "$ROOT/scripts/compose.sh" up -d --force-recreate --no-deps --wait --wait-timeout 180 functions

  step 'Local doctor'
  node "$ROOT/scripts/doctor.mjs" --local

  step "What $TO_LABEL asks of the operator"
  local CL_TO="$TAG"
  [[ -n "$TAG" ]] || CL_TO=Unreleased
  changelog_between "$ROOT/CHANGELOG.md" "$FROM_TAG" "$CL_TO"

  step 'Done'
  say "Upgraded $FROM_LABEL -> $TO_LABEL. The backup taken first: $BACKUP_DIR"
  say 'Still to do by hand when they apply:'
  say '  - a "sudo bash scripts/watch-timer.sh ..." command printed by setup above (the monitoring checker timer)'
  say "  - a USB backup drive: sudo bash scripts/backup-usb.sh setup --state \"\$WAREHOUSE_STATE_DIR\"   (it prints your earlier choices; check that line)"
  say '  - the public check: node scripts/doctor.mjs'
  say "  - the operator actions listed above"
}
main "$@"; exit $?
