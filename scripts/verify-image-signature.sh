#!/usr/bin/env bash
# Checks the signature of one release image: bash scripts/verify-image-signature.sh <repository>@sha256:<digest>
# The release workflow (release.yml, job publish-images) signs every image it publishes with cosign, keyless: the signature is made with
# the workflow's GitHub OIDC identity and recorded in the public Rekor log. The check below accepts a signature only when its certificate
# names a tag run of release.yml in this repository, issued by GitHub's Actions OIDC issuer (docs/CONTAINER_SECURITY.md, "Image signatures").
# Exit status, so the callers (build-images.sh, upgrade-prepull.sh, release.yml) can decide:
#   0   the signature checks out
#   1   the image has no signature, or one that does not check: it must not be used
#   2   wrong use of the script
#   10  this tree is an older release whose images are not signed (it has no docker/images-signed): nothing was checked
#   11  cosign is not installed on this host: the signature could not be checked
# A message that names the image goes to standard error for 1 and 11.
# WAREHOUSE_COSIGN_IDENTITY_REGEXP and WAREHOUSE_COSIGN_ISSUER override the identity (a fork that signs its own releases); WAREHOUSE_SIGNED=yes
# makes the check apply to a tree without the marker (the release workflow, which has just signed).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(dirname "$HERE")"
ref="${1:-}"
[[ $# -eq 1 && "$ref" =~ ^[a-z0-9./_-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] || { echo 'Usage: bash scripts/verify-image-signature.sh <repository>@sha256:<digest>' >&2; exit 2; }
if [[ "${WAREHOUSE_SIGNED:-}" != yes && ! -f "$TREE/docker/images-signed" ]]; then
  echo "Image signature of $ref: not checked, this release's tree has no docker/images-signed (an older release, whose images are not signed)."
  exit 10
fi
if ! command -v cosign >/dev/null; then
  echo "Image signature of $ref: cannot be checked, cosign is not installed on this host (docs/OPERATOR_INSTALL.md, \"Check the image signatures\")." >&2
  exit 11
fi
identity="${WAREHOUSE_COSIGN_IDENTITY_REGEXP:-^https://github\\.com/abhiguru/supabase-warehouse-template/\\.github/workflows/release\\.yml@refs/tags/v[0-9].*\$}"
issuer="${WAREHOUSE_COSIGN_ISSUER:-https://token.actions.githubusercontent.com}"
if out="$(cosign verify --certificate-identity-regexp "$identity" --certificate-oidc-issuer "$issuer" "$ref" 2>&1 >/dev/null)"; then
  echo "Image signature of $ref: verified (signed by the release workflow)."
  exit 0
fi
echo "Image signature of $ref: NOT VERIFIED, so the image is not used (${out##*$'\n'})." >&2
exit 1
