#!/usr/bin/env bash
# Optional encrypted off-site copy of the backups to an S3-compatible bucket the facility owns (WH-145). Off by default.
#
#   offsite.sh on  --endpoint URL --bucket NAME --credentials-file FILE [--region R] [--max-rate MB/S]
#                          check the bucket (write, read, delete a test object; refuse one that anyone can read), store the
#                          settings in <state>/config/offsite.conf and the credentials in <state>/config/offsite.credentials
#                          (mode 0600), and turn the nightly upload on. After `off`, `on` with no options turns it on again.
#   offsite.sh off         stop the uploads; the bucket and its contents are left alone
#   offsite.sh status      the settings (never the credentials) and the result of the last upload; reads no network
#   offsite.sh run [DIR]   upload one backup (default: the newest backup that authenticates), check it, apply the retention.
#                          Run by scripts/watch-daily.sh after the backup of the night; run by hand for the first upload
#                          (a large first upload may need more than the nightly time limit; an interrupted run continues).
#   offsite.sh list        the backups in the bucket under this installation's backup key
#   offsite.sh verify [--deep] [NAME]
#                          check a backup in the bucket (default: the newest): every object it needs is there with the right size;
#                          --deep also downloads and decrypts every object and checks it against its name
#   offsite.sh keep-list   reads backup names (warehouse-<utc>) on standard input, prints those the retention keeps (no network)
#   offsite.sh fetch --endpoint URL --bucket NAME --credentials-file FILE --backup-key KEYFILE --dest DIR [--region R] [--backup NAME]
#                          rebuild one backup (default: the newest) as an ordinary backup directory DEST/<name> from the bucket;
#                          needs no installation. scripts/restore-host.sh --from-offsite does this and then restores from it.
#
# How the copy is made. The tool that talks to the bucket is rclone (the S3 backend), which must be installed on the host; it only moves
# bytes. Everything is encrypted here first, with the backup key and the cipher the USB archives use (scripts/backup-key.sh): the provider
# holds nothing readable, and no file name of the backup.
#   - Each file of the backup is packed as a one-file tar (path, mode and extended attributes, no time of access) and stored as an
#     object named by an HMAC of the tar's SHA-256 under the backup key: a file the earlier night already sent has the same name and
#     is not sent again. A night costs the new photos and the database dump.
#   - The backup's own list of its files (the manifest: path, mode, size, object name) is encrypted and signed with the backup key and
#     uploaded last, so an interrupted upload leaves only objects that no manifest names yet.
#   - Names in the bucket (under warehouse-offsite/k-<key fingerprint>/): objects/<64 hex>, backups/<warehouse-utc>.manifest. The
#     backup names (their times) are visible to the provider; nothing else is. A new backup key starts a new set (k-<other>); the old
#     set stays, is never touched by the new key, and needs the old key to be opened.
#   - A restore rebuilds the backup directory and gives it to the usual restore, which checks the signed SHA256SUMS and the
#     storage tree against the backup key: a changed or swapped object in the bucket cannot get through that.
# Checks after an upload: every object the manifest names is listed with the size it should have; each object uploaded in this run, the
# manifest, and a seventh of all objects (a different seventh each weekday, so each object is read back weekly) are downloaded,
# decrypted and checked against their own name. Any mismatch is a failed upload.
# Retention in the bucket (this key's set): the last 14 backups and the first backup of each of the last 12 calendar months; the others'
# manifests are removed, then every object no kept manifest names and older than 2 days. Nothing is removed unless every kept manifest
# could be read.
# The credentials: a file of two lines (access_key_id=..., secret_access_key=...), copied to config/offsite.credentials (0600, never
# part of a backup: backup.sh copies named files only), handed to rclone through its environment and not through a command line,
# and removed from every message before it is printed. Plain http is refused except to a loopback address.
# Test seam (the CI drill): WAREHOUSE_OFFSITE_TEST_DIR=/absolute/dir makes a directory stand in for the bucket (<dir>/<bucket>), no network.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "$*" >&2; exit 1; }
# shellcheck source=scripts/backup-key.sh
source "$ROOT/scripts/backup-key.sh"

KEEP_NIGHTLY=14 KEEP_MONTHS=12 GC_MIN_AGE=2d
OFF_ENDPOINT='' OFF_BUCKET='' OFF_REGION='' OFF_RATE='' OFF_AKID='' OFF_SECRET=''
WORK='' RC_ERR=''
cleanup() { local s=$?; trap - EXIT; [[ -z "$WORK" ]] || rm -rf -- "$WORK"; exit "$s"; }
trap cleanup EXIT

# ---------------------------------------------------------------- retention (pure)
# Names on standard input; the names to keep on standard output, oldest first.
keep_list() {
  LC_ALL=C sort -u | awk -v nightly="$KEEP_NIGHTLY" -v months="$KEEP_MONTHS" '
    /^warehouse-[0-9]{8}T[0-9]{6}Z$/ { name[++n] = $0 }
    END {
      if (!n) exit
      for (i = 1; i <= n; i++) { y = substr(name[i], 11, 4) + 0; m = substr(name[i], 15, 2) + 0; idx[i] = y * 12 + m - 1 }
      newest = idx[n]
      for (i = 1; i <= n; i++) {
        if (i > n - nightly) keep[i] = 1
        if (idx[i] > newest - months && !(idx[i] in first)) { first[idx[i]] = i; keep[i] = 1 }
      }
      for (i = 1; i <= n; i++) if (i in keep) print name[i]
    }'
}

# ---------------------------------------------------------------- settings
valid_endpoint() { [[ "$1" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ || "$1" =~ ^http://(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\])(:[0-9]+)?$ ]]; }
valid_bucket() { [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ && "$1" != *..* ]]; }
valid_region() { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9-]{1,40}$ ]]; }
valid_rate() { [[ -z "$1" || "$1" =~ ^[1-9][0-9]{0,5}$ ]]; }

# Reads FILE (access_key_id= and secret_access_key= lines) into OFF_AKID and OFF_SECRET. The file must be a regular file of this
# user with mode 0600: credentials left readable to others are refused, not tolerated.
read_credentials() {
  local file="$1" key value line
  [[ -f "$file" && ! -L "$file" ]] || { echo "The credentials file $file is not a regular file." >&2; return 1; }
  [[ "$(stat -c %u -- "$file")" == "$(id -u)" && "$(stat -c %a -- "$file")" == 600 ]] || { echo "The credentials file $file must belong to this user with mode 0600 (chmod 600 it)." >&2; return 1; }
  OFF_AKID='' OFF_SECRET=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -n "$line" && "$line" != '#'* ]] || continue
    key="${line%%=*}" value="${line#*=}"
    [[ "$line" == *=* && "$value" =~ ^[A-Za-z0-9/+=._-]{8,200}$ ]] || { echo "The credentials file has a line that is not access_key_id=... or secret_access_key=... (values are not printed)." >&2; return 1; }
    case "$key" in access_key_id) OFF_AKID="$value" ;; secret_access_key) OFF_SECRET="$value" ;; *) echo "The credentials file has an unknown key '$key'." >&2; return 1 ;; esac
  done < "$file"
  [[ -n "$OFF_AKID" && -n "$OFF_SECRET" ]] || { echo 'The credentials file needs both access_key_id= and secret_access_key=.' >&2; return 1; }
}

conf_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
load_conf() {
  local state="$1" conf="$1/config/offsite.conf"
  [[ -f "$conf" && ! -L "$conf" ]] || { echo 'The off-site copy is not set up: bash scripts/offsite.sh on --endpoint ... (docs/OPERATOR_INSTALL.md, "Off-site copy").' >&2; return 1; }
  OFF_ENDPOINT="$(conf_get "$conf" ENDPOINT)" OFF_BUCKET="$(conf_get "$conf" BUCKET)" OFF_REGION="$(conf_get "$conf" REGION)" OFF_RATE="$(conf_get "$conf" MAX_RATE)"
  valid_endpoint "$OFF_ENDPOINT" && valid_bucket "$OFF_BUCKET" && valid_region "$OFF_REGION" && valid_rate "$OFF_RATE" || { echo "$conf is not valid; run offsite.sh on again." >&2; return 1; }
  read_credentials "$state/config/offsite.credentials"
}

# ---------------------------------------------------------------- the bucket (rclone)
need_rclone() {
  command -v rclone >/dev/null 2>&1 || { echo 'rclone is not installed. Install it (apt install rclone, or https://rclone.org/install/) and run this again.' >&2; return 1; }
  local v; v="$(rclone version 2>/dev/null | sed -n '1s/^rclone v\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  [[ -n "$v" ]] || { echo 'rclone version could not be read.' >&2; return 1; }
  set -- $v
  (($1 > 1 || $2 >= 60)) || { echo "rclone $1.$2 is too old (1.60 or newer is needed)." >&2; return 1; }
}
make_work() {
  [[ -z "$WORK" ]] || return 0
  local base="${1:-${TMPDIR:-/tmp}}"
  WORK="$(mktemp -d "$base/.offsite-work.XXXXXX")"
}
# Runs rclone against the remote called offsite. The credentials reach it through the environment of a subshell, so they are on no
# command line and not in the environment of any other command. Its error text goes to $RC_ERR with the credentials taken out.
rc() {
  local status=0 errf="$WORK/rclone.err" text
  (
    export RCLONE_CONFIG=/dev/null RCLONE_CONFIG_OFFSITE_NO_CHECK_BUCKET=true
    if [[ -n "${WAREHOUSE_OFFSITE_TEST_DIR:-}" ]]; then
      export RCLONE_CONFIG_OFFSITE_TYPE=local
    else
      export RCLONE_CONFIG_OFFSITE_TYPE=s3 RCLONE_CONFIG_OFFSITE_PROVIDER=Other RCLONE_CONFIG_OFFSITE_ENDPOINT="$OFF_ENDPOINT" \
        RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID="$OFF_AKID" RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY="$OFF_SECRET" RCLONE_CONFIG_OFFSITE_ENV_AUTH=false
      [[ -z "$OFF_REGION" ]] || export RCLONE_CONFIG_OFFSITE_REGION="$OFF_REGION"
    fi
    exec rclone "$@" ${OFF_RATE:+--bwlimit "${OFF_RATE}M"} --retries 3 --low-level-retries 5 --contimeout 30s --timeout 5m -q
  ) 2>"$errf" || status=$?
  text="$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | tail -n 1 | cut -c1-300 || true)"
  [[ -z "$OFF_SECRET" ]] || text="${text//"$OFF_SECRET"/***}"
  [[ -z "$OFF_AKID" ]] || text="${text//"$OFF_AKID"/***}"
  RC_ERR="$text"
  return "$status"
}
remote_root() {
  if [[ -n "${WAREHOUSE_OFFSITE_TEST_DIR:-}" ]]; then
    [[ "$WAREHOUSE_OFFSITE_TEST_DIR" == /* ]] || die 'WAREHOUSE_OFFSITE_TEST_DIR must be an absolute path.'
    printf 'offsite:%s/%s\n' "${WAREHOUSE_OFFSITE_TEST_DIR%/}" "$OFF_BUCKET"
  else
    printf 'offsite:%s\n' "$OFF_BUCKET"
  fi
}
# BASE: this key's set in the bucket.
set_base() { BASE="$(remote_root)/warehouse-offsite/k-$(backup_key_fingerprint "$BACKUP_KEY")"; }
# "size path" lines of a remote folder (empty when it does not exist yet).
remote_list() { rc lsf -R --files-only --format sp --separator ' ' "$@" 2>/dev/null || { [[ "${RC_ERR,,}" == *"not found"* || "${RC_ERR,,}" == *"directory"*"found"* ]] && return 0; return 1; }; }

# ---------------------------------------------------------------- status file
status_file() { printf '%s/config/offsite.last\n' "$1"; }
# write_status STATE ok|failed MESSAGE [key=value ...]: last_success_epoch moves only on ok (a verified upload).
write_status() {
  local state="$1" result="$2" message="$3" file now prev success deep tmp; shift 3
  file="$(status_file "$state")"; now="$(date +%s)"
  prev="$(cat -- "$file" 2>/dev/null || true)"
  success="$(sed -n 's/^last_success_epoch=//p' <<<"$prev" | head -n 1)"; success="${success:-0}"
  [[ "$result" != ok ]] || success="$now"
  tmp="$(mktemp "$file.XXXXXX")"
  {
    printf 'result=%s\nfinished_utc=%s\nfinished_epoch=%s\nlast_success_epoch=%s\n' "$result" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" "$now" "$success"
    printf 'message=%s\n' "$(printf '%s' "$message" | tr '\r\n' '  ' | cut -c1-400)"
    (($#)) && printf '%s\n' "$@"
  } > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$file"
}

# ---------------------------------------------------------------- manifest
MANIFEST_HEADER=warehouse-offsite-manifest-v1
manifest_mac() { backup_hmac "$BACKUP_KEY" warehouse-offsite-manifest-v1 < "$1"; }
# The object name of a one-file tar (given by its SHA-256): an HMAC, so the provider cannot test a guess about a file's content.
object_id() { backup_hmac "$BACKUP_KEY" warehouse-offsite-object-v1 <<<"$1"; }
# read_manifest FILE_ENCRYPTED NAME OUT: decrypt, check the signature and the header, leave the plain manifest in OUT.
read_manifest() {
  local enc="$1" name="$2" out="$3" body="$3.body" last mac
  backup_decrypt "$BACKUP_KEY" < "$enc" > "$out" 2>/dev/null || { echo "The manifest of $name does not decrypt with this backup key." >&2; return 1; }
  last="$(tail -n 1 -- "$out")"
  [[ "$last" =~ ^mac\ ([0-9a-f]{64})$ ]] || { echo "The manifest of $name is not valid (no signature)." >&2; return 1; }
  mac="${BASH_REMATCH[1]}"
  head -n -1 -- "$out" > "$body"
  [[ "$(manifest_mac "$body")" == "$mac" ]] || { echo "The manifest of $name does not match the backup key (changed in the bucket, or made with another key)." >&2; return 1; }
  [[ "$(sed -n 1p "$body")" == "$MANIFEST_HEADER" && "$(sed -n 2p "$body")" == "backup $name" ]] || { echo "The manifest of $name is for another backup or format." >&2; return 1; }
  mv -f -- "$body" "$out"
}
# Calls CMD MODE SIZE ID PATH for each file line of a plain manifest.
valid_relpath() { [[ -n "$1" && "$1" != /* && "$1" != */ && "$1" != *$'\n'* && "$1" != ".." && "$1" != ../* && "$1" != */../* && "$1" != */.. && "$1" != . && "$1" != ./* && "$1" != */./* ]]; }

# Download one object and check it is what its name says (decrypt, hash the tar, HMAC); the tar is left in OUT when given.
fetch_object() {
  local id="$1" out="${2:-/dev/null}" sum
  rc cat "$BASE/objects/$id" > "$WORK/obj.enc" || { echo "Could not download object ${id:0:12}...: $RC_ERR" >&2; return 1; }
  backup_decrypt "$BACKUP_KEY" < "$WORK/obj.enc" > "$WORK/obj.tar" 2>/dev/null || { echo "Object ${id:0:12}... does not decrypt." >&2; return 1; }
  sum="$(sha256sum < "$WORK/obj.tar" | cut -d' ' -f1)"
  [[ "$(object_id "$sum")" == "$id" ]] || { echo "Object ${id:0:12}... in the bucket is not what its name says (changed or damaged)." >&2; return 1; }
  [[ "$out" == /dev/null ]] || mv -f -- "$WORK/obj.tar" "$out"
  rm -f -- "$WORK/obj.enc" "$WORK/obj.tar"
}

# verify_manifest PLAIN_MANIFEST MODE [IDFILE]: sizes of all objects; deep (download and check) for MODE=all, MODE=slice (the objects whose
# name falls in today's seventh) and the ids listed in IDFILE. Prints the problems; returns non-zero if there is one.
verify_manifest() {
  local manifest="$1" mode="$2" idfile="${3:-}" line size id dow bad=0 checked=0 listing
  local -A have=() deep=()
  dow="$(date -u +%w)"
  listing="$(remote_list "$BASE/objects")" || { echo "Could not list the bucket: $RC_ERR" >&2; return 1; }
  while read -r size id; do [[ -z "$id" ]] || have[$id]="$size"; done <<<"$listing"
  if [[ -n "$idfile" && -f "$idfile" ]]; then while read -r id; do [[ -z "$id" ]] || deep[$id]=1; done < "$idfile"; fi
  while IFS= read -r line; do
    [[ "$line" =~ ^F\ ([0-7]{3,4})\ ([0-9]+)\ ([0-9a-f]{64})\ (.+)$ ]] || continue
    size="${BASH_REMATCH[2]}" id="${BASH_REMATCH[3]}"
    if [[ -z "${have[$id]:-}" ]]; then echo "Missing in the bucket: ${BASH_REMATCH[4]}" >&2; bad=$((bad + 1)); continue; fi
    if [[ "${have[$id]}" != "$((size + 16))" ]]; then echo "Wrong size in the bucket: ${BASH_REMATCH[4]}" >&2; bad=$((bad + 1)); continue; fi
    if [[ "$mode" == all || -n "${deep[$id]:-}" || ( "$mode" == slice && $((16#${id:0:6} % 7)) == "$dow" ) ]]; then
      checked=$((checked + 1))
      fetch_object "$id" || bad=$((bad + 1))
    fi
  done < "$manifest"
  VERIFIED_DEEP=$checked
  ((bad == 0)) || { echo "$bad problem(s) in the copy in the bucket." >&2; return 1; }
}

# ---------------------------------------------------------------- upload
# The newest backup directory that authenticates (signature and list; not the whole tree, which backup.sh and the verify did).
newest_backup() {
  local state="$1" d
  while IFS= read -r d; do
    if BACKUP_TREE=skip WAREHOUSE_BACKUP_KEY_FILE="$state/config/backup.key" backup_authenticate "$d" false >/dev/null 2>&1; then printf '%s\n' "$d"; return 0; fi
  done < <(find "$state/backups" -mindepth 1 -maxdepth 1 -type d -name 'warehouse-????????T??????Z' -print | LC_ALL=C sort -r)
  return 1
}

cmd_run() {
  local state dir name now manifest plain have_file listing size id sum path mode line count=0 sent=0 sent_bytes=0 ptr kept
  state="$(. "$ROOT/scripts/operator-lock.sh"; operator_state)" || exit 1
  . "$ROOT/scripts/operator-lock.sh"
  [[ "$(conf_get "$state/config/offsite.conf" ENABLED)" == yes ]] || { echo 'The off-site copy is off.' >&2; exit 0; }
  fail() { write_status "$state" failed "$1" "${@:2}" || true; echo "Off-site copy failed: $1" >&2; exit 1; }
  load_conf "$state" || fail "settings or credentials are not usable (see the message above)"
  need_rclone || fail 'rclone is not usable on this host'
  backup_key_load "$state/config/backup.key" || fail 'the backup key is not usable'
  backup_escrow_ok "$state" || fail "the backup key copy is not confirmed (${BACKUP_ESCROW_PROBLEM}); without the key the off-site copy cannot be opened: bash scripts/backup-key-escrow.sh show"
  operator_lock_or_inherited "$state" 2>/dev/null || fail 'another operator command holds the lock'
  dir="${1:-}"
  if [[ -z "$dir" ]]; then dir="$(newest_backup "$state")" || fail 'there is no backup that authenticates'; fi
  dir="${dir%/}"; name="$(basename -- "$dir")"
  [[ "$name" =~ ^warehouse-[0-9]{8}T[0-9]{6}Z$ && -d "$dir" && ! -L "$dir" ]] || fail "not a backup directory: $dir"
  BACKUP_TREE=skip WAREHOUSE_BACKUP_KEY_FILE="$state/config/backup.key" backup_authenticate "$dir" false >/dev/null 2>&1 || fail "$name does not authenticate; it was not uploaded"
  make_work "$state/backups"
  set_base
  now="$(date +%s)"

  listing="$(remote_list "$BASE/objects")" || fail "could not list the bucket: ${RC_ERR:-no detail} (check the credentials and the network)"
  local -A have=()
  while read -r size id; do [[ -z "$id" ]] || have[$id]="$size"; done <<<"$listing"

  plain="$WORK/manifest.plain"; : > "$plain.body"
  : > "$WORK/new.ids"
  printf '%s\nbackup %s\nkey %s\n' "$MANIFEST_HEADER" "$name" "$(backup_key_fingerprint "$BACKUP_KEY")" > "$plain.body"
  while IFS= read -r -d '' path; do
    [[ "$path" != *$'\n'* ]] || fail "a file name with a line break in $name cannot be sent"
    valid_relpath "$path" || fail "an unusable file name in $name"
    if [[ -d "$dir/$path" ]]; then
      printf 'D %s %s\n' "$(stat -c %a -- "$dir/$path")" "$path" >> "$plain.body"; continue
    fi
    [[ -f "$dir/$path" && ! -L "$dir/$path" ]] || fail "$path in $name is not a plain file"
    count=$((count + 1))
    tar --xattrs --xattrs-include='user.*' --format=posix --pax-option=delete=atime,delete=ctime --numeric-owner --owner=0 --group=0 \
      --no-recursion -C "$dir" -cf "$WORK/file.tar" -- "$path" || fail "could not pack $path"
    sum="$(sha256sum < "$WORK/file.tar" | cut -d' ' -f1)"; size="$(stat -c %s -- "$WORK/file.tar")"
    id="$(object_id "$sum")"; mode="$(stat -c %a -- "$dir/$path")"
    if [[ -z "${have[$id]:-}" || "${have[$id]}" != "$((size + 16))" ]]; then
      backup_encrypt "$BACKUP_KEY" < "$WORK/file.tar" > "$WORK/file.enc" || fail "could not encrypt $path"
      rc copyto "$WORK/file.enc" "$BASE/objects/$id" || fail "the bucket refused the upload of a file: ${RC_ERR:-no detail} (credentials, quota or network)"
      have[$id]="$size"; sent=$((sent + 1)); sent_bytes=$((sent_bytes + size + 16)); printf '%s\n' "$id" >> "$WORK/new.ids"
      rm -f -- "$WORK/file.enc"
    fi
    printf 'F %s %s %s %s\n' "$mode" "$size" "$id" "$path" >> "$plain.body"
  done < <(cd "$dir" && find . -mindepth 1 \( -type f -o -type d \) -printf '%P\0' | LC_ALL=C sort -z)
  rm -f -- "$WORK/file.tar"
  ((count > 0)) || fail "$name holds no file"
  { cat -- "$plain.body"; printf 'mac %s\n' "$(manifest_mac "$plain.body")"; } > "$plain"
  # The manifest goes up last: it is what makes the backup exist in the bucket.
  backup_encrypt "$BACKUP_KEY" < "$plain" > "$WORK/manifest.enc" || fail 'could not encrypt the manifest'
  rc copyto "$WORK/manifest.enc" "$BASE/backups/$name.manifest" || fail "the bucket refused the manifest: ${RC_ERR:-no detail}"

  # Check what is in the bucket against what was sent.
  rc cat "$BASE/backups/$name.manifest" > "$WORK/manifest.back" || fail "the manifest could not be read back: ${RC_ERR:-no detail}"
  cmp -s -- "$WORK/manifest.back" "$WORK/manifest.enc" || fail 'the manifest in the bucket is not the one that was sent'
  VERIFIED_DEEP=0
  verify_manifest "$plain.body" slice "$WORK/new.ids" 2> "$WORK/verify.err" || fail "the copy in the bucket did not check: $(head -n 2 "$WORK/verify.err" | tr '\n' ' ')"

  # Retention, then the objects nothing keeps.
  local problem=''
  problem="$(apply_retention "$state" "$name" 2>&1)" || true
  write_status "$state" ok "uploaded $name ($count files, $sent new, $((sent_bytes / 1048576)) MiB sent, $VERIFIED_DEEP read back)${problem:+; WARNING: $problem}" \
    "backup=$name" "files=$count" "files_sent=$sent" "bytes_sent=$sent_bytes"
  if [[ -n "$problem" ]]; then
    write_status "$state" failed "uploaded $name and checked it, but the clean-up of old backups in the bucket failed: $problem" "backup=$name" "files=$count" "files_sent=$sent" "bytes_sent=$sent_bytes"
    # The upload stands (last_success_epoch moved by the first write); the alert is for the clean-up.
    echo "Off-site copy: $problem" >&2
    exit 1
  fi
  echo "Off-site copy of $name done: $count files, $sent new."
}

# Removes the manifests the retention does not keep, then the old objects no kept manifest names. Prints the problem and returns
# non-zero when it could not do that safely; it deletes nothing unless every kept manifest was read.
apply_retention() {
  local state="$1" current="$2" listing names kept n id line size drop count=0
  local -A used=()
  listing="$(remote_list "$BASE/backups")" || { echo "could not list the backups in the bucket: $RC_ERR"; return 1; }
  names="$(sed -n 's/^[0-9]* \(warehouse-[0-9]\{8\}T[0-9]\{6\}Z\)\.manifest$/\1/p' <<<"$listing")"
  kept="$(keep_list <<<"$names")"
  grep -qx "$current" <<<"$kept" || { echo "the retention would not keep the backup just made ($current); nothing removed"; return 1; }
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    rc cat "$BASE/backups/$n.manifest" > "$WORK/k.enc" || { echo "could not read the kept backup $n: $RC_ERR; nothing removed"; return 1; }
    read_manifest "$WORK/k.enc" "$n" "$WORK/k.plain" 2>"$WORK/k.err" || { echo "$(head -n 1 "$WORK/k.err"); nothing removed"; return 1; }
    while IFS= read -r line; do
      [[ "$line" =~ ^F\ [0-7]{3,4}\ [0-9]+\ ([0-9a-f]{64})\  ]] && used[${BASH_REMATCH[1]}]=1
    done < "$WORK/k.plain"
    count=$((count + 1))
  done <<<"$kept"
  ((count > 0 && ${#used[@]} > 0)) || { echo 'no kept backup names any object; nothing removed'; return 1; }
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    grep -qx "$n" <<<"$kept" || rc deletefile "$BASE/backups/$n.manifest" || { echo "could not remove the old backup $n: $RC_ERR"; return 1; }
  done <<<"$names"
  : > "$WORK/drop.list"
  while read -r size id; do :; done < /dev/null
  rc lsf --files-only --min-age "$GC_MIN_AGE" "$BASE/objects" > "$WORK/old.list" 2>/dev/null || { echo "could not list the old objects: $RC_ERR"; return 1; }
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9a-f]{64}$ && -z "${used[$id]:-}" ]] && printf '%s\n' "$id" >> "$WORK/drop.list"
  done < "$WORK/old.list"
  if [[ -s "$WORK/drop.list" ]]; then
    rc delete "$BASE/objects" --files-from "$WORK/drop.list" || { echo "could not remove old files: $RC_ERR"; return 1; }
  fi
}

# ---------------------------------------------------------------- fetch (restore side)
cmd_fetch() {
  local endpoint='' bucket='' region='' cred='' keyfile='' dest='' want='' names listing name n line mode size id path d tmpdir
  while (($#)); do
    case "$1" in
      --endpoint) endpoint="${2:-}"; shift 2 ;; --bucket) bucket="${2:-}"; shift 2 ;; --region) region="${2:-}"; shift 2 ;;
      --credentials-file) cred="${2:-}"; shift 2 ;; --backup-key) keyfile="${2:-}"; shift 2 ;; --dest) dest="${2:-}"; shift 2 ;;
      --backup) want="${2:-}"; shift 2 ;; *) die "Unknown option for fetch: $1" ;;
    esac
  done
  [[ -n "$endpoint" && -n "$bucket" && -n "$cred" && -n "$keyfile" && -n "$dest" ]] || die 'fetch needs --endpoint, --bucket, --credentials-file, --backup-key and --dest.'
  valid_endpoint "$endpoint" && valid_bucket "$bucket" && valid_region "$region" || die 'The endpoint, bucket or region is not valid.'
  [[ "$dest" == /* && -d "$dest" && ! -L "$dest" ]] || die "--dest must be an existing absolute folder: $dest"
  OFF_ENDPOINT="$endpoint" OFF_BUCKET="$bucket" OFF_REGION="$region" OFF_RATE=''
  read_credentials "$cred" || exit 1
  need_rclone || exit 1
  backup_key_load "$keyfile" || exit 1
  make_work "$dest"
  set_base
  listing="$(remote_list "$BASE/backups")" || die "Could not list the bucket: $RC_ERR"
  names="$(sed -n 's/^[0-9]* \(warehouse-[0-9]\{8\}T[0-9]\{6\}Z\)\.manifest$/\1/p' <<<"$listing" | LC_ALL=C sort)"
  [[ -n "$names" ]] || die 'The bucket holds no backup made with this backup key.'
  if [[ -n "$want" ]]; then
    grep -qx -- "$want" <<<"$names" || die "No backup $want in the bucket. Available: $(tr '\n' ' ' <<<"$names")"
    name="$want"
  else
    name="$(tail -n 1 <<<"$names")"
  fi
  rc cat "$BASE/backups/$name.manifest" > "$WORK/m.enc" || die "Could not download the manifest of $name: $RC_ERR"
  read_manifest "$WORK/m.enc" "$name" "$WORK/m.plain" || exit 1
  [[ ! -e "$dest/$name" ]] || die "$dest/$name already exists."
  mkdir -- "$dest/$name"
  local -a dirs=()
  while IFS= read -r line; do
    case "$line" in
      D\ *)
        [[ "$line" =~ ^D\ ([0-7]{3,4})\ (.+)$ ]] || die 'The manifest has a folder line that is not valid.'
        valid_relpath "${BASH_REMATCH[2]}" || die 'The manifest names an unusable path.'
        mkdir -p -- "$dest/$name/${BASH_REMATCH[2]}"; dirs+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}") ;;
      F\ *)
        [[ "$line" =~ ^F\ ([0-7]{3,4})\ ([0-9]+)\ ([0-9a-f]{64})\ (.+)$ ]] || die 'The manifest has a file line that is not valid.'
        id="${BASH_REMATCH[3]}" path="${BASH_REMATCH[4]}"
        valid_relpath "$path" || die 'The manifest names an unusable path.'
        mkdir -p -- "$dest/$name/$(dirname -- "$path")"
        fetch_object "$id" "$WORK/f.tar" || die "Restore from the bucket stopped at $path."
        [[ "$(tar -tf "$WORK/f.tar")" == "$path" ]] || die "An object in the bucket holds a different path than the manifest says ($path)."
        tar --no-same-owner -p --xattrs --xattrs-include='user.*' -C "$dest/$name" -xf "$WORK/f.tar" || die "Could not unpack $path."
        rm -f -- "$WORK/f.tar" ;;
    esac
  done < <(sed -n '/^[DF] /p' "$WORK/m.plain")
  # Folder modes last (a folder made read-only must not stop the files going into it).
  for d in "${dirs[@]}"; do chmod "${d%% *}" -- "$dest/$name/${d#* }"; done
  chmod 700 -- "$dest/$name"
  rm -rf -- "$WORK"; WORK=''
  printf '%s\n' "$dest/$name"
}

# ---------------------------------------------------------------- on / off / status / list / verify
cmd_on() {
  local state endpoint='' bucket='' region='' cred='' rate='' conf probe tmp content got
  state="$(. "$ROOT/scripts/operator-lock.sh"; operator_state)" || exit 1
  conf="$state/config/offsite.conf"
  while (($#)); do
    case "$1" in
      --endpoint) endpoint="${2:-}"; shift 2 ;; --bucket) bucket="${2:-}"; shift 2 ;; --region) region="${2:-}"; shift 2 ;;
      --credentials-file) cred="${2:-}"; shift 2 ;; --max-rate) rate="${2:-}"; shift 2 ;; *) die "Unknown option for on: $1" ;;
    esac
  done
  if [[ -z "$endpoint$bucket$cred" && -f "$conf" ]]; then
    # on again, same bucket and credentials as before.
    load_conf "$state" || exit 1
    endpoint="$OFF_ENDPOINT" bucket="$OFF_BUCKET" region="$OFF_REGION" rate="${rate:-$OFF_RATE}"; cred="$state/config/offsite.credentials"
  fi
  [[ -n "$endpoint" && -n "$bucket" && -n "$cred" ]] || die 'Usage: bash scripts/offsite.sh on --endpoint URL --bucket NAME --credentials-file FILE [--region R] [--max-rate MB/S]'
  valid_endpoint "$endpoint" || die 'Check failed (endpoint): it must be an https:// address (plain http is accepted only to this host).'
  valid_bucket "$bucket" || die 'Check failed (bucket): not a valid bucket name.'
  valid_region "$region" || die 'Check failed (region): letters, digits and "-" only.'
  valid_rate "$rate" || die 'Check failed (max rate): a whole number of MB per second.'
  read_credentials "$cred" || die 'Check failed (credentials file).'
  OFF_ENDPOINT="$endpoint" OFF_BUCKET="$bucket" OFF_REGION="$region" OFF_RATE="$rate"
  need_rclone || exit 1
  backup_key_load "$state/config/backup.key" || exit 1
  backup_escrow_ok "$state" || die "Check failed (backup key copy): ${BACKUP_ESCROW_PROBLEM}. The copy in the bucket is encrypted with the backup key and cannot be opened without it: bash scripts/backup-key-escrow.sh show"
  make_work
  probe="warehouse-offsite/test/$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  content="warehouse-offsite-test $(date -u +%Y-%m-%dT%H:%M:%SZ) $RANDOM$RANDOM"
  printf '%s\n' "$content" > "$WORK/probe"
  rc copyto "$WORK/probe" "$(remote_root)/$probe" || die "Check failed (write): the bucket refused a test object: ${RC_ERR:-no detail}. Check the endpoint, bucket name, region and that the key may write."
  got="$(rc cat "$(remote_root)/$probe" || true)"
  if [[ "$got" != "$content" ]]; then rc deletefile "$(remote_root)/$probe" || true; die "Check failed (read): the test object could not be read back: ${RC_ERR:-it differs}."; fi
  if [[ -z "${WAREHOUSE_OFFSITE_TEST_DIR:-}" ]] && command -v curl >/dev/null 2>&1; then
    # Anonymous request for the test object (path style, then the bucket's own host). A public bucket is refused where it can be told.
    for url in "${endpoint%/}/$bucket/$probe" "https://$bucket.${endpoint#https://}/$probe"; do
      code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$url" 2>/dev/null || true)"
      if [[ "$code" == 200 ]]; then rc deletefile "$(remote_root)/$probe" || true; die 'Check failed (public bucket): anyone can read objects in this bucket. The copy is encrypted, but a facility bucket must be private; switch off public access at the provider and run this again.'; fi
    done
  fi
  rc deletefile "$(remote_root)/$probe" || die "Check failed (delete): the test object could not be removed: ${RC_ERR:-no detail}. The key needs permission to delete (the retention removes old backups)."
  # Stored: credentials 0600 first, then the settings (the settings file holds nothing secret).
  tmp="$(mktemp "$state/config/offsite.credentials.XXXXXX")"
  printf 'access_key_id=%s\nsecret_access_key=%s\n' "$OFF_AKID" "$OFF_SECRET" > "$tmp"; chmod 600 "$tmp"; mv -f -- "$tmp" "$state/config/offsite.credentials"
  tmp="$(mktemp "$conf.XXXXXX")"
  printf 'ENABLED=yes\nENDPOINT=%s\nBUCKET=%s\nREGION=%s\nMAX_RATE=%s\nENABLED_EPOCH=%s\n' "$endpoint" "$bucket" "$region" "$rate" "$(date +%s)" > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$conf"
  echo "Off-site copy is on: bucket $bucket at $endpoint. The check wrote, read and removed a test object."
  echo "Keep, with the copy of the backup key, the endpoint, the bucket name and a copy of the credentials: a lost-host restore needs all four."
  echo "The file $cred you gave me can be deleted now (a copy is kept in $state/config/offsite.credentials, mode 0600)."
  echo "The first upload can take long: run bash scripts/offsite.sh run once by hand; the nightly backup then sends only what is new."
}
cmd_off() {
  local state conf tmp
  state="$(. "$ROOT/scripts/operator-lock.sh"; operator_state)" || exit 1
  conf="$state/config/offsite.conf"
  [[ -f "$conf" && ! -L "$conf" ]] || { echo 'The off-site copy is already off (never set up).'; return 0; }
  tmp="$(mktemp "$conf.XXXXXX")"
  sed 's/^ENABLED=.*/ENABLED=no/' "$conf" > "$tmp"; chmod 600 "$tmp"; mv -f -- "$tmp" "$conf"
  echo 'Off-site copy is off. The bucket and what it holds are untouched; bash scripts/offsite.sh on turns it on again.'
}
cmd_status() {
  local state conf last
  state="$(. "$ROOT/scripts/operator-lock.sh"; operator_state)" || exit 1
  conf="$state/config/offsite.conf"; last="$(status_file "$state")"
  if [[ ! -f "$conf" ]]; then echo 'Off-site copy: not set up (off by default).'; return 0; fi
  echo "Off-site copy: $([[ "$(conf_get "$conf" ENABLED)" == yes ]] && echo on || echo off)"
  echo "Endpoint: $(conf_get "$conf" ENDPOINT)"; echo "Bucket: $(conf_get "$conf" BUCKET)"
  echo "Region: $(conf_get "$conf" REGION)"; echo "Max rate (MB/s): $(conf_get "$conf" MAX_RATE)"
  if [[ -f "$last" ]]; then
    sed -n 's/^result=/Last result: /p;s/^finished_utc=/Last run: /p;s/^backup=/Last backup uploaded: /p;s/^files=/Files: /p;s/^files_sent=/Files sent in that run: /p;s/^bytes_sent=/Bytes sent in that run: /p;s/^message=/Message: /p' "$last"
    echo "Last verified upload: $(date -u -d "@$(sed -n 's/^last_success_epoch=//p' "$last" | head -n 1)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo never)"
  else echo 'No upload has run yet.'; fi
}
open_bucket() {
  STATE_FOR_BUCKET="$(. "$ROOT/scripts/operator-lock.sh"; operator_state)" || exit 1
  load_conf "$STATE_FOR_BUCKET" || exit 1
  need_rclone || exit 1
  backup_key_load "$STATE_FOR_BUCKET/config/backup.key" || exit 1
  make_work
  set_base
}
cmd_list() { open_bucket; remote_list "$BASE/backups" | sed -n 's/^\([0-9]*\) \(warehouse-[0-9]\{8\}T[0-9]\{6\}Z\)\.manifest$/\2/p' | LC_ALL=C sort; }
cmd_verify() {
  local deep=no name='' listing
  while (($#)); do case "$1" in --deep) deep=all; shift ;; warehouse-*) name="$1"; shift ;; *) die "Unknown option for verify: $1" ;; esac; done
  open_bucket
  listing="$(remote_list "$BASE/backups")" || die "Could not list the bucket: $RC_ERR"
  if [[ -z "$name" ]]; then name="$(sed -n 's/^[0-9]* \(warehouse-[0-9]\{8\}T[0-9]\{6\}Z\)\.manifest$/\1/p' <<<"$listing" | LC_ALL=C sort | tail -n 1)"; fi
  [[ -n "$name" ]] || die 'The bucket holds no backup made with this backup key.'
  rc cat "$BASE/backups/$name.manifest" > "$WORK/v.enc" || die "Could not download the manifest of $name: $RC_ERR"
  read_manifest "$WORK/v.enc" "$name" "$WORK/v.plain" || exit 1
  VERIFIED_DEEP=0
  verify_manifest "$WORK/v.plain" "$([[ $deep == all ]] && echo all || echo none)" || exit 1
  echo "$name in the bucket checks out ($([[ $deep == all ]] && echo "every object read back and checked" || echo "all objects present with the right size"))."
}

case "${1:-}" in
  on) shift; cmd_on "$@" ;;
  off) cmd_off ;;
  status) cmd_status ;;
  run) shift; cmd_run "$@" ;;
  list) cmd_list ;;
  verify) shift; cmd_verify "$@" ;;
  fetch) shift; cmd_fetch "$@" ;;
  keep-list) keep_list ;;
  mark-failed) # internal: scripts/watch-daily.sh, when it had to stop a run (time limit) that could not record its own end
    shift; state="$(. "$ROOT/scripts/operator-lock.sh"; operator_state)" || exit 1; write_status "$state" failed "${*:-the run was stopped}" ;;
  *) die 'Usage: bash scripts/offsite.sh on|off|status|run [BACKUP_DIR]|list|verify [--deep] [NAME]|keep-list|fetch ...   (see the header of this file)' ;;
esac
