#!/usr/bin/env bash
# One command to move an installed facility to a tagged release (docs/OPERATOR_INSTALL.md, "Rerun and upgrade").
#
#   export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
#   bash upgrade.sh [--dry-run] vX.Y.Z [-- SETUP_OPTION VALUE ...]
#   bash upgrade.sh [--dry-run] --ref COMMIT_OR_BRANCH            (tests and development only; no support)
#
# Under the operator lock, from start to end:
#   1. back up (scripts/backup.sh) and prove the backup restores (scripts/verify-restore.sh), on the OLD release
#   2. fetch the tags and check the tag out (detached HEAD, the same as the "Major PostgreSQL upgrade" procedure)
#   3. rerun `setup.sh --operator` of the NEW release with this installation's own values. Setup also recreates the
#      `functions` container (its code is bind-mounted and the edge runtime keeps what it loaded) and ends with
#      `doctor --local`: everything that depends on the release being moved to lives in that release's setup.sh,
#      because from the checkout on, this script is the OLD release's, still running from memory
#   4. print what CHANGELOG.md asks of the operator between the old and the new release
#   5. append one line to $WAREHOUSE_STATE_DIR/config/upgrades.log
#
# Before anything is changed it refuses: running as root, a dirty working tree, untracked files the release would overwrite, a name
# that is not a release tag on origin, a release the checkout is already past (it only moves forward), a release that changes the
# PostgreSQL major (that is the separate "Major PostgreSQL upgrade" procedure), a database whose migration ledger names migrations the
# release does not contain (a new baseline, or a downgrade), a stored Slack webhook file that setup would not accept, and a release
# without upgrade.sh.
#
# An interrupted upgrade can be finished or undone. Before the first change the script writes $WAREHOUSE_STATE_DIR/config/
# upgrade-in-progress (mode 0600; scripts/upgrade-record.mjs reads it): the old commit, the target, the setup inputs and the
# current step; once the backup is verified, also the backup's path. A rerun of the same command (the database may be down)
# reads it, reuses that backup and takes no new one of the half-upgraded database, and names the right old commit. Success deletes
# it; doctor, start.sh and the status commands report it while it exists. When a step fails the script prints the way forward and
# the complete way back (the old commit, stop, the in-place restore of that backup with --restore-config, the old release's
# setup, the functions recreate, doctor).
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
CMD_TEXT=''
ORIG_ARGS=()
# What load_record found: none, unverified (the old release was only being backed up), verified, invalid.
REC=none
R_FROM_SHA='' R_FROM_LABEL='' R_FROM_TAG='' R_TO_SHA='' R_TO_LABEL='' R_BACKUP='' R_STARTED='' R_STEP='' R_ADMIN_PHONE='' R_ADMIN_NAME='' R_WEBHOOK_OFF=''

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

# Version order for the CHANGELOG.md sections and for "this checkout is already past that release": major.minor.patch as
# numbers, a pre-release before its release (semver 2.0, build metadata ignored). Used by awk below.
AWK_SEMVER='
function semver_cmp(a, b,   ra, rb, na, nb, pa, pb, ia, ib, ca, cb, i, x, y, xn, yn) {
  sub(/^v/, "", a); sub(/^v/, "", b); sub(/\+.*/, "", a); sub(/\+.*/, "", b)
  ra = ""; rb = ""
  if (index(a, "-")) { ra = substr(a, index(a, "-") + 1); a = substr(a, 1, index(a, "-") - 1) }
  if (index(b, "-")) { rb = substr(b, index(b, "-") + 1); b = substr(b, 1, index(b, "-") - 1) }
  na = split(a, pa, "."); nb = split(b, pb, ".")
  for (i = 1; i <= 3; i++) {
    x = (i <= na) ? pa[i] + 0 : 0; y = (i <= nb) ? pb[i] + 0 : 0
    if (x != y) return (x < y) ? -1 : 1
  }
  if (ra == "" && rb == "") return 0
  if (ra == "") return 1
  if (rb == "") return -1
  ca = split(ra, ia, "."); cb = split(rb, ib, ".")
  for (i = 1; i <= ca && i <= cb; i++) {
    x = ia[i]; y = ib[i]; xn = (x ~ /^[0-9]+$/); yn = (y ~ /^[0-9]+$/)
    if (xn && yn) { if (x + 0 != y + 0) return (x + 0 < y + 0) ? -1 : 1 }
    else if (xn) return -1
    else if (yn) return 1
    else if (x != y) return (x < y) ? -1 : 1
  }
  if (ca != cb) return (ca < cb) ? -1 : 1
  return 0
}'
semver_lt() { awk -v a="$1" -v b="$2" "$AWK_SEMVER"' BEGIN { exit !(semver_cmp(a, b) < 0) }'; }
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

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
      # Nothing of the facility changed: no half-done upgrade to report, and a rerun takes a fresh backup.
      if facility_unchanged; then record_remove; fi
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

# The CHANGELOG.md sections from the new release down to (not including) the old one: for each, its "Operator actions"
# subsection in full and the titles of the other subsections. A section without subsections is printed whole. When the old
# release has no section (a backport tag's section lives on its release branch, not on main), every section is printed down to
# the first one that is not newer than the old release, by version order. A pre-release tag (v0.7.0-rc.1) uses its release's section.
changelog_between() {
  local file="$1" from="$2" to="$3" mode=range
  [[ -f "$file" ]] || { say 'This release has no CHANGELOG.md.'; return 0; }
  [[ "$from" != "$to" ]] || { say "Already at $to: nothing new to read."; return 0; }
  if ! grep -Eq "^## $(re_escape "$to")( |\$)" "$file"; then
    local base="${to%%-*}"
    if [[ "$base" != "$to" ]] && grep -Eq "^## $(re_escape "$base")( |\$)" "$file"; then
      to="$base"
    else
      say "CHANGELOG.md has no section for $to. Read the release notes of $to on GitHub before you rely on this upgrade."
      return 0
    fi
  fi
  if [[ -z "$from" ]]; then mode=one
  elif ! grep -Eq "^## $(re_escape "$from")( |\$)" "$file"; then mode=below; fi
  awk -v from="$from" -v to="$to" -v mode="$mode" "$AWK_SEMVER"'
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
      if (mode == "one") inrange = 0
    }
    /^## / {
      flush()
      name = $2
      if (name == to) inrange = 1
      else if (inrange && (name == from || name == "Older" || (mode == "below" && name ~ /^v[0-9]/ && semver_cmp(name, from) <= 0))) inrange = 0
      if (inrange) { open = 1; heading = substr($0, 4); sec_n = 0 }
      next
    }
    open { sec[++sec_n] = $0 }
    END { flush() }
  ' "$file"
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

  trap 'rm -f -- "$BACKUP_OUT" "$DB_ERR"' EXIT
  DB_ERR="$(mktemp)"
  ((EUID != 0)) || refuse 'upgrade.sh must run as the installation user (the owner of this checkout and of the state, a member of the docker group), not as root and not with sudo: root cannot read the files the way the installation does, and git refuses a checkout it does not own.'
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/operator-lock.sh
  . "$ROOT/scripts/operator-lock.sh"
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
           3) WEBHOOK_OFF=yes ;;
           5) refuse "the Slack webhook file in the state does not hold a Slack incoming-webhook URL (https://hooks.slack.com/services/...), so setup would ask for one and, without a terminal, stop after the checkout. Replace it ('docs/MONITORING.md', \"Alert delivery\"), or add '-- --alert-webhook-file PATH' (a file holding the URL) or '-- --alert-webhook-file off' to this command. Nothing was changed." ;;
         esac
       fi ;;
  esac

  # --- the plan -------------------------------------------------------------------------------------------------------
  local MASKED='(not read: the database did not answer)'
  [[ -z "$ADMIN_PHONE" ]] || MASKED="${ADMIN_PHONE:0:2}******${ADMIN_PHONE: -4}"
  say
  say "Plan: $FROM_LABEL -> $TO_LABEL (PostgreSQL $PG_FROM stays)"
  if [[ "$RESUME" == yes ]]; then say "  1. no new backup: the one taken and verified before this upgrade began is reused ($BACKUP_DIR); the database may be half upgraded"
  else say '  1. backup, then verify the backup in a disposable database'; fi
  if [[ "$FROM_SHA" == "$TO_SHA" ]]; then say '  2. no checkout: this checkout is already at the release (the rest is repeated)'
  elif [[ "$(git rev-parse HEAD)" == "$TO_SHA" ]]; then say '  2. no checkout: this checkout is already at the release (the interrupted upgrade got that far)'
  else say "  2. git checkout --detach ${TO_SHA:0:12}"; fi
  say "  3. setup.sh --operator --state-dir $STATE --admin-phone $MASKED --admin-name <administrator's name>$([[ "$WEBHOOK_OFF" == yes ]] && echo ' --alert-webhook-file off')${SETUP_EXTRA[*]+" ${SETUP_EXTRA[*]}"}"
  say '     (setup of the release also recreates the functions container and ends with node scripts/doctor.mjs --local)'
  say '  4. print the operator actions of CHANGELOG.md between the two releases'
  say "  5. append a line to $STATE/config/upgrades.log and remove $RECORD"
  if [[ "$DRY" == yes ]]; then
    [[ "$DB_OK" == yes ]] || warn "not checked: the migration ledger and the administrator ($DB_NOTE)"
    say
    say 'Dry run: nothing was changed (the tags were fetched into git; the working tree, the state and the containers are as they were).'
    exit 0
  fi

  # --- the upgrade ----------------------------------------------------------------------------------------------------
  LOGGING=yes
  trap finish EXIT
  # doctor and the status commands do not call a run in progress "interrupted".
  export WAREHOUSE_UPGRADE_RUNNING=1
  say
  say 'The facility is unavailable for part of this: the backup pauses the API, and setup restarts services. The monitoring checker stays quiet while this command holds the operator lock.'
  say 'Run it in tmux or screen when you are connected over SSH: a dropped connection would stop it half way (the rerun finishes it).'

  if [[ "$RESUME" == yes ]]; then
    STAGE=checkout
    RECORD_LIVE=yes
    step "Resuming: the backup taken before the upgrade began is reused"
    say "Backup, verified before the first change: $BACKUP_DIR"
  else
    STAGE=backup
    RECORD_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    RECORD_LIVE=yes
    # Before the first change: from here on a rerun, doctor and start.sh can say what was going on. Without the record there is no start.
    STEP='Backup'
    record_write || { echo "Could not write the upgrade record $RECORD. Nothing was changed." >&2; exit 1; }
    step 'Backup'
    BACKUP_OUT="$(mktemp)"
    bash "$ROOT/scripts/backup.sh" | tee "$BACKUP_OUT"
    BACKUP_DIR="$(sed -n 's/^Backup created at \(\/.*\)$/\1/p' "$BACKUP_OUT" | tail -n 1)"
    [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || { echo 'The backup finished but did not report its directory.' >&2; exit 1; }

    step 'Verify the backup restores'
    bash "$ROOT/scripts/verify-restore.sh" "$BACKUP_DIR"
    # The backup is proved: from here the record names it, and a rerun reuses it.
    VERIFIED=yes
    STAGE=checkout
  fi

  if [[ "$(git rev-parse HEAD)" == "$TO_SHA" ]]; then
    step "Checkout: already at $TO_LABEL"
  else
    step "Checkout: $TO_LABEL"
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
