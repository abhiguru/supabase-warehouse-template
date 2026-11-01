#!/usr/bin/env bash
# The release workflow's check that a pushed tag is signed (docs/RELEASE_CHECKLIST.md, "Signing the tag").
#   bash scripts/check-release-signature.sh TAG
# Run in a clone with the history and with TAG fetched as the tag object (a tag-triggered checkout can leave a plain reference). The signers
# are those of the PREVIOUS final release tag, as committed there (git show PREVIOUS:.github/allowed_signers): the anchor an operator who
# sits on that release has, so a release cannot name its own signers, and a release that lists no key after one that does is refused.
# When the previous release lists no key and the tagged commit does (the first signed release), the tag is checked against the commit's
# own list; when neither lists a key, or there is no previous final tag, the step says so and checks nothing.
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
dir="$(mktemp -d)"
trap 'rm -rf -- "$dir"' EXIT
commit="$(git rev-parse "$tag^{commit}")"
git show "$previous:.github/allowed_signers" > "$dir/previous" 2>/dev/null || : > "$dir/previous"
git show "$commit:.github/allowed_signers" > "$dir/tagged" 2>/dev/null || : > "$dir/tagged"
fail() {
  echo "::error title=Release tag is not signed by a trusted key::$1" >&2
  exit 1
}
if signers_have_key "$dir/previous"; then
  signers_have_key "$dir/tagged" || fail "$previous lists a release signing key in .github/allowed_signers and $tag lists none: a release that drops the key list would let operators skip the check. Keep the key line."
  problem="$(tag_signature_problem "$tag" "$dir/previous" "$commit")"
  [[ -z "$problem" ]] || fail "$problem (the key list of $previous). Sign the tag with 'git tag -s' using a key listed in .github/allowed_signers of $previous (docs/RELEASE_CHECKLIST.md, \"Signing the tag\")."
  echo "$tag is signed by a key listed in .github/allowed_signers of $previous."
elif signers_have_key "$dir/tagged"; then
  # The first signed release: operators at $previous check nothing, so the tagged commit's own list is all there is to check against.
  problem="$(tag_signature_problem "$tag" "$dir/tagged" "$commit")"
  [[ -z "$problem" ]] || fail "$problem (the key list of $tag itself: $previous lists none). Sign the tag with 'git tag -s' using the key you added to .github/allowed_signers."
  echo "::notice title=First signed release::$previous lists no release signing key, so $tag is checked against its own key list. Publish the fingerprint (ssh-keygen -lf) in the README (Security) and the release note: operators at $previous compare it by hand."
else
  echo "::notice title=Signature not checked::$previous lists no release signing key in .github/allowed_signers and neither does $tag, so nothing is checked."
fi
