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

## Legal text before a public app build (WH-140)

The app's terms of use and privacy notice are a template that no lawyer has reviewed yet. This backend serves their facility values
([PRIVACY_FOR_OPERATORS.md](PRIVACY_FOR_OPERATORS.md)); the app holds the text.

- [ ] The owner has recorded the lawyer's review, with its date, and the app's `LEGAL_TEXT_REVIEWED` constant is `true` (the app's release check
      refuses a public build while it is `false`). A release for a public store waits for this.
- [ ] The default facility's legal values are real, not placeholders (`node scripts/doctor.mjs` shows no legal warning).

## Mobile contract before a release

The `contract` CI job compares names only against the pinned app commit
([CONTRIBUTING.md](../CONTRIBUTING.md#mobile-companion-pin-mobile_ref)), so before every release of either repository:

- [ ] Move the pin (`MOBILE_REF`) to the app commit being released, in the same
      pull request as any backend change that commit needs.
- [ ] With that app commit checked out and its `node_modules` installed, run the
      live comparison against a running stack of this backend commit, run **from that stack's own checkout** (the script reads the compose
      files and the images of the checkout it sits in, so another checkout would compare another commit):
      `WAREHOUSE_STATE_DIR=<state> node scripts/check-mobile-contract.mjs <app checkout> --live`.
      It must report no missing RPC, table or function and no `mismatches`
      (overloads, argument names and the grant to signed-in users).
- [ ] Set `minimumClientVersion` in `app-compat.json` to the oldest app build this release still answers (a backend release supports the newest
      app release; older builds are told to update, [API_CONTRACT.md](API_CONTRACT.md#which-app-builds-a-release-supports-and-what-the-backend-tells-the-app)).
- [ ] `MOBILE_MIN_REF` (`.github/workflows/ci.yml`) lists the app commit of every build handed out with the current `minimumClientVersion`.
      Add the commit of each app build released with that version; when the minimum is raised, replace the list with the commits of the new
      minimum, in the same pull request. For each listed commit, `scripts/check-min-apps.sh` (the `contract` job and `release.yml` run it) must
      pass, and so must the live comparison, with that commit checked out and its `node_modules` installed, from the running stack's own
      checkout: `WAREHOUSE_STATE_DIR=<state> node scripts/check-mobile-contract.mjs <app checkout at that commit> --live`. CI compares names only;
      the live comparison is what catches changed argument names and grants. A function, table or edge function that these apps call cannot be
      dropped in a release that does not raise the minimum
      ([CONTRIBUTING.md](../CONTRIBUTING.md#the-oldest-supported-apps-mobile_min_ref)). Say in the release note that builds below the minimum are
      told to update.
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
- [ ] A release that changes `scripts/watch-timer.sh` or `scripts/backup-usb.sh` in a way that changes the units, the udev rule or the
      installed helper (any edit changes their recipe hash) carries an Operator action: `sudo bash scripts/watch-timer.sh install --state <state>`
      and/or `sudo bash scripts/backup-usb.sh setup --state <state>`. Until it is done, `root_copy_stale` reminds weekly.
- [ ] If the release changes the PostgreSQL major, the section says so at the top, writes the procedure, its way back and its disk need into the
      "Major PostgreSQL upgrade" section of `docs/OPERATOR_INSTALL.md` and links it (`upgrade.sh` refuses such a move). If the migrations were squashed, the section lists the migration names the new baseline replaces.
- [ ] The release contains `upgrade.sh`, `scripts/pg-major.sh` and, in `setup.sh`, `operator_lock_or_inherited` and the recreate of
      the `functions` container (the steps that depend on the release live in its `setup.sh`: `CONTRIBUTING.md`, "Releases").
      `scripts/check-release-contents.sh` checks these and the `CHANGELOG.md` section when the tag is pushed.

## Signing the tag

Release tags are signed with an SSH key, and `upgrade.sh` refuses a tag that no key in the `.github/allowed_signers` of the installed
checkout signed. One-time setup (the maintainer, once):

- [ ] Create the signing key on the maintainer's own machine, **not** on the CI runner or any host that builds releases, with a passphrase
      (a hardware key, `ssh-keygen -t ed25519-sk`, is better), and keep a copy of the private key away from that machine:
      `ssh-keygen -t ed25519 -C "warehouse-release-signing" -f ~/.ssh/warehouse_release_signing`.
- [ ] Add the public key to `.github/allowed_signers` as one line (`release namespaces="git" ssh-ed25519 AAAA... warehouse-release-signing`,
      the file's comment shows the form), in a commit of its own, **before** the first signed tag, and release that commit. Never change this
      file in a pull request that is not about the key.
- [ ] In the clone used for tagging only (not globally): `git config gpg.format ssh`,
      `git config user.signingkey ~/.ssh/warehouse_release_signing.pub`.
- [ ] Publish the key's fingerprint (`ssh-keygen -lf ~/.ssh/warehouse_release_signing.pub`) in the README under a "Security" heading and in each
      release note: an operator whose checkout lists no key yet is shown the fingerprint of the release's key and compares it with these.
- [ ] GitHub's immutable releases are switched on for the repository (see [Image publication](#image-publication)).

Every release: sign with `git tag -s vX.Y.Z-rc.N <commit> -m "..."` (instead of `git tag -a`), then check it before the push:
`git -c gpg.ssh.allowedSignersFile=.github/allowed_signers tag -v vX.Y.Z-rc.N`.

How it is checked. Until a release lists a key, nothing is checked: `upgrade.sh` warns that the checkout lists no key and goes on, and
`release.yml` prints a notice. From the first release that lists a key, a checkout at that release (or later) refuses any tag not signed by
a key of ITS OWN list, and `release.yml` checks the pushed tag against the list of the previous final release, as an operator at that
release would (for the first signed release, whose predecessor lists no key, against the release's own list). Only an SSH signature counts: a PGP or
X.509 signature is refused, whatever the host keyring holds. A release that lists no key after one that does is refused (a downgrade). A release therefore cannot add its own signers: **key rotation** needs one release signed with the old key that carries the
new key line; keep the old line for at least two releases. A lost key means releases cannot be verified until such a bridge release signed
by a still-listed key. `--ref` is not verified.

## Tag validation

A `v*` tag runs `release.yml`: the semantic-version gate (`scripts/check-release.sh`), the release contents gate
(`scripts/check-release-contents.sh`: the `CHANGELOG.md` section, `upgrade.sh`, `scripts/pg-major.sh`, the inherited lock and the
functions recreate in `setup.sh`), `npm test`, the dependency advisories this release adds over the previous tag (`scripts/audit-compare.mjs --with-root`), the
Chrome for Testing freshness check of the PDF renderer (`scripts/check-cft-freshness.mjs --mode warn`: a Chrome more than 14 days
behind Stable is a warning on the run and never blocks the tag; the weekly issue is the signal) and a Compose validation against
generated operator state. Before the tests it checks that the tag is signed by a key the previous release lists ([above](#signing-the-tag)). Then its second job, `publish-images`, builds, scans and publishes the images ([below](#image-publication)).
Wait for both to pass before the next sections.

**Before pushing the tag, run the full CI on the commit with `workflow_dispatch`.** A push to `main` that only repeats a squash-merged pull
request whose own run passed in full on the identical tree skips the long jobs (`migrations`, `contract`, `operator-install`,
`operator-upgrade`, and the storage and renderer jobs); the run log says so in a notice naming the pull request, its run and the tree.
A skipped job is not a success, so the release gate below refuses such a commit, naming the two missing checks. Open Actions > CI > Run
workflow, choose the branch that holds the commit (a `workflow_dispatch` run tests the branch tip, so the tag's commit must be that tip),
and wait for it to finish; the gate then passes. Pull requests, the weekly schedule, `workflow_dispatch` and pushes to `release/**` always run in full.
Do not use "Re-run jobs" on the skipped push run, even where the gate's message suggests it: the re-run skips again, and its skipped checks become the newest on the
commit, which also undoes a passing `workflow_dispatch` run. Start a new `workflow_dispatch` run instead.

**Before pushing the tag, wait for green `operator-install` and `operator-upgrade` on the commit.** Neither is a required check on `main`
(they take up to an hour and run on one machine), so nothing else stops a tag on a commit whose installation or upgrade run failed. The
first step of the `release` job after Node is set up, `scripts/check-release-ci.mjs`, asks the GitHub API for the check runs of the tagged
commit and fails, naming the missing or failed one, unless the newest run of each is a completed success. It never waits: if CI is still
running or failed, let it finish or re-run the failed job (for a tag on an older commit, open that commit's CI run in Actions and use "Re-run jobs"; "Run workflow" on a branch only tests the branch tip), then re-run the release workflow. A final tag on the commit of its release candidate asks about that same commit, so the same runs
count. Only check runs made by GitHub Actions count, and the tag must name the commit the workflow started on. An `operator-upgrade` that skips itself with a notice (no starting point can be found) ends as a success and counts. The `release` job has `contents: read` and `checks: read`; the script reads the public endpoint anonymously if the token is refused.

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
      again (`-rc.N+1`); never move a tag. A **final** whose own build or scan fails is not repaired by `-rc.N+1` (the final's tag stays where it
      is, and there may be no draft to publish with `gh release edit --draft=false`): publish that release with `gh release create vX.Y.Z --verify-tag`
      (facilities then build the images from the recipe, as for any release without a list), or cut the next patch release. Re-running the job on a draft release builds again and replaces `release-images.json` (the
      digests change; a facility that already pulled keeps what it has); on a published release the upload is refused.
- [ ] **A new image package** (a service that gets its own image for the first time, so `ghcr.io` has no package for it yet): its first push
      creates the package private and without this repository's write access. Give it the access and the visibility of the next item, then
      re-run `publish-images` once for the tag: one re-run for each new package.
- [ ] **Once, with the first release candidate (nothing in this job has run against `ghcr.io` before it):** if the push is refused
      (`denied: permission_denied`), open each package's settings, "Manage Actions access", and add this repository with the Write role,
      then re-run the job. GitHub creates each package private. For every package of the repository
      (`github.com/abhiguru?tab=packages`: `db`, `functions`, `gateway`, `pdf-renderer`, `storage` and the optional `cups`, `sensor-bridge` and
      `supavisor`) open Package settings, link it to this repository if it is not, and set its visibility to **Public**; then re-run the job. The
      step "Check that the images pull without credentials" fails until every package is public, so a private package is never
      discovered by a facility silently building instead.
- [ ] **Signatures.** The step "Sign every published image (keyless) and check the signatures" is green: every image of the list is signed by the
      workflow run and passes `scripts/verify-image-signature.sh` (and a wrong identity is refused). Check one by hand with the `cosign verify` command of
      [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#image-signatures). If the step fails, nothing is attached: fix the cause (the job needs
      `id-token: write`; Sigstore's services must answer), re-run the job on a draft release, or cut the next candidate. Never publish a release whose
      images do not verify: a facility that cannot verify them refuses the upgrade (or builds locally).
- [ ] In the release (a draft, or published) check the asset `release-images.json`: `release` is the tag, `commit` is
      `git rev-parse vX.Y.Z^{commit}`, there is one image for every recipe (`jq -r '.images | keys[]' release-images.json`: the services of
      `docker/docker-compose.yml` that have `build:`), and each `ref` is `ghcr.io/abhiguru/supabase-warehouse-template/<service>@sha256:<64 hex>`.
- [ ] A release candidate's draft is **published as a pre-release before the rehearsal** (`gh release edit vX.Y.Z-rc.N --draft=false
      --prerelease`), or the rehearsal's `setup.sh` finds no file and builds, which proves nothing about the pull. The rehearsal output must
      say `Taken from the release: N (M already on this host) (...)`. The final's job needs the candidate's list, so keep the candidate's release (draft or
      published) until the final has been tagged.

## Upgrade rehearsal from the previous tag

The `operator-upgrade` CI job runs `upgrade.sh --ref` from the previous tag (or the merge base) to the change, but it cannot run
the new tag itself (a commit is not a release tag). So the rehearsal runs on a release candidate, and the final tag goes on the same
commit afterwards: a failed rehearsal never leaves a published `vX.Y.Z` that has to be moved.

- [ ] The `operator-upgrade` job's rollback drill passed for this commit (it makes an upgrade fail inside setup and runs the way back that
      `node scripts/upgrade-record.mjs rollback` prints; a notice that it was skipped is not a pass).
- [ ] Tag the release commit `vX.Y.Z-rc.N` (`git tag -s vX.Y.Z-rc.N <commit> -m "..."`, push it) and wait for `release.yml` to pass. The
      `CHANGELOG.md` section is `## vX.Y.Z (date)`; `upgrade.sh` prints it for the candidate too.
- [ ] On a **throwaway** installation of the previous release (its own state and project name; never a facility's), with some data
      in it, run `bash upgrade.sh --dry-run vX.Y.Z-rc.N` and then `bash upgrade.sh vX.Y.Z-rc.N`. Both must end well; the last line of
      `$WAREHOUSE_STATE_DIR/config/upgrades.log` must end in `ok`, `config/upgrade-in-progress` must be gone, and
      `node scripts/doctor.mjs` must pass.
- [ ] On the same throwaway installation, `node scripts/upgrade-record.mjs rollback --last` prints the way back from the finished upgrade:
      read it (it starts with `bash scripts/maintenance.sh on`, names the loss, and ends with `rm -f` of `config/upgrade-last`).
- [ ] At a release candidate tag the preflight prints `Pre-pull of images: done (N image(s) of vX.Y.Z-rc.N, ...)` before the pause, and setup
      pulls nothing again.
- [ ] Read what `upgrade.sh` printed under "What vX.Y.Z-rc.N asks of the operator": it must be the operator actions of this release and
      no other release's.
- [ ] If the previous release is on another PostgreSQL major, `upgrade.sh` must refuse and name the "Major PostgreSQL upgrade"
      section; rehearse that procedure instead.
- [ ] Once, for the first release that has the upgrade record: stop a rehearsal in the middle (`kill -9` of `upgrade.sh` while `setup.sh`
      runs), check that `node scripts/doctor.mjs --local` reports the interrupted upgrade, and finish it with the same command.
- [ ] Rehearsal passed: tag the same commit `vX.Y.Z` (`git tag -s vX.Y.Z vX.Y.Z-rc.N^{commit} -m "..."`), push it, wait for `release.yml`.
      Failed: fix on `main` and start again with `-rc.N+1`; do not move a tag.
- [ ] Record in the release pull request or the release note: the previous tag, the candidate, the tag, the date and the result.

## Windows (WSL2) acceptance, per release

A manual check on a Windows 10 22H2 host, following the WSL2 section of
[OPERATOR_INSTALL.md](OPERATOR_INSTALL.md#windows-host-ubuntu-in-wsl2) from the top. There is no CI runner for Windows. For each box,
record the result and the evidence named (command output or a timed log) in the release pull request.

- [ ] Fresh install from the guide on a host with no earlier installation; record the guide's commit and the WSL version
      (`wsl --version`).
- [ ] `node scripts/doctor.mjs --local` passes; record its last line.
- [ ] `bash scripts/tunnel.sh create` and the public check: `get-public-config` answers 200 on the public address; record the
      status code and the time.
- [ ] Both tasks registered with `scripts/windows/register-tasks.ps1` (with `-BusId` for the USB task); record the script's read-back output.
- [ ] The keep-alive task read back (`Get-ScheduledTask 'Warehouse WSL' | Get-ScheduledTaskInfo` and its settings): Running, both
      triggers, `IgnoreNew`, battery switches off.
- [ ] Recovery after a reboot with nobody signed in (Windows auto logon off; check with `quser` or the Security log for no interactive logon), and after `wsl --shutdown`; record seconds until the first 200 for each.
- [ ] The planned-work order of the guide end to end, including `Disable-ScheduledTask`, `Enable-ScheduledTask` and both doctor
      modes at the end; record any step that did not behave as written.
- [ ] USB: the "Warehouse USB" task registered, `usbipd list` shows the stick "Attached", enrol, and one automatic run; record the
      run's journal summary and that the copy was verified.
- [ ] The stick is "Attached" again in `usbipd list` after a reboot with nobody signed in (Windows auto logon off; check with `quser` or the Security log for no interactive logon), and after `wsl --shutdown`, and a USB run
      after each restart succeeded (`backup-usb.sh status`); record the seconds it took.
- [ ] Known gaps noted in the release note, if still open: a restart with no console session signed in (Windows auto logon off)
      with the tasks registered by the script.

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
      next minor release from `main` (all of the checklist above applies). The exception is a fix that is a change to a file of
      `migrations/definitions/` only: cut `release/MAJOR.MINOR` from the current line's latest tag, apply that change (the pull request
      runs the same CI guard as for the previous line: no numbered migration, no added, removed or renamed definition file), write the
      `CHANGELOG.md` section on the branch and also on `main`, and tag a patch there. Only a minor release that contains
      `migrations/definitions/` can take such a fix.
- [ ] **Previous line, still supported** (6 months after the current minor's first release), and the fix is **code only**: no file under
      `migrations/` is part of it. Cherry-pick it onto `release/MAJOR.MINOR` of that line (create the branch from its last tag if it
      does not exist; the pull request runs CI, which refuses a change to `migrations/`), write the `CHANGELOG.md` section of the patch
      release on the branch **and add the same section to `main`'s `CHANGELOG.md`**, tag the patch on the branch, and run the checks
      above for that tag too.
- [ ] **The fix needs SQL: no backport.** The previous line's release note (a new patch release of it, if it needs one for the
      notice) tells its operators to upgrade to the next minor release. Never put a migration on a `release/*` branch.
- [ ] Two releases (one when there is no backport), each titled "... Security: ..." and naming the other.
- [ ] Owner action, once: a ruleset for `release/*` like `main`'s (docs/PRODUCTION_DEPENDENCIES.md).
