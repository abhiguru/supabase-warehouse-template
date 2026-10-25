import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';

test('workflow actions are referenced by commit, with the release in a comment', () => {
  const directory = new URL('../.github/workflows/', import.meta.url);
  let count = 0;
  for (const file of readdirSync(directory)) {
    for (const line of readFileSync(new URL(file, directory), 'utf8').split('\n')) {
      if (!/^\s*(?:- )?uses:/.test(line)) continue;
      // A tag such as @v7 can be moved to other code; a commit cannot. Dependabot
      // (github-actions) updates the hash and the comment together.
      assert.match(line, /uses: [a-z0-9-]+\/[a-z0-9-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$/, `${file}: ${line.trim()}`);
      count += 1;
    }
  }
  assert.ok(count >= 13, 'workflow steps were read');
  assert.match(readFileSync(new URL('../.github/dependabot.yml', import.meta.url), 'utf8'), /package-ecosystem: github-actions/);
});

test('the mobile companion is pinned once, by full commit, and the contract job uses that pin', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  // One declaration: a second one (or a job-level override) would hide which commit was checked.
  const pins = ci.split('\n').filter(line => /^\s*MOBILE_REF\s*:/.test(line));
  assert.equal(pins.length, 1, 'MOBILE_REF is declared exactly once');
  // A branch, a tag or a short hash can come to mean other code; 40 hex digits cannot.
  assert.match(pins[0], /^  MOBILE_REF: [0-9a-f]{40}$/, `MOBILE_REF must be a full commit SHA: ${pins[0].trim()}`);
  // Every checkout of the app takes its ref from the pin, never from a name written in the step.
  const checkouts = ci.split(/\n\s*- uses: actions\/checkout@/).slice(1).map(step => step.split(/\n\s*- /)[0]);
  const mobile = checkouts.filter(step => /repository: abhiguru\/rn-warehouse-template/.test(step));
  assert.ok(mobile.length >= 1, 'the contract job checks out the app');
  for (const step of mobile) assert.match(step, /\n\s*ref: \$\{\{ env\.MOBILE_REF \}\}\n/, 'the app is checked out at MOBILE_REF');
  // The release step that moves the pin and runs the live comparison stays documented.
  const checklist = readFileSync(new URL('../docs/RELEASE_CHECKLIST.md', import.meta.url), 'utf8');
  assert.match(checklist, /## Mobile contract before a release/);
  assert.match(checklist, /check-mobile-contract\.mjs [^\n]*--live/);
});

test('no workflow names a self-hosted runner; CI jobs take their runner from a repository variable, never for a fork', () => {
  const directory = new URL('../.github/workflows/', import.meta.url);
  for (const file of readdirSync(directory)) {
    const runsOn = readFileSync(new URL(file, directory), 'utf8').split('\n').filter(line => /^\s*runs-on:/.test(line));
    assert.ok(runsOn.length >= 1, `${file} has jobs`);
    // A label written here would leave the job waiting for ever in every fork.
    for (const line of runsOn) assert.doesNotMatch(line, /self-hosted/, `${file}: ${line.trim()}`);
  }
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = ci.slice(ci.indexOf('\n  operator-install:\n') + 1).split(/\n  [a-z-]+:\n/)[0];
  assert.match(job, /\n    runs-on: \$\{\{ github\.event\.pull_request\.head\.repo\.fork && 'ubuntu-latest' \|\| fromJSON\(vars\.OPERATOR_INSTALL_RUNNER \|\| '"ubuntu-latest"'\) \}\}\n/);
  // Every CI job: the runner comes from a variable, and a fork's pull request always gets a hosted runner.
  const ciRunsOn = ci.split('\n').filter(line => /^ {4}runs-on:/.test(line));
  assert.ok(ciRunsOn.length >= 8, 'the CI jobs were read');
  for (const line of ciRunsOn) {
    assert.match(line, /^ {4}runs-on: \$\{\{ github\.event\.pull_request\.head\.repo\.fork && 'ubuntu-latest' \|\| fromJSON\(vars\.(?:CI_RUNNER|OPERATOR_INSTALL_RUNNER) \|\| '"ubuntu-latest"'\) \}\}$/, line.trim());
  }
});

test('every Dependabot ignore entry names the update types it ignores', () => {
  // An entry with a name alone would also stop Dependabot's security pull
  // requests for that dependency; one with update-types stops version updates only.
  const lines = readFileSync(new URL('../.github/dependabot.yml', import.meta.url), 'utf8').split('\n');
  let entries = 0;
  lines.forEach((line, index) => {
    const match = /^(\s*)- dependency-name:/.exec(line);
    if (!match) return;
    const indent = match[1].length;
    const body = [];
    for (const next of lines.slice(index + 1)) {
      if (next.trim() && next.match(/^\s*/)[0].length <= indent) break;
      body.push(next);
    }
    assert.match(body.join('\n'), /^\s+update-types:\n(?:\s+- "version-update:semver-(?:major|minor|patch)"\n?)+/, `dependabot.yml:${index + 1} ${line.trim()}`);
    entries += 1;
  });
  assert.equal(entries, 8, 'every ignore entry was read');
});

// A plain (unquoted) YAML scalar ends at ": " or " #", so `run: pip install --only-binary=:all: -r ...`
// made GitHub reject the whole workflow file (2026-10-18). Such a command must be quoted or a block scalar.
test('a one-line run command with ": " or " #" in it is quoted', () => {
  const directory = new URL('../.github/workflows/', import.meta.url);
  for (const file of readdirSync(directory)) {
    for (const [index, line] of readFileSync(new URL(file, directory), 'utf8').split('\n').entries()) {
      const match = /^\s*(?:- )?run:\s+(.*)$/.exec(line);
      if (!match || /^['"|>]/.test(match[1])) continue;
      assert.doesNotMatch(match[1], /: | #/, `${file}:${index + 1} needs quotes: ${match[1]}`);
    }
  }
});

test('the renderer job runs only for a change that can move it, builds the image once, and is not a required check', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = name => ci.slice(ci.indexOf(`\n  ${name}:\n`) + 1).split(/\n  [a-z-]+:\n/)[0];
  // The filter names every path that can change the renderer's output; the whole _shared folder holds the HTML templates.
  for (const path of ['docker/pdf-renderer/', 'tests/golden-pdf/', 'functions/_shared/']) assert.ok(job('changes').includes(path), path);
  assert.match(job('changes'), /\.github\/workflows\/ci\\\.yml/);
  const renderer = job('pdf-renderer');
  assert.match(renderer, /\n    needs: \[validate, changes\]\n    if: github\.event_name == 'schedule' \|\| github\.event_name == 'workflow_dispatch' \|\| needs\.changes\.outputs\.renderer == 'true'\n/);
  // Image drift (live Debian mirrors) is found weekly, not only by the next renderer change; the other jobs are unconditional.
  assert.match(ci.slice(0, ci.indexOf('\npermissions:')), /\n  schedule:\n    - cron: '[0-9*/, -]+ \* \* [0-7]'\n  workflow_dispatch:$/);
  assert.doesNotMatch(job('validate') + job('migrations') + job('contract'), /\n    if:/);
  assert.equal((renderer.match(/docker build /g) || []).length, 1, 'the image is built once');
  assert.match(renderer, /IMAGE=pdf-renderer:ci bash docker\/pdf-renderer\/test\/integration\.sh/);
  assert.doesNotMatch(ci, /\n  pdf-golden:/, 'the golden job is part of pdf-renderer');
});

test('operator-upgrade installs the previous release, moves it to the commit with upgrade.sh --ref, and checks the result', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = ci.slice(ci.indexOf('\n  operator-upgrade:\n') + 1).split(/\n  [a-z-]+:\n/)[0];
  assert.ok(job.length > 100, 'the job exists');
  assert.match(job, /\n    runs-on: \$\{\{ github\.event\.pull_request\.head\.repo\.fork && 'ubuntu-latest' \|\| fromJSON\(vars\.OPERATOR_INSTALL_RUNNER \|\| '"ubuntu-latest"'\) \}\}\n/, 'same runner rule as operator-install');
  assert.match(job, /\n    needs: validate\n/);
  assert.doesNotMatch(job, /runs after the install drills/, 'it runs beside them, not after');
  // Tags are needed to find the previous release.
  assert.match(job, /\n          fetch-depth: 0\n/);
  // The base branch is the pull request's, else the branch that was pushed (main or a release branch).
  assert.match(job, /BASE_BRANCH: \$\{\{ github\.base_ref \|\| github\.ref_name \}\}/);
  assert.match(job, /run: bash scripts\/ci-previous-tag\.sh "\$BASE_BRANCH" \| tee -a "\$GITHUB_OUTPUT"/);
  // When not even the merge base can start the drill the job says so and does not fail; when it starts from the merge base it says that.
  assert.match(job, /if: steps\.previous\.outputs\.skip == 'true'[^]*::notice title=Upgrade drill skipped::/);
  assert.match(job, /if: steps\.previous\.outputs\.kind == 'merge-base'[^]*::notice title=Upgrade drill starts from the merge base::/);
  for (const step of ['Install the previous release', 'Upgrade to this commit with upgrade.sh', 'The upgraded installation is healthy and the same facility']) {
    assert.match(job, new RegExp(`- name: ${step}\\n        if: steps\\.previous\\.outputs\\.skip != 'true'\\n`), step);
  }
  // The previous release is installed with its own setup.sh. A tag that has upgrade.sh and pg-major.sh runs its own, unchanged (the
  // script operators of that release run); a merge base, or a tag from before them, gets this change's copies.
  assert.match(job, /git -C backend worktree prune\n\s+git -C backend worktree add --detach "\$previous" "\$PREVIOUS_REF"/, 'a persistent runner may keep the registration of an earlier worktree');
  assert.match(job, /if \[ "\$PREVIOUS_KIND" = tag \] && git -C "\$previous" cat-file -e HEAD:upgrade\.sh[^\n]*HEAD:scripts\/pg-major\.sh[^\n]*; then\n\s+echo "The drill runs the upgrade\.sh of \$PREVIOUS_REF, unchanged\."\n\s+else/);
  assert.match(job, /cp backend\/upgrade\.sh "\$previous\/upgrade\.sh"/);
  assert.match(job, /bash setup\.sh --operator --state-dir "\$state"/);
  assert.match(job, /bash upgrade\.sh --dry-run --ref "\$ref"[^]*bash upgrade\.sh --ref "\$ref"/);
  assert.match(job, /test "\$\(git rev-parse HEAD\)" = "\$ref"/);
  assert.match(job, /grep -q ' ok\$'/, 'the upgrades.log line says ok');
  assert.match(job, /test ! -e "\$WAREHOUSE_STATE_DIR\/config\/upgrade-in-progress"/, 'a finished upgrade leaves no record');
  // Healthy after, still the same facility, and no table lost rows.
  assert.match(job, /node scripts\/doctor\.mjs --local/);
  assert.match(job, /instanceId/);
  assert.match(job, /bash scripts\/data-fingerprint\.sh --counts > "\$RUNNER_TEMP\/counts-before"[^]*bash scripts\/data-fingerprint\.sh --counts > "\$RUNNER_TEMP\/counts-after"[^]*rows lost in/);
  assert.match(job, /npm run test:db-roles/);
  assert.match(job, /node tests\/operator-api-core\.mjs/);
  assert.match(job, /if: always\(\) && steps\.previous\.outputs\.skip != 'true'/);
  // Hosted runners need no variable; nothing in the job names a machine.
  assert.doesNotMatch(job, /self-hosted/);
  // The script that picks the starting point is in the repository and skips rather than fails.
  const picker = readFileSync(new URL('../scripts/ci-previous-tag.sh', import.meta.url), 'utf8');
  assert.match(picker, /skip=true/);
  assert.match(picker, /kind=merge-base/);
});

test('the checks also run for the release branches, and a pull request into one may not change migrations', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  assert.match(ci, /\n  push:\n    branches: \[main, 'release\/\*\*'\]\n  pull_request:\n    branches: \[main, 'release\/\*\*'\]\n/);
  const validate = ci.slice(ci.indexOf('\n  validate:\n') + 1).split(/\n  [a-z-]+:\n/)[0];
  assert.match(validate, /- name: A change to a release branch carries no migration\n        [^\n]*\n[^]*if: github\.event_name == 'pull_request' && startsWith\(github\.base_ref, 'release\/'\)/);
  assert.match(validate, /git diff --name-only "\$BASE_SHA" HEAD -- migrations\//);
  assert.match(validate, /exit 1\n          fi\n      - uses: actions\/setup-node/);
  const contributing = readFileSync(new URL('../CONTRIBUTING.md', import.meta.url), 'utf8');
  assert.match(contributing, /Backports never carry a migration/);
});

test('keep-alive: a monthly timestamp commit on its own branch and a call that enables the scheduled workflows, with write access in this workflow only', () => {
  const directory = new URL('../.github/workflows/', import.meta.url);
  const keepAlive = readFileSync(new URL('keep-alive.yml', directory), 'utf8');
  // Monthly (day of month 1), and by hand.
  assert.match(keepAlive, /\n  schedule:\n    - cron: '\d+ \d+ 1 \* \*'\n  workflow_dispatch:\n/);
  assert.match(keepAlive, /\npermissions:\n  contents: write\n  actions: write\n/);
  // Least privilege: no other workflow may write contents or actions, and none may ask for everything.
  for (const file of readdirSync(directory)) {
    if (file === 'keep-alive.yml') continue;
    const text = readFileSync(new URL(file, directory), 'utf8');
    assert.doesNotMatch(text, /contents:\s*write/, `${file} does not need write access`);
    assert.doesNotMatch(text, /actions:\s*write/, `${file} may not enable or disable workflows`);
    assert.doesNotMatch(text, /write-all/, `${file} may not ask for every permission`);
  }
  assert.doesNotMatch(keepAlive, /secrets\./);
  assert.deepEqual([...keepAlive.matchAll(/uses: ([a-z0-9-]+\/[a-z0-9-]+)@/g)].map(match => match[1]), ['actions/checkout']);
  // main is protected, so the commit goes to the keep-alive branch (an orphan with the one file), never to main.
  assert.match(keepAlive, /git push origin keep-alive\b/);
  assert.doesNotMatch(keepAlive, /git push[^\n]*\bmain\b|origin main\b|HEAD:main/);
  assert.match(keepAlive, /git checkout -q --orphan keep-alive/);
  assert.match(keepAlive, /\.github\/KEEPALIVE/);
  // A refused push fails the run and tells the owner what to do.
  assert.match(keepAlive, /::error title=Keep-alive push refused::[^\n]*Owner action:[^\n]*bypass actor[^\n]*\n\s+exit 1\n/);
  // The documented enable endpoint is called for every scheduled workflow other than this one, also when the push failed.
  assert.match(keepAlive, /- name: Enable the scheduled workflows\n        [^\n]*\n        if: \$\{\{ !cancelled\(\) \}\}/);
  assert.match(keepAlive, /for workflow in ci\.yml cft-freshness\.yml; do/);
  assert.match(keepAlive, /-X PUT[^]*actions\/workflows\/\$workflow\/enable/);
  const scheduled = readdirSync(directory).filter(file => /\n  schedule:\n/.test(readFileSync(new URL(file, directory), 'utf8')) && file !== 'keep-alive.yml');
  assert.deepEqual(scheduled.sort(), ['cft-freshness.yml', 'ci.yml'], 'every other scheduled workflow is enabled by the call');
  // The owner action and the open question are on the dependencies page.
  const dependencies = readFileSync(new URL('../docs/PRODUCTION_DEPENDENCIES.md', import.meta.url), 'utf8');
  assert.match(dependencies, /keep-alive/);
  assert.match(dependencies, /Owner action[^\n]*keep-alive/);
  assert.match(dependencies, /unverified/i);
  assert.match(dependencies, /Actions tab/);
});
