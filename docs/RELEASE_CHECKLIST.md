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
- [ ] The release contains `upgrade.sh`, `scripts/pg-major.sh` and, in `setup.sh`, `operator_lock_or_inherited` and the recreate of
      the `functions` container (the steps that depend on the release live in its `setup.sh`: `CONTRIBUTING.md`, "Releases").
      `scripts/check-release-contents.sh` checks these and the `CHANGELOG.md` section when the tag is pushed.

## Tag validation

A `v*` tag runs `release.yml`: the semantic-version gate (`scripts/check-release.sh`), the release contents gate
(`scripts/check-release-contents.sh`: the `CHANGELOG.md` section, `upgrade.sh`, `scripts/pg-major.sh`, the inherited lock and the
functions recreate in `setup.sh`), `npm test`, `npm audit`, the
Chrome for Testing freshness check of the PDF renderer (`scripts/check-cft-freshness.mjs --mode warn`: a Chrome more than 14 days
behind Stable is a warning on the run and never blocks the tag; the weekly issue is the signal) and a Compose validation against
generated operator state. Then its second job, `publish-images`, builds, scans and publishes the images ([below](#image-publication)).
Wait for both to pass before the next sections.

## Image publication

The `publish-images` job runs after the checks above, with `packages: write` and `contents: write` (no other job has either). It builds
every Compose image of the tagged commit with `--no-cache`, scans each with `npm run scan:images` (the section "Image scan before a
release" above, run on the runner with Trivy 0.76.0 pinned by checksum in the workflow; a HIGH or CRITICAL row no valid exception covers, or an
expired exception, fails the job before anything is pushed), logs in to `ghcr.io`, pushes each image as
`ghcr.io/abhiguru/supabase-warehouse-template/<service>:<tag>` (`scripts/publish-images.sh`), checks that every image can be read
without credentials, and attaches `release-images.json` to the GitHub Release (a draft is made when the release does not exist yet).
Every image carries the labels `org.opencontainers.image.revision` (the commit) and `org.opencontainers.image.version` (the tag), and a facility
refuses a pulled image whose revision is not its checkout's commit. Facilities at the tag pull by those digests
([OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#rerun-and-upgrade)); a facility that cannot builds from the recipe as before. The manual scan above
stays as the early check on the release commit: a scan that fails here fails the tag's job.

**A final tag re-tags the images of its release candidate; it does not rebuild them.** When `vX.Y.Z` is on the same commit as the newest
`vX.Y.Z-rc.N` (the flow above: tag the rc, rehearse, tag the same commit), and that candidate's `release-images.json` can be downloaded and fits the
commit, the job builds and scans nothing: it copies each image of the candidate to `<service>:vX.Y.Z` by digest (`docker buildx imagetools
create --prefer-index=false`, a carbon copy: the digest does not change) and attaches a `release-images.json` with the same digests and
`"release": "vX.Y.Z"`. The job log says `... they are re-tagged, not built again` and the build and scan steps are skipped. **What ships is
what was rehearsed**, and what was scanned when the candidate was published: the images carry that day's packages, and a vulnerability
published between the candidate and the final does not fail the final. That is the point (the bytes under test are the bytes released), and
the price: if you want the newer packages, cut another candidate (`-rc.N+1`) on the commit, scan it, rehearse again and tag the final on
that. A final on a commit that has no candidate, or whose newest candidate is on another commit or has no usable list, builds and scans
as a candidate does; a scan that fails then is handled as in the first item below. The label `org.opencontainers.image.version` of a re-tagged image
names the candidate it was built for; the revision is the commit of both.

- [ ] **Once, before the first release candidate: switch on GitHub's immutable releases for the repository.** On GitHub: the repository's
      **Settings**, **General**, the **Releases** section, **Enable release immutability** (the control may move: the GitHub documentation page
      "Immutable releases" says where it is). From then on a published release's tag and assets cannot be changed or deleted, so
      `release-images.json` of a published release is what the maintainer published, whoever later holds a token that can write
      release assets. A draft stays editable (this workflow attaches the file to a draft), the job cannot replace the file of a published
      release (a re-run after publication fails at the upload), and a mistake in a published candidate is corrected by the next candidate,
      never by editing it. Without this setting the file is an ordinary release asset that anyone with write access to the repository's releases
      can replace; the revision label check still refuses an image built from another commit (an older release's image, say).
- [ ] `publish-images` is green for the tag. If its scan failed, fix the recipe or have the owner renew the exception on `main` and tag
      again (`-rc.N+1`); never move a tag. Re-running the job on a draft release builds again and replaces `release-images.json` (the
      digests change; a facility that already pulled keeps what it has); on a published release the upload is refused.
- [ ] **Once, with the first release candidate (nothing in this job has run against `ghcr.io` before it):** if the push is refused
      (`denied: permission_denied`), open each package's settings, "Manage Actions access", and add this repository with the Write role,
      then re-run the job. GitHub creates each package private. For every package of the repository
      (`github.com/abhiguru?tab=packages`: `db`, `functions`, `gateway`, `pdf-renderer`, `storage` and the optional `cups`, `sensor-bridge` and
      `supavisor`) open Package settings, link it to this repository if it is not, and set its visibility to **Public**; then re-run the job. The
      step "Check that the images pull without credentials" fails until every package is public, so a private package is never
      discovered by a facility silently building instead.
- [ ] In the release (a draft, or published) check the asset `release-images.json`: `release` is the tag, `commit` is
      `git rev-parse vX.Y.Z^{commit}`, there is one image for every recipe (`jq -r '.images | keys[]' release-images.json`: the services of
      `docker/docker-compose.yml` that have `build:`), and each `ref` is `ghcr.io/abhiguru/supabase-warehouse-template/<service>@sha256:<64 hex>`.
- [ ] A release candidate's draft is **published as a pre-release before the rehearsal** (`gh release edit vX.Y.Z-rc.N --draft=false
      --prerelease`), or the rehearsal's `setup.sh` finds no file and builds, which proves nothing about the pull. The rehearsal output must
      say `Pulled N image(s) from the release (...)`. The final's job needs the candidate's list, so keep the candidate's release (draft or
      published) until the final has been tagged.

## Upgrade rehearsal from the previous tag

The `operator-upgrade` CI job runs `upgrade.sh --ref` from the previous tag (or the merge base) to the change, but it cannot run
the new tag itself (a commit is not a release tag). So the rehearsal runs on a release candidate, and the final tag goes on the same
commit afterwards: a failed rehearsal never leaves a published `vX.Y.Z` that has to be moved.

- [ ] Tag the release commit `vX.Y.Z-rc.N` (`git tag -a vX.Y.Z-rc.N <commit>`, push it) and wait for `release.yml` to pass. The
      `CHANGELOG.md` section is `## vX.Y.Z (date)`; `upgrade.sh` prints it for the candidate too.
- [ ] On a **throwaway** installation of the previous release (its own state and project name; never a facility's), with some data
      in it, run `bash upgrade.sh --dry-run vX.Y.Z-rc.N` and then `bash upgrade.sh vX.Y.Z-rc.N`. Both must end well; the last line of
      `$WAREHOUSE_STATE_DIR/config/upgrades.log` must end in `ok`, `config/upgrade-in-progress` must be gone, and
      `node scripts/doctor.mjs` must pass.
- [ ] Read what `upgrade.sh` printed under "What vX.Y.Z-rc.N asks of the operator": it must be the operator actions of this release and
      no other release's.
- [ ] If the previous release is on another PostgreSQL major, `upgrade.sh` must refuse and name the "Major PostgreSQL upgrade"
      section; rehearse that procedure instead.
- [ ] Once, for the first release that has the upgrade record: stop a rehearsal in the middle (`kill -9` of `upgrade.sh` while `setup.sh`
      runs), check that `node scripts/doctor.mjs --local` reports the interrupted upgrade, and finish it with the same command.
- [ ] Rehearsal passed: tag the same commit `vX.Y.Z` (`git tag -a vX.Y.Z vX.Y.Z-rc.N^{commit}`), push it, wait for `release.yml`.
      Failed: fix on `main` and start again with `-rc.N+1`; do not move a tag.
- [ ] Record in the release pull request or the release note: the previous tag, the candidate, the tag, the date and the result.

## Release note

Publish by hand. The `publish-images` job has already made the release as a **draft** that holds `release-images.json`; give it its
title and note and publish it: `gh release edit vX.Y.Z --draft=false --title '<title>' --notes-file <release-notes.md>` (a pre-release tag
is made a pre-release: add `--prerelease` if you publish one by hand). If you made the release before the job ran, the job only attaches
the file. Until the release is published a facility cannot fetch the file and builds, which is the old behaviour. Operators read the note,
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

## A security fix: which line, which tag

The rules and their reasons are in [CONTRIBUTING.md](../CONTRIBUTING.md), "How a security fix ships".

- [ ] The fix is on `main` with its test.
- [ ] **Current line.** If `main` holds nothing unreleased beyond the fix, tag the next patch from `main`. Otherwise ship the fix as the
      next minor release from `main` (all of the checklist above applies). There is no release branch for the current line.
- [ ] **Previous line, still supported** (6 months after the current minor's first release), and the fix is **code only**: no file under
      `migrations/` is part of it. Cherry-pick it onto `release/MAJOR.MINOR` of that line (create the branch from its last tag if it
      does not exist; the pull request runs CI, which refuses a change to `migrations/`), write the `CHANGELOG.md` section of the patch
      release on the branch **and add the same section to `main`'s `CHANGELOG.md`**, tag the patch on the branch, and run the checks
      above for that tag too.
- [ ] **The fix needs SQL: no backport.** The previous line's release note (a new patch release of it, if it needs one for the
      notice) tells its operators to upgrade to the next minor release. Never put a migration on a `release/*` branch.
- [ ] Two releases (one when there is no backport), each titled "... Security: ..." and naming the other.
- [ ] Owner action, once: a ruleset for `release/*` like `main`'s (docs/PRODUCTION_DEPENDENCIES.md).
