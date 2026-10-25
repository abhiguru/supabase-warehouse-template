# Release checklist

Open-source availability does not imply safe production deployment: what is still open is in
[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md). A release is cut from `main` with a semantic version tag
(`vMAJOR.MINOR.PATCH`, optionally with `-prerelease` and `+build`), and publishing it is a manual maintainer step. Operators follow
these tags and move with `bash upgrade.sh vX.Y.Z` ([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade)); the support window
(the current and the previous minor) is in [SECURITY.md](../SECURITY.md). The order below is the order of the work.

## Boundaries

- Do not revoke or rotate another installation's credentials. New installations generate their own secrets; setup reruns
  preserve existing environment files (only the MSG91 provider lines change when a new `--provider-env` is given).
  Rotating an installation's own signing keys is the operator's explicit `bash rotate-keys.sh --yes`, never a release step.
- Do not mark a task complete without recorded evidence. A passing source scan does not prove application security or
  native-device compatibility.

## Mobile contract before a release

The `contract` CI job compares names only against the pinned app commit
([CONTRIBUTING.md](../CONTRIBUTING.md#mobile-companion-pin-mobile_ref)), so before every release of either repository:

- [ ] Move the pin (`MOBILE_REF`) to the app commit being released, in the same
      pull request as any backend change that commit needs.
- [ ] With that app commit checked out and its `node_modules` installed, run the
      live comparison against a running stack of this backend commit:
      `WAREHOUSE_STATE_DIR=<state> node scripts/check-mobile-contract.mjs <app checkout> --live`.
      It must report no missing RPC, table or function and no `mismatches`
      (overloads, argument names and the grant to signed-in users).
- [ ] Record the backend and app commit pair in the pull request.

## Image scan before a release

Operating-system packages come from live repositories, so an image built from
an unchanged recipe on another day has other packages, and a cached layer keeps
the packages of the day it was cached (owner decision D5: no snapshot mirrors; a
fresh build and scan before each release instead). Before every release tag:

- [ ] On the release commit, with a **throwaway** operator state of this
      checkout (its own project name; never an installation's state, whose
      running containers would be left on images no recorded build made; the
      scan refuses a project that has containers), run `npm run scan:images`
      (Trivy 0.74.0 or later; record `trivy --version` in the pull request). It builds every Compose image with `--no-cache` and scans
      each once, in full; it must end with "Container image scan passed". Read its
      warnings for exceptions that covered nothing, then remove the throwaway
      project's `<project>-*` images.
- [ ] If it fails on an expired exception or a new row, fix the recipe, or have
      the owner review the entry in `docker/image-exceptions.json` (new
      `reviewed` date, `expires` at most 90 days later, reason updated with the
      scan's counts), in the release pull request.
- [ ] Record the scan date and the per-image row counts in the pull request, read from the single report
      (`<report_dir>/<image>.json`): fixable rows with
      `jq '[.Results[]?.Vulnerabilities[]? | select((.FixedVersion // "") != "" or .Status == "fixed")] | length' <report_dir>/<image>.json`,
      all HIGH/CRITICAL rows with
      `jq '[.Results[]?.Vulnerabilities[]?] | length' <report_dir>/<image>.json`. This one
      `--no-cache` build and scan is the whole rebuild step: do not build twice. Never
      release from images built from cache.

- [ ] Before a release that changes `docker/sensor-bridge/`, check that `docker/sensor-bridge/LICENSE` is present.

## Changelog before the tag

- [ ] In `CHANGELOG.md`, rename `## Unreleased` to `## vX.Y.Z (YYYY-MM-DD)` and open a new empty `## Unreleased` above it.
      `upgrade.sh` prints the operator actions by that heading; a release without its section sends the operator to the release note.
- [ ] Every operator action of the release is in that section's "Operator actions" list, numbered, each with the exact command.
- [ ] If the release changes the PostgreSQL major, the section says so at the top and links the "Major PostgreSQL upgrade" procedure
      (`upgrade.sh` refuses such a move). If the migrations were squashed, the section lists the migration names the new baseline replaces.
- [ ] The release contains `upgrade.sh`, `scripts/pg-major.sh` and, in `setup.sh`, `operator_lock_or_inherited`.

## Tag validation

A `v*` tag runs `release.yml`: the semantic-version gate (`scripts/check-release.sh`), `npm test`, `npm audit`, the
Chrome for Testing freshness check of the PDF renderer (`scripts/check-cft-freshness.mjs`; a Chrome more than 14 days
behind Stable blocks the release) and a Compose validation against generated operator state. Wait for it to pass before the
next two sections.

## Upgrade rehearsal from the previous tag

The `operator-upgrade` CI job runs `upgrade.sh --ref` from the previous tag to the change, but it cannot run the tag itself (a
commit is not a release tag). Once the tag is pushed and `release.yml` is green:

- [ ] On a **throwaway** installation of the previous release (its own state and project name; never a facility's), with some data
      in it, run `bash upgrade.sh --dry-run vX.Y.Z` and then `bash upgrade.sh vX.Y.Z`. Both must end well; the last line of
      `$WAREHOUSE_STATE_DIR/config/upgrades.log` must end in `ok`, and `node scripts/doctor.mjs` must pass.
- [ ] Read what `upgrade.sh` printed under "What vX.Y.Z asks of the operator": it must be the operator actions of this release and
      no other release's.
- [ ] If the previous release is on another PostgreSQL major, `upgrade.sh` must refuse and name the "Major PostgreSQL upgrade"
      section; rehearse that procedure instead.
- [ ] Record in the release pull request or the release note: the previous tag, the tag, the date and the result.

## Release note

Publish by hand: `gh release create vX.Y.Z --verify-tag --title '<title>' --notes-file <release-notes.md>`. Operators read this,
so write it for them. Title: `vX.Y.Z`, or `vX.Y.Z Security: <what, in a few words>` for a security fix (the support policy in
[SECURITY.md](../SECURITY.md) says a fix is announced by a release with "Security" in its title). Template:

```markdown
## Upgrade

bash upgrade.sh vX.Y.Z            (from vA.B.C or later in the same PostgreSQL major; run `--dry-run` first to see the plan)

## Security                       (only for a security release)

- Affected: vA.B.C to vX.Y.(Z-1) (and the previous line vP.Q.R to vP.Q.S)
- Impact: <what an attacker could do, without a recipe>
- Fixed in: vX.Y.Z (and vP.Q.T, the backport)
- Operator action besides the upgrade: <none | exact commands>

## Operator actions

1. <copied from the "Operator actions" list of CHANGELOG.md, with the exact commands>

## What changed

<five lines or fewer; the rest is in CHANGELOG.md>

## Compatibility

- App: <the app release or commit this backend is tested with (MOBILE_REF)>
- PostgreSQL: <major; if it changed: "upgrade.sh refuses this move: follow Major PostgreSQL upgrade in docs/OPERATOR_INSTALL.md">
- Supported lines now: X.Y (current) and P.Q (until <date, 6 months after the X.Y.0 release>)
```

## Backport of a security fix

- [ ] The fix is on `main` with its test. If the previous minor line is still supported (6 months after the current minor's first
      release), cherry-pick it onto `release/MAJOR.MINOR` of that line (create the branch from its last tag if it does not exist),
      add the `CHANGELOG.md` section, and run the checks above for the backport tag too.
- [ ] Two releases, two notes, both titled "... Security: ...", each naming the other.
