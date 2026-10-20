# Release checklist

Open-source availability does not imply safe production deployment: what is still open is in
[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md). A release is cut from `main` with a semantic version tag
(`vMAJOR.MINOR.PATCH`, optionally with `-prerelease` and `+build`), and publishing it is a manual maintainer step.

## Boundaries

- Do not revoke or rotate another installation's credentials. New installations generate their own secrets; setup reruns
  preserve existing environment files (only the MSG91 provider lines change when a new `--provider-env` is given).
  Rotating an installation's own signing keys is the operator's explicit `bash rotate-keys.sh --yes`, never a release step.
- Do not mark a task complete without recorded evidence. A passing source scan does not prove application security or
  native-device compatibility.

## Mobile contract before a release

The `contract` CI job checks this backend against one commit of the app,
`MOBILE_REF` in `.github/workflows/ci.yml`. The pin does not move by itself and
the job compares names only, so before every release of either repository:

- [ ] Set `MOBILE_REF` to the full 40-character SHA of the app commit being
      released (a pushed commit of `abhiguru/rn-warehouse-template`), in the same
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

## Tag validation

A `v*` tag runs `release.yml`: the semantic-version gate (`scripts/check-release.sh`), `npm test`, `npm audit`, the
Chrome for Testing freshness check of the PDF renderer (`scripts/check-cft-freshness.mjs`; a Chrome more than 14 days
behind Stable blocks the release) and a Compose validation against generated operator state. Then publish by hand:
`gh release create <tag> --verify-tag --notes-file <release-notes.md>`.
