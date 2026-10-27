#!/usr/bin/env bash
# The seeded Storage drill (docker/storage/README.md, "The quarterly move"): rehearses a move of the Storage image on a catalog with
# thousands of objects, on throwaway containers and a throwaway --internal network (no host ports, nothing of an installation).
#   1. The database of the shipped recipe (docker/volumes/db bootstrap and roles), then the CURRENT Storage image (built from
#      docker/storage) with the environment of docker/docker-compose.yml, DB_MIGRATIONS_FREEZE_AT included: its migrations are
#      applied and the newest is the one docker/storage/migrations-head.txt names.
#   2. A catalog of STORAGE_DRILL_OBJECTS fictional objects (rows in storage.objects, a file for each; the content of an object is its
#      name) plus one upload through the API. Every object is read through the API, and signed URLs work.
#   3. The NEXT image (STORAGE_NEXT_TAG, which must be newer than the current tag; by default the newest tag of the same major on
#      Docker Hub) with the freeze still set, as an accidental bump would run: the catalog stays at the current head, and the new
#      code still reads every object, signs URLs and takes an upload on that schema.
#   4. The next image with the freeze set to the name of ITS newest migration file, as the quarterly move sets it in
#      docker/docker-compose.yml: its migrations are applied to the catalog (the time it takes is printed; setup.sh waits 180 s for
#      them), the head is that migration (and not below the current head; equal means the move adds no Storage migration), no
#      object was lost or changed, every object is read through the API again, signed URLs work, and an upload works.
# Steps 1 and 2 fail the drill when they fail. Steps 3 and 4 do too when STORAGE_DRILL_NEXT_REQUIRED=true; otherwise they print a
# warning and the drill ends 0, so a next minor that is not chosen yet (or one that does not pass) does not block anything.
# STORAGE_DRILL_OBJECTS (default 5000), STORAGE_NEXT_TAG (for example v1.84.28).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# new_name and create_net (throwaway names slim-tool-*); db_psql is not used: the database here has its own passwords.
source "$ROOT/scripts/baseline/lib.sh"

objects="${STORAGE_DRILL_OBJECTS:-5000}"
[[ "$objects" =~ ^[0-9]{1,6}$ && "$objects" -ge 1 ]] || { echo "STORAGE_DRILL_OBJECTS must be a number from 1 to 999999 (got '$objects')." >&2; exit 1; }
next_required="${STORAGE_DRILL_NEXT_REQUIRED:-false}"

say() { printf '== %s\n' "$*"; }
fail() { echo "Storage drill FAILED: $*" >&2; exit 1; }

containers=()
# Every image id on the host before the drill builds or pulls anything. An id in this list is never the drill's to remove, however it got
# tagged: a cached build of docker/storage comes out with the id of an earlier build (tests/migrations.sh leaves one untagged), and a
# pulled tag can be a second name of an image that was here.
preexisting_images="$(docker image ls -aq --no-trunc)" || { echo 'Storage drill FAILED: cannot list the images of the host.' >&2; exit 1; }
image_preexisted() { grep -qxF -- "$1" <<<"$preexisting_images"; }
images=()   # ids of images that did not exist before this script built or pulled them
net=''
files_volume=''
work="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-storage-drill.XXXXXX")"
cleanup() {
  local c
  for c in "${containers[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1 || true; done
  [[ -z "$net" ]] || docker network rm "$net" >/dev/null 2>&1 || true
  [[ -z "$files_volume" ]] || docker volume rm -f "$files_volume" >/dev/null 2>&1 || true
  # By exact id and without -f: Docker refuses an image that a container uses or that carries another name, and the drill leaves it then.
  for c in "${images[@]}"; do
    docker image rm "$c" >/dev/null 2>&1 || echo "Storage drill: left the image $c in place (in use, or already gone); remove it by hand if it is not wanted: docker image rm $c" >&2
  done
  rm -rf "$work"
}
trap cleanup EXIT

# --- the facts of this checkout ---------------------------------------------------------------------------------------------------
head_id="$(sed -n 's/^id=//p' "$ROOT/docker/storage/migrations-head.txt")"
head_name="$(sed -n 's/^name=//p' "$ROOT/docker/storage/migrations-head.txt")"
[[ "$head_id" =~ ^[0-9]+$ && -n "$head_name" ]] || fail 'docker/storage/migrations-head.txt has no id= and name='
freeze="$(awk '/^  storage:$/ { in_storage = 1; next } in_storage && /^  [a-z][a-z-]*:$/ { in_storage = 0 } in_storage && $1 == "DB_MIGRATIONS_FREEZE_AT:" { print $2 }' "$ROOT/docker/docker-compose.yml")"
[[ "$freeze" == "$head_name" ]] || fail "docker-compose.yml freezes Storage at '$freeze', migrations-head.txt says '$head_name'"
current_tag="$(sed -n 's/^FROM supabase\/storage-api:\(v[0-9.]*\)@.*/\1/p' "$ROOT/docker/storage/Dockerfile" | head -n 1)"
[[ -n "$current_tag" ]] || fail 'no storage-api tag in docker/storage/Dockerfile'

# The newest tag of the same major on Docker Hub that is newer than the current one; empty when there is none or Docker Hub is
# not reachable. A tag is vMAJOR.MINOR.PATCH only (no suffixes).
resolve_next_tag() {
  local major="${current_tag%%.*}" url="https://hub.docker.com/v2/repositories/supabase/storage-api/tags?page_size=100&ordering=last_updated&name=${current_tag%%.*}."
  curl -fsS --max-time 30 "$url" 2>/dev/null | CURRENT="$current_tag" MAJOR="$major" node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      const key = t => t.slice(1).split(".").map(Number);
      const newer = (a, b) => { for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i]; return false; };
      const tags = JSON.parse(s).results.map(r => r.name).filter(t => new RegExp("^" + process.env.MAJOR + "\\.[0-9]+\\.[0-9]+$").test(t));
      let best = process.env.CURRENT;
      for (const t of tags) if (newer(key(t), key(best))) best = t;
      if (best !== process.env.CURRENT) console.log(best);
    })' || true
}

# --- containers ----------------------------------------------------------------------------------------------------------------------
net="$(create_net)"
db="$(new_name drill-db)"
containers+=("$db")
# The stored files outlive the Storage containers of the drill, as data/storage does in an installation.
files_volume="$(new_name files)"
docker volume create --label purpose=storage-drill "$files_volume" >/dev/null
db_password="$(openssl rand -hex 32)"
jwt_secret="$(openssl rand -hex 32)"
storage_password="$(openssl rand -hex 32)"
jwt() {
  JWT_SECRET="$jwt_secret" ROLE="$1" node -e '
    const c = require("crypto"), b = o => Buffer.from(JSON.stringify(o)).toString("base64url"), now = Math.floor(Date.now() / 1000);
    const h = b({ alg: "HS256", typ: "JWT" }), p = b({ role: process.env.ROLE, iss: "storage-drill", iat: now, exp: now + 7200 });
    console.log(h + "." + p + "." + c.createHmac("sha256", process.env.JWT_SECRET).update(h + "." + p).digest("base64url"))'
}
service_key="$(jwt service_role)"
anon_key="$(jwt anon)"

echo "Starting the database."
docker run -d --name "$db" --label purpose=storage-drill --network "$net" --memory 1g --cpus 1 \
  --tmpfs /var/lib/postgresql/data:rw,size=1g -e PGDATA=/var/lib/postgresql/data \
  -e JWT_SECRET="$jwt_secret" -e JWT_EXP=3600 -e AUTH_MODE=operator -e APP_ENV=production \
  -e POSTGRES_USER=supabase_admin -e POSTGRES_DB=postgres -e POSTGRES_PASSWORD="$db_password" \
  -e DB_PASSWORD_AUTHENTICATOR="$(openssl rand -hex 32)" -e DB_PASSWORD_STORAGE="$storage_password" \
  -e POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8 \
  -v "$ROOT/docker/volumes/db/00-bootstrap.sql:/docker-entrypoint-initdb.d/00-bootstrap.sql:ro" \
  -v "$ROOT/docker/volumes/db/roles.sql:/docker-entrypoint-initdb.d/10-roles.sql:ro" \
  "$(bash "$ROOT/scripts/db-image.sh")" postgres -c shared_preload_libraries=pg_stat_statements -c wal_level=replica >/dev/null
ready=false
for ((i = 0; i < 60; i++)); do
  if [[ "$(docker logs "$db" 2>&1 || true)" == *'PostgreSQL init process complete; ready for start up'* ]] \
    && docker exec "$db" pg_isready -U supabase_admin -d postgres -h 127.0.0.1 >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]] || fail 'the database did not start'
sql() { docker exec -i -e PGPASSWORD="$db_password" "$db" psql -X -q -At -v ON_ERROR_STOP=1 -U supabase_admin -d postgres "$@"; }

# start_storage NAME IMAGE [FREEZE]: Storage as docker-compose.yml runs it (the same environment), on the drill database; waits for
# "Started Successfully" (its migrations run before the server starts) and sets started_seconds to how long that took.
started_seconds=0
start_storage() {
  local name="$1" image="$2" freeze_at="${3:-}" begin=$SECONDS i logs
  containers+=("$name")
  local freeze_args=()
  [[ -z "$freeze_at" ]] || freeze_args=(-e "DB_MIGRATIONS_FREEZE_AT=$freeze_at")
  docker run -d --name "$name" --label purpose=storage-drill --network "$net" --memory 512m --cpus 1 \
    -v "$files_volume:/var/lib/storage" \
    -e ANON_KEY="$anon_key" -e SERVICE_KEY="$service_key" -e PGRST_JWT_SECRET="$jwt_secret" \
    -e "DATABASE_URL=postgres://supabase_storage_admin:$storage_password@$db:5432/postgres" \
    -e FILE_SIZE_LIMIT=52428800 -e STORAGE_BACKEND=file -e FILE_STORAGE_BACKEND_PATH=/var/lib/storage \
    -e TENANT_ID=stub -e REGION=stub -e GLOBAL_S3_BUCKET=stub -e ENABLE_IMAGE_TRANSFORMATION=false \
    -e DB_SUPER_USER=supabase_storage_admin -e DB_INSTALL_ROLES=false "${freeze_args[@]}" \
    "$image" >/dev/null
  for ((i = 0; i < 300; i++)); do
    # Captured first: grep -q ending the pipe early would make `docker logs` fail under pipefail once the log is long.
    logs="$(docker logs "$name" 2>&1 || true)"
    if [[ "$logs" == *'Started Successfully'* ]]; then started_seconds=$((SECONDS - begin)); return 0; fi
    [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)" == true ]] || break
    sleep 1
  done
  docker logs --tail 20 "$name" 2>&1 | cut -c1-400 >&2 || true
  return 1
}
stop_container() { docker rm -f -v "$1" >/dev/null 2>&1 || true; }
api() { docker exec -e KEY="$service_key" "$1" sh -c "$2"; }
head_of_catalog() { sql -c "SELECT COALESCE(max(id), 0) FROM storage.migrations"; }
count_of_catalog() { sql -c "SELECT count(*) FROM storage.migrations"; }

# read_all CONTAINER: every object of the drill bucket through the API; prints "read=<n> bad=<n>". The names are fed to a loop in the container.
read_all() {
  sql -c "SELECT name FROM storage.objects WHERE bucket_id = 'drill' ORDER BY name" | docker exec -i "$1" sh -c 'cat > /tmp/names'
  api "$1" 'n=0; bad=0
    while IFS= read -r name; do
      n=$((n + 1))
      got=$(wget -qO- --header "Authorization: Bearer $KEY" "http://127.0.0.1:5000/object/authenticated/drill/$name" 2>/dev/null || echo UNREADABLE)
      if [ "$got" != "$name" ]; then bad=$((bad + 1)); [ "$bad" -gt 5 ] || echo "unreadable or changed: $name" >&2; fi
    done < /tmp/names
    echo "read=$n bad=$bad"'
}
# signed_urls CONTAINER COUNT: a signed URL for each of the first COUNT objects, fetched without any key; prints "signed=<ok>/<n>".
signed_urls() {
  sql -c "SELECT name FROM storage.objects WHERE bucket_id = 'drill' ORDER BY name LIMIT $2" | docker exec -i "$1" sh -c 'cat > /tmp/signnames'
  api "$1" 'n=0; ok=0
    while IFS= read -r name; do
      n=$((n + 1))
      url=$(wget -qO- --header "Authorization: Bearer $KEY" --header "Content-Type: application/json" --post-data "{\"expiresIn\":300}" "http://127.0.0.1:5000/object/sign/drill/$name" 2>/dev/null | sed -n "s/.*\"signedURL\":\"\([^\"]*\)\".*/\1/p")
      [ -n "$url" ] && [ "$(wget -qO- "http://127.0.0.1:5000$url" 2>/dev/null || echo UNREADABLE)" = "$name" ] && ok=$((ok + 1))
    done < /tmp/signnames
    echo "signed=$ok/$n"'
}
# upload_one CONTAINER NAME: one object through the API (Storage writes the row and the file itself).
upload_one() {
  api "$1" "printf '%s' '$2' > /tmp/upload.bin; wget -qO- --header \"Authorization: Bearer \$KEY\" --header 'Content-Type: text/plain' --post-file /tmp/upload.bin 'http://127.0.0.1:5000/object/drill/$2'" >/dev/null
}
expect_all_read() { # RESULT LABEL
  [[ "$1" == "read=$((objects + 1)) bad=0" ]] || fail "$2: expected every one of the $((objects + 1)) objects to be read through the API, got '$1'"
}

# --- 1. the current image ----------------------------------------------------------------------------------------------------------
say "1. The current Storage image ($current_tag, the recipe of docker/storage), frozen at $head_name"
current_image="$(docker build -q "$ROOT/docker/storage")" || fail 'docker build of docker/storage failed'   # untagged: the id is the only name
[[ "$current_image" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "docker build did not print an image id (got '$current_image')"
if ! image_preexisted "$current_image"; then images+=("$current_image"); fi
current="$(new_name drill-storage)"
start_storage "$current" "$current_image" "$freeze" || fail 'the current image did not start'
[[ "$(head_of_catalog)" == "$head_id" ]] || fail "the catalog is at migration $(head_of_catalog), migrations-head.txt says $head_id"
[[ "$(sql -c "SELECT name FROM storage.migrations WHERE id = $head_id")" == "$head_name" ]] || fail "migration $head_id is not named '$head_name' in storage.migrations"
count_before="$(count_of_catalog)"
echo "   catalog at migration $head_id ($count_before migrations), started in ${started_seconds} s."

# --- 2. the catalog ---------------------------------------------------------------------------------------------------------------
say "2. A catalog of $objects objects"
api "$current" "wget -qO- --header \"Authorization: Bearer \$KEY\" --header 'Content-Type: application/json' --post-data '{\"name\":\"drill\",\"public\":false}' http://127.0.0.1:5000/bucket" >/dev/null
sql -c "INSERT INTO storage.objects (bucket_id, name, version, metadata)
  SELECT 'drill', 'lot-' || (g % 97) || '/doc-' || g || '.txt', gen_random_uuid()::text,
         jsonb_build_object('size', length('lot-' || (g % 97) || '/doc-' || g || '.txt'), 'mimetype', 'text/plain', 'cacheControl', 'no-cache',
                            'eTag', '\"drill\"', 'contentLength', length('lot-' || (g % 97) || '/doc-' || g || '.txt'), 'httpStatusCode', 200, 'lastModified', now())
  FROM generate_series(1, $objects) g" >/dev/null
sql -c "SELECT '/var/lib/storage/stub/stub/drill/' || name || '/' || version || '|' || name FROM storage.objects WHERE bucket_id = 'drill'" \
  | docker exec -i "$current" sh -c 'while IFS="|" read -r path content; do mkdir -p "${path%/*}"; printf "%s" "$content" > "$path"; done'
upload_one "$current" 'uploaded/before.txt'
[[ "$(sql -c "SELECT count(*) FROM storage.objects WHERE bucket_id = 'drill'")" == "$((objects + 1))" ]] || fail 'the catalog does not hold the seeded objects and the upload'
catalog_before="$(sql -c "SELECT md5(string_agg(name || ':' || version, ',' ORDER BY name)) FROM storage.objects WHERE bucket_id = 'drill'")"
result="$(read_all "$current")"; echo "   $result"
expect_all_read "$result" 'the current image'
result="$(signed_urls "$current" 25)"; echo "   $result"
[[ "$result" == 'signed=25/25' ]] || fail "the current image: signed URLs: $result"

stop_container "$current"
# --- 3 and 4. the next image -------------------------------------------------------------------------------------------------------
next_tag="${STORAGE_NEXT_TAG:-$(resolve_next_tag)}"
next_phase_failed() {
  if [[ "$next_required" == true ]]; then fail "$*"; fi
  echo "::warning title=Storage drill, next minor::$* (not required: STORAGE_DRILL_NEXT_REQUIRED is not true)"
  echo "Storage drill: the current image passed; the next minor did not (see the warning above)."
  exit 0
}
if [[ -z "$next_tag" ]]; then
  next_phase_failed "no newer tag of ${current_tag%%.*}.x to rehearse (Docker Hub has none, or was not reachable); set STORAGE_NEXT_TAG"
fi
[[ "$next_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "STORAGE_NEXT_TAG '$next_tag' is not a tag like v1.84.28"
if [[ "$next_tag" == "$current_tag" || "$(printf '%s\n%s\n' "$current_tag" "$next_tag" | sort -V | tail -n 1)" != "$next_tag" ]]; then
  next_phase_failed "STORAGE_NEXT_TAG ($next_tag) is not newer than the current tag $current_tag; clear the variable after the move"
fi
next_image="supabase/storage-api:$next_tag"
if ! docker image inspect "$next_image" >/dev/null 2>&1; then
  docker pull -q "$next_image" >/dev/null || next_phase_failed "could not pull $next_image"
  pulled_id="$(docker image inspect -f '{{.Id}}' "$next_image")" || next_phase_failed "cannot read the id of the pulled $next_image"
  if ! image_preexisted "$pulled_id"; then images+=("$pulled_id"); fi   # removed at the end only when the pull made a new image
fi
# The newest migration file the next image ships: the name the move puts in DB_MIGRATIONS_FREEZE_AT and the head it must reach.
next_newest="$(docker run --rm --entrypoint sh "$next_image" -c 'ls /app/migrations/tenant' | sed -En 's/^0*([0-9]+)-(.*)\.sql$/\1 \2/p' | sort -n | tail -n 1)"
[[ "$next_newest" =~ ^[0-9]+\ .+$ ]] || next_phase_failed "$next_image has no readable /app/migrations/tenant"
next_id="${next_newest%% *}"
next_name="${next_newest#* }"
((next_id >= head_id)) || next_phase_failed "the newest migration of $next_tag ($next_id) is older than the current head $head_id"

say "3. $next_tag with the freeze still at $head_name (an accidental bump)"
frozen="$(new_name drill-frozen)"
start_storage "$frozen" "$next_image" "$freeze" || next_phase_failed "$next_tag did not start with the freeze at $head_name"
[[ "$(head_of_catalog)" == "$head_id" ]] || next_phase_failed "$next_tag moved the catalog to migration $(head_of_catalog) although it was frozen at $head_id"
echo "   the catalog stayed at migration $head_id."
result="$(read_all "$frozen")"; echo "   $result"
[[ "$result" == "read=$((objects + 1)) bad=0" ]] || next_phase_failed "$next_tag on the frozen schema: expected every one of the $((objects + 1)) objects to be read through the API, got '$result'"
result="$(signed_urls "$frozen" 25)"; echo "   $result"
[[ "$result" == 'signed=25/25' ]] || next_phase_failed "$next_tag on the frozen schema: signed URLs: $result"
upload_one "$frozen" 'uploaded/frozen.txt' || next_phase_failed "$next_tag on the frozen schema: an upload failed"
[[ "$(sql -c "SELECT count(*) FROM storage.objects WHERE bucket_id = 'drill'")" == "$((objects + 2))" ]] || next_phase_failed "$next_tag on the frozen schema: the upload did not reach the catalog"
catalog_before="$(sql -c "SELECT md5(string_agg(name || ':' || version, ',' ORDER BY name)) FROM storage.objects WHERE bucket_id = 'drill'")"
stop_container "$frozen"

say "4. $next_tag with the freeze set to $next_name (the quarterly move)"
moved="$(new_name drill-next)"
start_storage "$moved" "$next_image" "$next_name" || next_phase_failed "$next_tag did not start on the seeded catalog with the freeze at $next_name"
echo "   migrations and start took ${started_seconds} s (setup.sh waits 180 s; 150 s on $objects rows is a smoke limit, not a sizing figure)."
((started_seconds <= 150)) || next_phase_failed "$next_tag took ${started_seconds} s to migrate $objects objects; setup.sh gives Storage 180 s"
head_after="$(head_of_catalog)"
[[ "$head_after" == "$next_id" ]] || next_phase_failed "the catalog is at migration $head_after after the move; $next_tag ships $next_id ($next_name) as its newest"
if [[ "$head_after" == "$head_id" ]]; then echo "   $next_tag ships no new Storage migration: the catalog stays at $head_id."; fi
echo "   catalog at migration $head_after ($(count_of_catalog) migrations, was $count_before)."
[[ "$(sql -c "SELECT md5(string_agg(name || ':' || version, ',' ORDER BY name)) FROM storage.objects WHERE bucket_id = 'drill'")" == "$catalog_before" ]] \
  || next_phase_failed "the catalog's objects (names and versions) changed in the move"
result="$(read_all "$moved")"; echo "   $result"
[[ "$result" == "read=$((objects + 2)) bad=0" ]] || { docker logs --tail 40 "$moved" 2>&1 | grep '"level":50' | tail -n 3 | cut -c1-1500 >&2 || true; next_phase_failed "$next_tag: expected every one of the $((objects + 2)) objects to be read through the API, got '$result'"; }
result="$(signed_urls "$moved" 25)"; echo "   $result"
[[ "$result" == 'signed=25/25' ]] || next_phase_failed "$next_tag: signed URLs: $result"
upload_one "$moved" 'uploaded/after.txt' || next_phase_failed "$next_tag: an upload failed"
[[ "$(sql -c "SELECT count(*) FROM storage.objects WHERE bucket_id = 'drill'")" == "$((objects + 3))" ]] || next_phase_failed "$next_tag: the upload did not reach the catalog"
echo "Storage drill passed: $objects objects, $current_tag (migration $head_id) to $next_tag (migration $head_after) in ${started_seconds} s."
