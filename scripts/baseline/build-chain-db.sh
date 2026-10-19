#!/usr/bin/env bash
# Starts a throwaway database (no network, named slim-tool-*) and applies the migration chain the way
# tests/migrations.sh does (scripts/migration-plan.mjs piped into psql). Leaves the container RUNNING and prints
# its name on stdout (everything else goes to stderr). The caller removes it: docker rm -f -v <name>.
#
#   build-chain-db.sh [--image <ref>] [--root <dir>] [--empty] [--name <name>] [--bootstrap <dir>] [--net <network>]
#     --image  database image (default: the one tests/migrations.sh pins)
#     --root   directory with a migrations/ folder to apply (default: this checkout)
#     --empty  apply nothing (a pristine database of the image)
#     --name   container name (default slim-tool-chain-<random>)
#     --bootstrap  postgres:17 mode: a directory of init scripts mounted at /docker-entrypoint-initdb.d (see lib.sh)
#     --net    an existing --internal network to join (Storage must reach the database); default: no network
#
# Configure scripts: scripts/configure-*.sql only write rows (auth_config, roles) and, for configure-storage.sql,
# policies on storage.objects, which the baseline deliberately does not contain; so none is run here.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
image="$DEFAULT_DB_IMAGE" root="$BASELINE_ROOT" empty=false name='' bootstrap='' net=''
while (($#)); do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --empty) empty=true; shift ;;
    --name) name="$2"; shift 2 ;;
    --bootstrap) bootstrap="$2"; shift 2 ;;
    --net) net="$2"; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -n "$name" ]] || name=$(new_name chain)
DB_BOOTSTRAP="$bootstrap" DB_NET="$net" start_db "$image" "$name" >&2
if [[ "$empty" == false ]]; then
  if ! plan_of "$root" | db_psql "$name" >&2; then
    echo "Applying the migrations from $root failed" >&2
    docker rm -f -v "$name" >/dev/null 2>&1 || true
    exit 1
  fi
fi
echo "$name"
