#!/usr/bin/env bash
# Sourced by upgrade.sh and by scripts/upgrade-preflight.sh (the preflight of a release runs from a copy of that release's
# scripts/ directory, so each release's own copy of this file prints that release's CHANGELOG.md). Do not run it.
# Needs say() from the caller; a plain one is defined when the caller has none.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo 'scripts/upgrade-lib.sh is a sourced helper, not a command.' >&2
  exit 1
fi
declare -F say >/dev/null || say() { printf '%s\n' "$*"; }

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
