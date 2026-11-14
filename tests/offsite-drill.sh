#!/usr/bin/env bash
# The off-site copy against a real S3-compatible server in a container (WH-145), run by CI and by hand; not part of `npm test`
# (tests/offsite.test.mjs covers the same rules against a stand-in server in the test process). One throwaway container, published on
# 127.0.0.1 only, data in tmpfs, removed at the end by its exact name. The state, the backups and the key are fictional (the same
# fixtures as the unit tests); no operator state is read.
#
#   bash tests/offsite-drill.sh
#
# Proves, with the real rclone against a real server: on (and its refusals), two nights (the second sends only what changed), nothing in the
# bucket is readable without the key, the credentials are on no command line and in no output, a wrong key or credentials and an
# unreachable bucket fail without touching the local backup (and raise the alert text), a changed byte is caught, and fetch rebuilds the
# backup byte for byte. The restore-host and verify-restore steps on top of it are in tests/restore-host.test.mjs and tests/offsite.test.mjs.
# Needs: docker, rclone 1.60 or newer, node. Environment: OFFSITE_DRILL_IMAGE (default: the image pinned below), OFFSITE_DRILL_NAME
# (container name prefix, default warehouse-offsite-drill), OFFSITE_DRILL_PORT (default: a free port).
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# rustfs, pinned by digest (the MinIO images are no longer published to Docker Hub). Any S3 server works: set OFFSITE_DRILL_IMAGE and
# OFFSITE_DRILL_ENV (space-separated NAME=VALUE pairs naming the root user and password, here RUSTFS_ACCESS_KEY and RUSTFS_SECRET_KEY).
IMAGE="${OFFSITE_DRILL_IMAGE:-rustfs/rustfs@sha256:b81d16a90ee25bd9511280127ca1471788c6e874cf0f0da759645f46b2dc1d74}"
NAME="${OFFSITE_DRILL_NAME:-warehouse-offsite-drill}-$$"
KEYID=drillaccesskey01
SECRET=drillsecretkey0123456789ab
BUCKET=drillbucket
PORT="${OFFSITE_DRILL_PORT:-$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')}"
EP="http://127.0.0.1:$PORT"
work="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-offsite-drill.XXXXXX")"
fail() { echo "OFFSITE DRILL FAILED: $*" >&2; exit 1; }
cleanup() {
  local s=$?; trap - EXIT
  [[ -z "${sampler:-}" ]] || kill "$sampler" 2>/dev/null || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ -n "${OFFSITE_DRILL_KEEP:-}" ]]; then echo "Kept: $work" >&2; else rm -rf "$work"; fi
  exit "$s"
}
trap cleanup EXIT
command -v rclone >/dev/null || fail 'rclone is not installed'

extra_env=(); for pair in ${OFFSITE_DRILL_ENV:-}; do extra_env+=(-e "$pair"); done
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:9000" --tmpfs /data:rw,size=512m,mode=1777 --tmpfs /logs:rw,size=64m,mode=1777 \
  -e RUSTFS_ACCESS_KEY="$KEYID" -e RUSTFS_SECRET_KEY="$SECRET" "${extra_env[@]}" "$IMAGE" >/dev/null
rcl() { RCLONE_CONFIG=/dev/null RCLONE_CONFIG_T_TYPE=s3 RCLONE_CONFIG_T_PROVIDER=Other RCLONE_CONFIG_T_ENDPOINT="$EP" RCLONE_CONFIG_T_ACCESS_KEY_ID="$KEYID" \
  RCLONE_CONFIG_T_SECRET_ACCESS_KEY="$SECRET" timeout 60 rclone "$@"; }
for _ in $(seq 1 60); do rcl mkdir "t:$BUCKET" 2>/dev/null && break; sleep 1; done
rcl lsd t: | grep -q "$BUCKET" || fail 'the server did not come up'

# A fictional state with two nights of backups (hard-linked files keep their times; the second night has one new photo).
cat > "$work/fixture.mjs" <<EOF
import { makeState, makeBackup, writeEscrow } from '$ROOT/tests/backup-test-helpers.mjs';
import { execFileSync } from 'node:child_process';
const [scratch, night, ...extra] = process.argv.slice(2);
import { existsSync } from 'node:fs';
const state = existsSync(scratch + '/state') ? scratch + '/state' : makeState(scratch);
if (!existsSync(state + '/backups')) { writeEscrow(state); (await import('node:fs')).mkdirSync(state + '/backups', { mode: 0o700 }); }
const dir = state + '/backups/' + night;
makeBackup(dir, { format: 'warehouse-backup-v6', objects: ['documents/a.pdf/v1', 'photos/Rakesh Patel Cold Room/v2.jpg/v1', 'photos/ગ્રાહક/v1.jpg/v1', 'photos/back\\\\slash.jpg/v1', 'photos/tab\\tname.jpg/v1', 'photos/-dash.jpg/v1', ...extra] });
execFileSync('find', [dir, '-exec', 'touch', '-h', '-d', '@1700000000', '{}', '+']);
EOF
node "$work/fixture.mjs" "$work" warehouse-20261112T010000Z
node "$work/fixture.mjs" "$work" warehouse-20261113T010000Z photos/new/n.jpg/v1
export WAREHOUSE_STATE_DIR="$work/state"
state="$WAREHOUSE_STATE_DIR"
off() { bash "$ROOT/scripts/offsite.sh" "$@"; }
printf 'access_key_id=%s\nsecret_access_key=%s\n' "$KEYID" "$SECRET" > "$work/cred"; chmod 600 "$work/cred"
printf 'access_key_id=%s\nsecret_access_key=%s\n' "$KEYID" 'wrongsecretkey012345678' > "$work/badcred"; chmod 600 "$work/badcred"
backups_hash() { (cd "$state/backups" && find . -type f -exec sha256sum {} + | sort -k2 | sha256sum); }
local_before="$(backups_hash)"

echo '1. off by default; half-given options and a wrong secret are refused and store nothing'
off status | grep -q 'not set up' || fail 'not off by default'
for args in "--endpoint $EP --bucket $BUCKET" "--endpoint $EP --credentials-file $work/cred" "--bucket $BUCKET --credentials-file $work/cred"; do
  # shellcheck disable=SC2086
  if off on $args 2>/dev/null; then fail "on accepted half the options: $args"; fi
done
if off on --endpoint "$EP" --bucket "$BUCKET" --credentials-file "$work/badcred" 2>"$work/err"; then fail 'on accepted a wrong secret'; fi
grep -q 'Check failed (write)' "$work/err" || fail 'the refusal does not name the check'
if grep -q "$SECRET\|wrongsecretkey012345678" "$work/err"; then fail 'a secret was printed'; fi
[[ ! -e "$state/config/offsite.conf" ]] || fail 'a refused on stored settings'

echo '2. on, then two nights; the second sends only what changed; /proc is watched for the secret'
off on --endpoint "$EP" --bucket "$BUCKET" --credentials-file "$work/cred" > "$work/on.out" 2>&1 || { cat "$work/on.out" >&2; fail 'on failed'; }
( while :; do for p in /proc/[0-9]*; do tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -F -e "$SECRET" -e "$KEYID" | grep -v 'offsite-drill' >> "$work/proc.seen" || true; done; done ) 2>/dev/null &
sampler=$!
off run "$state/backups/warehouse-20261112T010000Z" > "$work/run1.out" 2>&1 || { cat "$work/run1.out" >&2; fail 'night 1 failed'; }
off run "$state/backups/warehouse-20261113T010000Z" > "$work/run2.out" 2>&1 || { cat "$work/run2.out" >&2; fail 'night 2 failed'; }
kill "$sampler" 2>/dev/null || true; sampler=''
grep -Eq 'files, ([0-9]+) new' "$work/run1.out" && [[ "$(sed -nE 's/.*: ([0-9]+) files, ([0-9]+) new.*/\1 \1/p;' "$work/run1.out")" == "$(sed -nE 's/.*: ([0-9]+) files, ([0-9]+) new.*/\1 \2/p' "$work/run1.out")" ]] || fail "night 1 did not send all: $(cat "$work/run1.out")"
total="$(sed -n 's/^files=//p' "$state/config/offsite.last")"   # the files of the last night (night 2)
sent="$(sed -n 's/^files_sent=//p' "$state/config/offsite.last")"
((sent > 0 && sent < total)) || fail "night 2 sent $sent of $total files"
[[ ! -s "$work/proc.seen" ]] || fail "a credential was on a command line: $(head -c 300 "$work/proc.seen")"
if grep -rq -e "$SECRET" "$work/on.out" "$work/run1.out" "$work/run2.out" "$state/config/offsite.conf" "$state/config/offsite.last" "$state/backups"; then fail 'the secret is in an output, the settings or a backup'; fi
[[ "$(stat -c %a "$state/config/offsite.credentials")" == 600 ]] || fail 'credentials file is not 0600'
[[ "$(off list | tr '\n' ' ')" == 'warehouse-20261112T010000Z warehouse-20261113T010000Z ' ]] || fail 'list is wrong'
off verify --deep > /dev/null || fail 'verify --deep failed on a good copy'

echo '3. nothing in the bucket is readable without the key'
mkdir "$work/dl"; rcl copy "t:$BUCKET" "$work/dl"
[[ -n "$(find "$work/dl" -type f)" ]] || fail 'nothing was uploaded'
for plain in 'fake database dump' 'Rakesh Patel' 'bytes of stub' WAREHOUSE_PROJECT_NAME documents a.pdf SHA256SUMS database.dump storage.manifest ustar; do
  if grep -rqaF -e "$plain" "$work/dl"; then fail "'$plain' is readable in the bucket"; fi
done
while IFS= read -r f; do [[ "$(head -c 8 "$f")" == Salted__ ]] || fail "$f is not encrypted"; done < <(find "$work/dl" -type f)
find "$work/dl" -type f | sed "s#$work/dl/##" | grep -Ev '^warehouse-offsite/k-[0-9a-f]{16}/(objects/[0-9a-f]{64}|backups/warehouse-[0-9]{8}T[0-9]{6}Z\.manifest)$' && fail 'a name in the bucket is not a hash or a backup name'

echo '4. fetch rebuilds the backup byte for byte; another key and wrong credentials get nothing'
mkdir "$work/dest"; chmod 700 "$work/dest"
for loc in C C.UTF-8; do   # names in Gujarati, with a backslash, a tab and a leading dash come back byte for byte in either locale
  mkdir "$work/dest-$loc"; chmod 700 "$work/dest-$loc"
  LC_ALL="$loc" off fetch --endpoint "$EP" --bucket "$BUCKET" --credentials-file "$work/cred" --backup-key "$state/config/backup.key" --dest "$work/dest-$loc" --backup warehouse-20261112T010000Z > /dev/null || fail "fetch failed under $loc"
  LC_ALL=C diff -r "$state/backups/warehouse-20261112T010000Z" "$work/dest-$loc/warehouse-20261112T010000Z" || fail "the fetched backup differs under $loc"
done
echo '   off keeps the credentials file and says so; on again needs no options'
off off | grep -q 'credentials stay in' || fail 'off did not say the credentials stay'
[[ -f "$state/config/offsite.credentials" ]] || fail 'off removed the credentials file'
off on > /dev/null || fail 'on again failed'
printf '%s\n' "$(printf '11%.0s' $(seq 32))" > "$work/otherkey"; chmod 600 "$work/otherkey"
if off fetch --endpoint "$EP" --bucket "$BUCKET" --credentials-file "$work/cred" --backup-key "$work/otherkey" --dest "$work/dest" 2>"$work/err"; then fail 'another key got a backup'; fi
grep -q 'no backup made with this backup key' "$work/err" || fail 'wrong-key message'
if off fetch --endpoint "$EP" --bucket "$BUCKET" --credentials-file "$work/badcred" --backup-key "$state/config/backup.key" --dest "$work/dest" --backup warehouse-20261113T010000Z >/dev/null 2>&1; then fail 'wrong credentials fetched'; fi

echo '5. failures raise the alert and leave the local backups untouched: wrong stored credentials, unreachable bucket, a changed byte'
cp "$state/config/offsite.credentials" "$work/cred.good"; cp "$state/config/offsite.conf" "$work/conf.good"
alert() { node --input-type=module -e "import { offsiteStatus } from '$ROOT/scripts/usb-backup-status.mjs'; console.log(JSON.stringify(offsiteStatus(process.argv[1])))" "$state"; }
cp "$work/badcred" "$state/config/offsite.credentials"
if off run > /dev/null 2>&1; then fail 'run succeeded with wrong credentials'; fi
alert | grep -q '"fresh":false,"problem":"The off-site copy of the backups failed' || fail 'no alert for wrong credentials'
[[ "$(backups_hash)" == "$local_before" ]] || fail 'a local backup changed (credentials)'
cp "$work/cred.good" "$state/config/offsite.credentials"
sed -i "s#^ENDPOINT=.*#ENDPOINT=http://127.0.0.1:1#" "$state/config/offsite.conf"
if off run > /dev/null 2>&1; then fail 'run succeeded with an unreachable bucket'; fi
alert | grep -q '"problem":"The off-site copy of the backups failed' || fail 'no alert for an unreachable bucket'
[[ "$(backups_hash)" == "$local_before" ]] || fail 'a local backup changed (unreachable)'
cp "$work/conf.good" "$state/config/offsite.conf"
off run > /dev/null || fail 'the next good night did not clear the failure'
alert | grep -q '"problem":null' || fail 'the alert did not clear'
# One byte changed in every object of the bucket: the deep check names it.
mkdir "$work/objs" "$work/bad"; objects="$(rcl lsf -R --files-only "t:$BUCKET" | grep '/objects/')"
rcl copy "t:$BUCKET" "$work/objs" --include '*/objects/*'
while IFS= read -r o; do
  b="$work/bad/$(basename "$o")"; last="$(tail -c 1 "$work/objs/$o" | od -An -tu1 | tr -d ' ')"
  head -c -1 "$work/objs/$o" > "$b"; printf "\\x$(printf '%02x' $((last ^ 1)))" >> "$b"   # one byte flipped in place: the size is the same
  [[ "$(stat -c %s "$b")" == "$(stat -c %s "$work/objs/$o")" ]] || fail 'the changed copy has another size'
done <<<"$objects"
first="$(head -n 1 <<<"$objects")"
prefix="${first%/objects/*}"
rcl copy "$work/bad" "t:$BUCKET/$prefix/objects" --ignore-times
if off verify --deep > "$work/deep.out" 2>&1; then fail 'verify --deep passed a changed object'; fi
grep -q 'not what its name says\|does not decrypt' "$work/deep.out" || fail "deep check message: $(cat "$work/deep.out")"
[[ "$(backups_hash)" == "$local_before" ]] || fail 'a local backup changed (tamper)'
echo 'OFFSITE DRILL PASSED'
