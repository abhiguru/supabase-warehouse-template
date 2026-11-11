#!/usr/bin/env bash
# The offline bundle of a release (WH-146): everything a facility with no internet needs to install or upgrade, in one file that is carried
# on a USB drive. docs/OPERATOR_INSTALL.md, "Local-only facility".
#
#   bash scripts/offline-bundle.sh make --tag vX.Y.Z --release-images FILE --signing-key KEY --out FILE [--apk FILE]
#       Run on a machine WITH internet, in a checkout that has the release tag and a Docker whose image store keeps digests (Docker 29 or
#       newer, the containerd image store). Pulls the release's images by digest (those of release-images.json, the release asset, and the
#       Docker Hub images the compose file names by digest), saves them, adds the tagged source (a git bundle), the neutral Android app
#       (--apk, optional), SHA256SUMS of everything and a signature of SHA256SUMS made with the release key (ssh-keygen -Y sign,
#       namespace warehouse-offline-bundle). Prints the file name and its SHA-256.
#   bash scripts/offline-bundle.sh open FILE DIR [--signers FILE]
#       Checks FILE and unpacks it into the new directory DIR: only the expected file names, every checksum, and the signature against the
#       keys of FILE (default .github/allowed_signers: the keys that sign release tags are the keys that sign bundles). With no key listed
#       there, the signature is not checked and it says so; with a key listed, a missing or wrong signature refuses. Prints the release, the
#       commit and the signer's fingerprint.
#   bash scripts/offline-bundle.sh load DIR
#       docker load of the bundle's images, then checks that every image is on this host under its digest. Refuses, naming the cause, when this
#       Docker's image store dropped the digests (a classic store before Docker 29).
#   bash scripts/offline-bundle.sh field DIR release|commit|apk
#       Prints one field of DIR/bundle.json.
# Nothing here pushes, pulls source from a network, or changes an installation.
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
NAMESPACE=warehouse-offline-bundle
SEMVER='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
say() { printf '%s\n' "$*"; }
refuse() { printf 'Refusing: %s\n' "$*" >&2; exit 1; }
usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | grep -E '^#   bash' | sed 's/^#   //' >&2
  exit 2
}
(($# >= 1)) || usage
command="$1"; shift

# The keys of an allowed_signers file, for this bundle's namespace: every non-comment line, its `namespaces="git"` replaced.
bundle_signers() {
  sed -E '/^[[:space:]]*(#|$)/d; s/namespaces="[^"]*"/namespaces="'"$NAMESPACE"'"/' "$1"
}
have_key() { grep -Eqv '^[[:space:]]*(#|$)' "$1"; }

case "$command" in
  make)
    TAG='' RELEASE_IMAGES='' KEY='' OUT='' APK=''
    while (($#)); do
      (($# >= 2)) || usage
      case "$1" in
        --tag) TAG="$2" ;; --release-images) RELEASE_IMAGES="$2" ;; --signing-key) KEY="$2" ;; --out) OUT="$2" ;; --apk) APK="$2" ;;
        *) usage ;;
      esac
      shift 2
    done
    [[ "$TAG" =~ $SEMVER ]] || refuse '--tag must be a release tag such as v0.8.0.'
    [[ -f "$RELEASE_IMAGES" && -f "$KEY" && -n "$OUT" ]] || refuse '--release-images and --signing-key must be files, and --out is needed.'
    [[ ! -e "$OUT" ]] || refuse "$OUT exists already."
    [[ -z "$APK" || -f "$APK" ]] || refuse "--apk $APK is not a file."
    for tool in git docker ssh-keygen sha256sum tar node; do command -v "$tool" >/dev/null || refuse "$tool is needed to make a bundle."; done
    commit="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG^{commit}")" || refuse "this checkout has no tag $TAG."
    # The release asset is checked against the tag first (release, commit, recipes hash, references only under the project's registry path).
    node "$HERE/image-recipes.mjs" release-select "$RELEASE_IMAGES" "$TAG" "$commit" >/dev/null || refuse 'release-images.json does not fit this tag (message above).'
    work="$(mktemp -d "$(dirname "$OUT")/.bundle-work.XXXXXX")" || refuse "cannot make a work directory next to $OUT."
    trap 'rm -rf -- "$work"' EXIT
    refs=()
    while IFS= read -r ref; do [[ -z "$ref" ]] || refs+=("$ref"); done < <(node -e '
      const m = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      for (const [, e] of Object.entries(m.images).sort(([a], [b]) => a.localeCompare(b))) console.log(e.ref);' "$RELEASE_IMAGES")
    while IFS= read -r ref; do [[ -z "$ref" ]] || refs+=("$ref"); done < <(git -C "$ROOT" show "$commit:docker/docker-compose.yml" \
      | sed -n 's/^[[:space:]]*image:[[:space:]]*\([^$[:space:]]*@sha256:[0-9a-f]\{64\}\)[[:space:]]*$/\1/p' | LC_ALL=C sort -u)
    ((${#refs[@]})) || refuse 'no image to bundle.'
    for ref in "${refs[@]}"; do
      say "Pulling $ref"
      docker pull --quiet "$ref" >/dev/null || refuse "could not pull $ref."
      # Docker records RepoDigests without a tag (repository@sha256:...).
      name="${ref%@*}"; last="${name##*/}"; want="${name%"$last"}${last%%:*}@${ref##*@}"
      docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$ref" | grep -qxF -- "$want" \
        || refuse "this Docker does not keep the digest of $ref; use Docker 29 or newer (the containerd image store)."
    done
    docker save --output "$work/images.tar" "${refs[@]}" || refuse 'docker save failed.'
    git -C "$ROOT" bundle create "$work/source.bundle" "refs/tags/$TAG" >/dev/null 2>&1 || refuse "git bundle of $TAG failed."
    cp -- "$RELEASE_IMAGES" "$work/release-images.json"
    files=(bundle.json release-images.json images.tar source.bundle)
    if [[ -n "$APK" ]]; then cp -- "$APK" "$work/neutral.apk"; files+=(neutral.apk); fi
    node -e '
      const [release, commit, apk, ...images] = process.argv.slice(1);
      process.stdout.write(JSON.stringify({ format: 1, release, commit, created: new Date().toISOString(), apk: apk || null, images }, null, 2) + "\n");' \
      "$TAG" "$commit" "${APK:+neutral.apk}" "${refs[@]}" > "$work/bundle.json"
    (cd "$work" && sha256sum -- "${files[@]}" > SHA256SUMS && ssh-keygen -Y sign -q -f "$KEY" -n "$NAMESPACE" SHA256SUMS) \
      || refuse 'signing failed (is the key readable, and without a passphrase?).'
    out_abs="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
    (cd "$work" && tar -cf "$out_abs" "${files[@]}" SHA256SUMS SHA256SUMS.sig)
    say "Wrote $OUT ($TAG, commit ${commit:0:12}, ${#refs[@]} images)."
    sha256sum -- "$OUT"
    ;;

  open)
    (($# >= 2)) || usage
    FILE="$1" DIR="$2"; shift 2
    SIGNERS=''
    while (($#)); do
      (($# >= 2)) && [[ "$1" == --signers ]] || usage
      SIGNERS="$2"; shift 2
    done
    [[ -f "$FILE" ]] || refuse "$FILE is not a file."
    [[ ! -e "$DIR" ]] || refuse "$DIR exists already; give a new directory."
    [[ -n "$SIGNERS" ]] || SIGNERS="$ROOT/.github/allowed_signers"
    if [[ ! -f "$SIGNERS" ]]; then SIGNERS=/dev/null; fi
    # Room first: the unpacked copy is about as large as the file.
    size="$(stat -c %s -- "$FILE")"
    parent="$(dirname "$DIR")"
    avail="$(df --output=avail -B1 -- "$parent" | tail -n 1 | tr -d ' ')"
    [[ "$avail" =~ ^[0-9]+$ ]] && ((avail > size + 1073741824)) || refuse "$parent has less free space than the bundle needs (${size} bytes and 1 GiB more)."
    # Only the expected names, plain files, no path: checked from the listing before anything is extracted.
    names="$(tar -tf "$FILE")" || refuse "$FILE is not a readable archive."
    while IFS= read -r name; do
      case "$name" in
        bundle.json|release-images.json|images.tar|source.bundle|neutral.apk|SHA256SUMS|SHA256SUMS.sig) ;;
        *) refuse "the bundle holds an unexpected entry (${name:0:60})." ;;
      esac
    done <<< "$names"
    for need in bundle.json release-images.json images.tar source.bundle SHA256SUMS SHA256SUMS.sig; do grep -qxF "$need" <<< "$names" || refuse "the bundle has no $need."; done
    [[ -z "$(sort <<< "$names" | uniq -d)" ]] || refuse 'the bundle lists an entry twice.'
    mkdir -m 0700 -- "$DIR"
    fail_open() { rm -rf -- "$DIR"; refuse "$*"; }
    tar -xf "$FILE" -C "$DIR" --no-same-owner --no-same-permissions || fail_open "$FILE could not be unpacked."
    for entry in "$DIR"/*; do [[ -f "$entry" && ! -L "$entry" ]] || fail_open "the bundle holds something that is not a plain file ($(basename "$entry"))."; done
    # The sums must name exactly the files present (apart from the sums themselves), and every one must match.
    listed="$(awk '{ print $2 }' "$DIR/SHA256SUMS" | LC_ALL=C sort)"
    present="$(cd "$DIR" && ls -1 | grep -vx -e SHA256SUMS -e SHA256SUMS.sig | LC_ALL=C sort)"
    [[ "$listed" == "$present" ]] || fail_open 'SHA256SUMS does not list exactly the files of the bundle.'
    (cd "$DIR" && sha256sum --check --quiet SHA256SUMS) || fail_open 'a checksum of the bundle does not match: the file is damaged or was changed.'
    if have_key "$SIGNERS"; then
      command -v ssh-keygen >/dev/null || fail_open 'ssh-keygen (the OpenSSH client) is needed to check the signature of the bundle.'
      tmp="$(mktemp)"; bundle_signers "$SIGNERS" > "$tmp"
      principal="$(ssh-keygen -Y find-principals -f "$tmp" -s "$DIR/SHA256SUMS.sig" 2>/dev/null | head -n 1 || true)"
      out=''
      if [[ -z "$principal" ]] || ! out="$(ssh-keygen -Y verify -f "$tmp" -I "$principal" -n "$NAMESPACE" -s "$DIR/SHA256SUMS.sig" < "$DIR/SHA256SUMS" 2>&1)"; then
        rm -f -- "$tmp"
        fail_open "the signature of the bundle is not by a key listed in $SIGNERS (${out:-no listed key made it}). Do not use this file."
      fi
      rm -f -- "$tmp"
      say "Signature:    checked ($(tr '\n' ' ' <<< "$out" | sed 's/ $//'))"
    else
      say "Warning: $SIGNERS lists no release signing key, so the signature of this bundle was NOT checked (only its checksums). Compare the key on the release page with the fingerprint published in the README (Security)." >&2
    fi
    node -e '
      const m = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      if (m.format !== 1 || !/^v\d/.test(m.release) || !/^[0-9a-f]{40}$/.test(m.commit) || !Array.isArray(m.images) || !m.images.length) { console.error("bundle.json is not a version 1 bundle description."); process.exit(1); }
      for (const ref of m.images) if (!/^[a-z0-9][a-z0-9.\/_-]*(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$/.test(ref)) { console.error("bundle.json names an image reference that is not by digest."); process.exit(1); }
      console.log(`Bundle:       release ${m.release}, commit ${m.commit.slice(0, 12)}, ${m.images.length} images${m.apk ? ", neutral app " + m.apk : ""}`);' "$DIR/bundle.json" \
      || fail_open 'bundle.json is not usable.'
    ;;

  load)
    (($# == 1)) || usage
    DIR="$1"
    [[ -f "$DIR/images.tar" && -f "$DIR/bundle.json" ]] || refuse "$DIR is not an opened bundle (bash scripts/offline-bundle.sh open)."
    command -v docker >/dev/null || refuse 'docker is not installed.'
    say 'Loading the images of the bundle (a few minutes)...'
    docker load --quiet --input "$DIR/images.tar" >/dev/null || refuse 'docker load failed.'
    missing=0
    while IFS= read -r ref; do
      if ! docker image inspect "$ref" >/dev/null 2>&1; then missing=$((missing + 1)); say "Not found after loading: $ref" >&2; fi
    done < <(node -e 'for (const r of JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).images) console.log(r)' "$DIR/bundle.json")
    ((missing == 0)) || refuse "$missing image(s) are not on this host under their digest after loading. This Docker's image store does not keep digests across save and load (the classic store before Docker 29); install Docker 29 or newer (containerd image store), then run the command again."
    say 'The images of the bundle are on this host.'
    ;;

  field)
    (($# == 2)) || usage
    node -e '
      const m = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      const v = { release: m.release, commit: m.commit, apk: m.apk ?? "" }[process.argv[2]];
      if (v === undefined) process.exit(2);
      console.log(v);' "$1/bundle.json" "$2"
    ;;
  *) usage ;;
esac
