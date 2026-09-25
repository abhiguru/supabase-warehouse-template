#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_commit=3db12332b66497c31f8ad2a5fb0eb0fe0ca05a7e
builder_image=golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36
runtime_image=grafana/grafana:13.2.2@sha256:ac461fb352abc50da10a51c7d02462e9c05488f11f53f14b3ad79a8145f638a0
image=${GRAFANA_CORE_IMAGE:-warehouse-grafana-core:candidate}
: "${GRAFANA_CORE_EVIDENCE_DIR:?Set GRAFANA_CORE_EVIDENCE_DIR to a persistent absolute directory}"
evidence_dir=$GRAFANA_CORE_EVIDENCE_DIR
[[ $evidence_dir = /* ]] || { echo 'GRAFANA_CORE_EVIDENCE_DIR must be absolute.' >&2; exit 1; }
mkdir -p "$evidence_dir"
case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) echo 'A native amd64 or arm64 runner is required.' >&2; exit 1 ;;
esac

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
gopath_cache=${GRAFANA_CORE_GOPATH:-$scratch/gopath}
build_cache=${GRAFANA_CORE_GOCACHE:-$scratch/gocache}
[[ $gopath_cache = /* && $build_cache = /* ]] || {
  echo 'Grafana core cache paths must be absolute.' >&2; exit 1;
}
git clone --quiet --depth 1 --branch v13.2.2 --filter=blob:none \
  https://github.com/grafana/grafana.git "$scratch/source"
test "$(git -C "$scratch/source" rev-parse HEAD)" = "$source_commit"
git -C "$scratch/source" apply --unidiff-zero --check "$root/docker/grafana/core-thrift-0.24.0.patch"
git -C "$scratch/source" apply --unidiff-zero "$root/docker/grafana/core-thrift-0.24.0.patch"
mkdir -p "$gopath_cache" "$build_cache"
{
  printf 'source_commit=%s\nbuilder_image=%s\nruntime_image=%s\ncandidate_image=%s\narchitecture=linux/%s\n' \
    "$source_commit" "$builder_image" "$runtime_image" "$image" "$arch"
  sha256sum "$root/docker/grafana/core-thrift-0.24.0.patch" | awk '{print "patch_sha256=" $1}'
  sha256sum "$root/docker/grafana/plugins.lock" | awk '{print "plugins_lock_sha256=" $1}'
} > "$evidence_dir/provenance.txt"

docker run --rm --platform "linux/$arch" --cpus=4 --memory=10g --memory-swap=10g \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$scratch/source,dst=/src" \
  --mount "type=bind,src=$gopath_cache,dst=/gopath" \
  --mount "type=bind,src=$build_cache,dst=/gocache" \
  -w /src -e GOPATH=/gopath -e GOCACHE=/gocache -e GOTOOLCHAIN=local \
  -e GOFLAGS=-p=4 "$builder_image" make build-go 2>&1 | tee "$evidence_dir/compile.log"

binary="$scratch/source/bin/linux/$arch/grafana"
test -s "$binary"
docker run --rm --platform "linux/$arch" --entrypoint go \
  --mount "type=bind,src=$scratch/source,dst=/src,readonly" \
  "$builder_image" version -m "/src/bin/linux/$arch/grafana" \
  | tee "$evidence_dir/build-info.txt"
rg -q 'github.com/apache/thrift[[:space:]]+v0\.24\.0' "$evidence_dir/build-info.txt"
sha256sum "$binary" | awk '{print $1 "  grafana"}' | tee "$evidence_dir/binary.sha256"

docker build --platform "linux/$arch" --pull=false \
  --build-context "core=$scratch/source/bin/linux/$arch" \
  -f "$root/docker/grafana/Dockerfile.core-candidate" -t "$image" "$root/docker" \
  2>&1 | tee "$evidence_dir/image-build.log"
docker image inspect --format '{{.Id}} {{.Architecture}}' "$image" | tee "$evidence_dir/image.txt"
docker run --rm --platform "linux/$arch" --entrypoint sha256sum "$image" \
  /usr/share/grafana/bin/grafana | awk '{print $1 "  grafana"}' \
  | tee "$evidence_dir/image-binary.sha256"
cmp "$evidence_dir/binary.sha256" "$evidence_dir/image-binary.sha256"
echo "Evidence directory: $evidence_dir"
