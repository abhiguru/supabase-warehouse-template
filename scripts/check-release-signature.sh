#!/usr/bin/env bash
# The release workflow's check that a pushed tag is signed (docs/RELEASE_CHECKLIST.md, "Signing the tag").
#   bash scripts/check-release-signature.sh TAG
# Run in a clone with the history and with TAG fetched as the tag object (a tag-triggered checkout can leave a plain reference). The signers
# are those of the PREVIOUS final release tag, as committed there (git show PREVIOUS:.github/allowed_signers): the anchor an operator who
# sits on that release has, so a release cannot name its own signers. When that release lists no key (the signed releases begin
# with this one) there is nothing to check against and the step says so.
set -euo pipefail
tag="${1:?usage: check-release-signature.sh TAG}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/upgrade-lib.sh
. "$here/upgrade-lib.sh"

# The newest FINAL release tag reachable from the tagged commit whose version is not this tag's own (as in the dependency audit step).
version="${tag%%[-+]*}"
previous="$(git tag --merged "$tag^{commit}" --list 'v[0-9]*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vxF "$version" | head -n 1 || true)"
if [[ -z "$previous" ]]; then
  echo "::notice title=Signature not checked::No previous final release tag is reachable from $tag, so there is no list of trusted signers to check it against."
  exit 0
fi
signers="$(mktemp)"
trap 'rm -f -- "$signers"' EXIT
git show "$previous:.github/allowed_signers" > "$signers" 2>/dev/null || : > "$signers"
if ! signers_have_key "$signers"; then
  echo "::notice title=Signature not checked::$previous lists no release signing key in .github/allowed_signers, so $tag cannot be checked against it. Operators on $previous do not check signatures either; the next release is checked against the key list of this one."
  exit 0
fi
problem="$(tag_signature_problem "$tag" "$signers" "$(git rev-parse "$tag^{commit}")")"
if [[ -n "$problem" ]]; then
  echo "::error title=Release tag is not signed by a trusted key::$problem (the key list of $previous). Sign the tag with 'git tag -s' using a key listed in .github/allowed_signers of $previous (docs/RELEASE_CHECKLIST.md, \"Signing the tag\")." >&2
  exit 1
fi
echo "$tag is signed by a key listed in .github/allowed_signers of $previous."
