import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

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
  assert.equal(entries, 7, 'every ignore entry was read'); // 8 until the jose ignore was removed (jose 6)
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
    // The one exception: the release workflow's publish-images job attaches release-images.json to the GitHub Release, so that job (and
    // only it, tested below) may write contents. Everything else of every workflow, that job's text included for the other two rules, is held to the rules.
    const rest = file === 'release.yml' ? text.replace(/\n  publish-images:\n[^]*?(?=\n  [a-z-]+:\n|$)/, '\n') : text;
    assert.doesNotMatch(rest, /contents:\s*write/, `${file} does not need write access`);
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
  assert.match(keepAlive, /for workflow in ci\.yml cft-freshness\.yml dependency-audit\.yml base-images\.yml; do/);
  assert.match(keepAlive, /-X PUT[^]*actions\/workflows\/\$workflow\/enable/);
  const scheduled = readdirSync(directory).filter(file => /\n  schedule:\n/.test(readFileSync(new URL(file, directory), 'utf8')) && file !== 'keep-alive.yml');
  assert.deepEqual(scheduled.sort(), ['base-images.yml', 'cft-freshness.yml', 'ci.yml', 'dependency-audit.yml'], 'every other scheduled workflow is enabled by the call');
  // The owner action and the open question are on the dependencies page.
  const dependencies = readFileSync(new URL('../docs/PRODUCTION_DEPENDENCIES.md', import.meta.url), 'utf8');
  assert.match(dependencies, /keep-alive/);
  assert.match(dependencies, /Owner action[^\n]*keep-alive/);
  assert.match(dependencies, /unverified/i);
  assert.match(dependencies, /Actions tab/);
});

test('validate (the required check) runs the tests and compares dependency advisories with the base, but never a live audit; the live audits are weekly workflows that open one issue each', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const validate = ci.slice(ci.indexOf('\n  validate:\n') + 1).split(/\n  [a-z-]+:\n/)[0];
  const steps = [...validate.matchAll(/^      - (?:name: ([^\n]+)|uses: ([^\n@]+)|run: ([^\n]+))/gm)].map(match => match[1] ?? match[2] ?? match[3]);
  assert.deepEqual(steps, ['actions/checkout', 'A change to a release branch carries no migration', 'actions/setup-node', 'npm ci', 'npm test',
    'Dependency advisories this change adds (docker/storage, docker/pdf-renderer)']);
  assert.doesNotMatch(validate.split('\n').filter(line => !line.trim().startsWith('#')).join('\n'), /npm audit|check:container-dependencies/);
  // The weekly signals: scheduled, each with the one permission it needs to open its issue, none writing contents.
  const directory = new URL('../.github/workflows/', import.meta.url);
  for (const file of ['cft-freshness.yml', 'dependency-audit.yml', 'base-images.yml']) {
    const text = readFileSync(new URL(file, directory), 'utf8');
    assert.match(text, /\n  schedule:\n    - cron: '[0-9]+ [0-9]+ \* \* [0-7]'\n/, `${file} runs weekly`);
    assert.match(text, /\npermissions:\n  contents: read\n  issues: write\n/, file);
    assert.match(text, /gh issue (?:create|edit)/, `${file} opens an issue`);
  }
  const dependencies = readFileSync(new URL('../docs/PRODUCTION_DEPENDENCIES.md', import.meta.url), 'utf8');
  for (const title of ['Chrome for Testing pin is more than 14 days behind Stable', 'Dependency advisories, <date>', 'Base image pins need attention']) {
    assert.ok(dependencies.includes(`"${title}"`), `PRODUCTION_DEPENDENCIES.md names the weekly issue ${title}`);
  }
  // The titles the workflows open are the ones the page names.
  assert.match(readFileSync(new URL('cft-freshness.yml', directory), 'utf8'), /title='Chrome for Testing pin is more than 14 days behind Stable'/);
  assert.match(readFileSync(new URL('dependency-audit.yml', directory), 'utf8'), /title="Dependency advisories, \$\(date -u \+%F\)"/);
  assert.match(readFileSync(new URL('base-images.yml', directory), 'utf8'), /title='Base image pins need attention'/);
});

// ---- the weekly issue steps, run for real with a stand-in `gh` --------------------------------------------------------------------
//
// The three weekly workflows keep ONE issue each. The step that opens, edits, comments on or closes it is shell inside the YAML, so
// it is cut out of the file and run with `bash -e` (what GitHub runs for a `run:` step) against a `gh` that records its arguments.

// The script of a `run: |` step, found by its name, with the indentation of the YAML taken off.
function stepScript(file, name) {
  const lines = readFileSync(new URL(`../.github/workflows/${file}`, import.meta.url), 'utf8').split('\n');
  const start = lines.findIndex(line => line.startsWith(`      - name: ${name}`));
  assert.ok(start >= 0, `${file}: no step named "${name}"`);
  const next = lines.findIndex((line, index) => index > start && line.startsWith('      - '));
  const run = lines.findIndex((line, index) => index > start && line === '        run: |');
  assert.ok(run > start && (next < 0 || run < next), `${file}: the step "${name}" has no run: | block`);
  const script = [];
  for (const line of lines.slice(run + 1)) {
    if (line.trim() && !line.startsWith('          ')) break;
    script.push(line.slice(10));
  }
  return script.join('\n');
}

// `issue`: { number, body } of the open issue the search finds, or none. `files`: what the step before left in RUNNER_TEMP.
function issueStep({ file, name, status, files = {}, issue }) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-issue-step-'));
  try {
    mkdirSync(join(dir, 'bin'));
    mkdirSync(join(dir, 'tmp'));
    for (const [fileName, text] of Object.entries(files)) writeFileSync(join(dir, 'tmp', fileName), text);
    const log = join(dir, 'gh.jsonl');
    // `gh issue list` answers the number, `gh issue view` the body; every other call is recorded with the text of its body file.
    writeFileSync(join(dir, 'bin/gh'), `#!${process.execPath}
const fs = require('fs');
const args = process.argv.slice(2);
const flag = key => args[args.indexOf(key) + 1];
const bodyFile = args.includes('--body-file') ? fs.readFileSync(flag('--body-file'), 'utf8') : args.includes('--body') ? flag('--body') : undefined;
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ args, text: bodyFile }) + '\\n');
if (args[0] === 'issue' && args[1] === 'list') process.stdout.write(${JSON.stringify(issue ? String(issue.number) : '')} + '\\n');
if (args[0] === 'issue' && args[1] === 'view') process.stdout.write(${JSON.stringify(issue?.body ?? '')});
`, { mode: 0o700 });
    writeFileSync(join(dir, 'step.sh'), stepScript(file, name));
    const run = spawnSync('bash', ['-e', join(dir, 'step.sh')], {
      encoding: 'utf8',
      env: {
        PATH: `${join(dir, 'bin')}:${process.env.PATH}`, RUNNER_TEMP: join(dir, 'tmp'), GH_TOKEN: 'unused', STATUS: String(status),
        GITHUB_REPOSITORY: 'example/warehouse', GITHUB_SERVER_URL: 'https://github.example.test', GITHUB_RUN_ID: '4242',
      },
    });
    let lines = [];
    try { lines = readFileSync(log, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line)); } catch { /* gh was not called */ }
    const calls = lines.filter(call => !(call.args[0] === 'issue' && ['list', 'view'].includes(call.args[1]))).map(call => ({ verb: call.args[1], args: call.args, text: call.text }));
    return { code: run.status, stdout: run.stdout, stderr: run.stderr, lists: lines.filter(call => call.args[1] === 'list').map(call => call.args), calls, verbs: calls.map(call => call.verb) };
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

const BASE_STEP = { file: 'base-images.yml', name: 'Open or update the issue, or close it when nothing needs attention' };
const WARN_NGINX = days => `WARN nginx:1.30.6-alpine-slim (docker/nginx/Dockerfile): last pushed ${days} days ago (limit 120). The variant is listed but is not being rebuilt.`;
const FAIL_NODE = 'FAIL node:24.22.1-alpine3.23 (docker/storage/Dockerfile): a tag of the 24 line with the variant alpine3.23 is no longer in the official-images library (library/node), so this pin gets no more updates.';
const issueBody = (...findings) => `The weekly base image check found:\n\n${findings.map(line => `- ${line}`).join('\n')}\n\nFAIL: the pinned variant is no longer published; move the pin.\n\nRun: https://github.example.test/example/warehouse/actions/runs/1\n`;

test('base-images issue step: an open issue gets ONE comment with only the new FAIL/WARN lines, and a silent edit when nothing is new', () => {
  // Nothing new: the same WARN, which is a week older (the age in the line is not news).
  const quiet = issueStep({ ...BASE_STEP, status: 0, files: { 'findings.txt': `${WARN_NGINX(130)}\n` }, issue: { number: 7, body: issueBody(WARN_NGINX(123)) } });
  assert.equal(quiet.code, 0, quiet.stderr);
  assert.deepEqual(quiet.verbs, ['edit'], 'a week with nothing new edits the body and sends nothing');
  assert.match(quiet.calls[0].text, /last pushed 130 days ago/);
  // A FAIL joins the WARN the issue already lists: one comment with the FAIL line only, sent before the edit.
  const news = issueStep({ ...BASE_STEP, status: 1, files: { 'findings.txt': `${WARN_NGINX(130)}\n${FAIL_NODE}\n` }, issue: { number: 7, body: issueBody(WARN_NGINX(123)) } });
  assert.equal(news.code, 0, news.stderr);
  assert.deepEqual(news.verbs, ['comment', 'edit'], 'the comment is made first: a failed comment leaves the body stale, so the next run sees the news again');
  assert.equal(news.calls[0].args[2], '7');
  assert.match(news.calls[0].text, /^New since the last run:\n\n- FAIL node:24\.22\.1-alpine3\.23 \(docker\/storage\/Dockerfile\): /);
  assert.doesNotMatch(news.calls[0].text, /nginx/, 'only the new line is listed');
  assert.match(news.calls[1].text, /- WARN nginx[^]*- FAIL node/, 'the edit holds every finding');
  // A WARN that turns into a FAIL for the same pin is news too.
  const worse = issueStep({ ...BASE_STEP, status: 1, files: { 'findings.txt': 'FAIL nginx:1.30.6-alpine-slim (docker/nginx/Dockerfile): a tag of the 1.30 line is gone.\n' }, issue: { number: 7, body: issueBody(WARN_NGINX(123)) } });
  assert.deepEqual(worse.verbs, ['comment', 'edit']);
  // Without an issue one is opened, with no comment.
  const first = issueStep({ ...BASE_STEP, status: 1, files: { 'findings.txt': `${FAIL_NODE}\n` } });
  assert.deepEqual(first.verbs, ['create']);
  assert.equal(first.calls[0].args[first.calls[0].args.indexOf('--title') + 1], 'Base image pins need attention');
});

test('base-images issue step: a clean run closes the issue; a crash (status 1 with no FAIL line, or a killed process) fails the step and leaves the issue alone', () => {
  const clean = issueStep({ ...BASE_STEP, status: 0, files: { 'findings.txt': '' }, issue: { number: 7, body: issueBody(WARN_NGINX(123)) } });
  assert.equal(clean.code, 0, clean.stderr);
  assert.deepEqual(clean.verbs, ['close']);
  assert.equal(issueStep({ ...BASE_STEP, status: 0, files: { 'findings.txt': '' } }).verbs.length, 0, 'clean and no issue: nothing to do');
  for (const [status, findings] of [[1, ''], [137, ''], [1, `${WARN_NGINX(130)}\n`], [127, `${FAIL_NODE}\n`]]) {
    const crashed = issueStep({ ...BASE_STEP, status, files: { 'findings.txt': findings }, issue: { number: 7, body: issueBody(WARN_NGINX(123)) } });
    assert.notEqual(crashed.code, 0, `status ${status} with findings ${JSON.stringify(findings)} fails the step`);
    assert.deepEqual(crashed.verbs, [], 'a crash does not close, edit or comment on the issue');
    assert.match(crashed.stdout, new RegExp(`^::error title=Base image check crashed::.*status ${status} `, 'm'));
  }
});

test('dependency-audit issue step: an open issue gets ONE comment with only the new finding lines, a silent edit when nothing is new, and a clean audit closes it', () => {
  const step = { file: 'dependency-audit.yml', name: 'Open or update the issue, or close it when the audit is clean' };
  const undici = '- docker/storage: undici GHSA-xjj6-f33q-929c (high, undici problem) https://github.com/advisories/GHSA-xjj6-f33q-929c';
  const lodash = '- docker/pdf-renderer: lodash GHSA-35jh-r3h4-6jhm (critical, lodash problem) https://github.com/advisories/GHSA-35jh-r3h4-6jhm';
  const report = (...lines) => `**Advisories with no exception** (HIGH or CRITICAL, production dependencies):\n\n${lines.join('\n')}\n\nWhat to do: raise the dependency.`;
  const body = (...lines) => `${report(...lines)}\n\nRun: https://github.example.test/example/warehouse/actions/runs/1\n`;
  const quiet = issueStep({ ...step, status: 1, files: { 'advisories.md': report(undici) }, issue: { number: 9, body: body(undici) } });
  assert.equal(quiet.code, 0, quiet.stderr);
  assert.deepEqual(quiet.verbs, ['edit'], 'nothing new: edited silently');
  assert.ok(quiet.calls[0].args.includes('--title'), 'the title carries the date');
  const news = issueStep({ ...step, status: 1, files: { 'advisories.md': report(undici, lodash) }, issue: { number: 9, body: body(undici) } });
  assert.equal(news.code, 0, news.stderr);
  assert.deepEqual(news.verbs, ['comment', 'edit']);
  assert.equal(news.calls[0].text.split('\n').filter(line => line.startsWith('- ')).join('\n'), lodash, 'only the new line is in the comment');
  assert.match(news.calls[0].text, /^New since the last run:/);
  assert.match(news.calls[1].text, /undici[^]*lodash/, 'the edit holds both');
  const fixed = issueStep({ ...step, status: 1, files: { 'advisories.md': report(undici) }, issue: { number: 9, body: body(undici, lodash) } });
  assert.deepEqual(fixed.verbs, ['edit'], 'a finding that went away is not news');
  // An issue body that was edited on the web comes back with Windows line ends: that must not make every line new.
  const crlf = issueStep({ ...step, status: 1, files: { 'advisories.md': report(undici, lodash) }, issue: { number: 9, body: body(undici, lodash).replace(/\n/g, '\r\n') } });
  assert.deepEqual(crlf.verbs, ['edit'], 'the same lines with CRLF are not new');
  assert.deepEqual(issueStep({ ...step, status: 1, files: { 'advisories.md': report(undici) } }).verbs, ['create']);
  assert.deepEqual(issueStep({ ...step, status: 0, issue: { number: 9, body: body(undici) } }).verbs, ['close']);
  const unread = issueStep({ ...step, status: 1, issue: { number: 9, body: body(undici) } });
  assert.notEqual(unread.code, 0, 'a missing report is a failed step, not an empty issue');
  assert.deepEqual(unread.verbs, []);
});

test('the three weekly workflows find their issue among the ones the bot itself opened, and never run twice at once', () => {
  const steps = {
    'cft-freshness.yml': 'Open or update the issue, or close it when the pin is current',
    'dependency-audit.yml': 'Open or update the issue, or close it when the audit is clean',
    'base-images.yml': 'Open or update the issue, or close it when nothing needs attention',
  };
  for (const [file, name] of Object.entries(steps)) {
    const text = readFileSync(new URL(`../.github/workflows/${file}`, import.meta.url), 'utf8');
    // Anyone may open an issue with the same title in a public repository; only the bot's own is edited or closed.
    assert.match(text, /\n\s+number=\$\(gh issue list --repo "\$GITHUB_REPOSITORY" --author app\/github-actions --state open /, `${file}: the issue is found by its author`);
    // A manual run beside the scheduled one must not open a second issue while the search index lags.
    assert.match(text, /\nconcurrency:\n  group: \$\{\{ github\.workflow \}\}\n  cancel-in-progress: false\n/, `${file}: one run at a time, none cancelled`);
    // The same, with the step run for real: the list call carries the author filter.
    const listed = issueStep({ file, name, status: 0, files: { 'findings.txt': '' }, issue: { number: 3, body: '' } });
    assert.equal(listed.lists.length, 1, file);
    assert.ok(listed.lists[0].includes('--author') && listed.lists[0].includes('app/github-actions'), `${file}: ${listed.lists[0].join(' ')}`);
  }
});

test('migration-order checks the base with the ordering script in its own job, and seeded-upgrade is scheduled only, with a plain and a clash variant', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = name => ci.slice(ci.indexOf(`\n  ${name}:\n`) + 1).split(/\n  [a-z-]+:\n/)[0];
  const order = job('migration-order');
  assert.ok(order.length > 100, 'the job exists');
  assert.match(order, /\n          fetch-depth: 0\n/, 'the base commit must be in the clone');
  assert.match(order, /BASE_SHA: \$\{\{ github\.event\.pull_request\.base\.sha \}\}/);
  assert.match(order, /PUSH_BEFORE: \$\{\{ github\.event\.before \}\}/);
  assert.match(order, /node scripts\/check-migration-order\.mjs "\$base"/);
  assert.doesNotMatch(job('validate'), /check-migration-order/, 'its own job: validate is edited by other changes');
  const seeded = job('seeded-upgrade');
  assert.ok(seeded.length > 100, 'the job exists');
  assert.match(seeded, /\n    if: github\.event_name == 'schedule' \|\| github\.event_name == 'workflow_dispatch'\n/, 'never on a push or a pull request');
  assert.match(seeded, /variant: \[plain, clash\]/);
  assert.match(seeded, /bash scripts\/ci-previous-tag\.sh "\$BASE_BRANCH"/);
  assert.match(seeded, /tests\/seed\/make-seed\.mjs/);
  assert.match(seeded, /--clash/);
  assert.match(seeded, /grep -q 'Rehearsal of the migrations: passed'/, 'the plain variant proves the rehearsal ran');
  assert.match(seeded, /00000000000117_customer_name_rule\.sql/, 'the clash variant proves the refusal names migration 117');
  assert.match(seeded, /grep -q 'customers_name_norm_key' "\$RUNNER_TEMP\/\$out\.out"/, 'and that the refusal came from the unique index over the clashing names');
  assert.match(seeded, /fingerprint-before/, 'and that the database is untouched');
});

test('release.yml publishes the release images in a job of their own: build, scan, then login, push and attach, with write permissions in that job only', () => {
  const release = readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');
  // The workflow stays read-only; the checks job inherits that and asks for nothing.
  assert.match(release, /\npermissions:\n  contents: read\n\njobs:\n/);
  const [checks, publish] = release.split(/\n  publish-images:\n/);
  assert.ok(publish, 'a publish-images job exists');
  assert.doesNotMatch(checks, /\n    permissions:|packages:\s*write|contents:\s*write/, 'the checks job writes nothing');
  assert.match(publish, /^    needs: release\n/, 'it runs only after the validation, tests and audit of the release job pass');
  assert.match(publish, /\n    if: github\.repository == 'abhiguru\/supabase-warehouse-template'\n/, 'a fork has no right to the registry namespace');
  assert.match(publish, /\n    permissions:\n      contents: write\n      packages: write\n    steps:\n/, 'exactly the two write permissions, on this job');
  assert.doesNotMatch(publish, /write-all|id-token|actions:\s*write|pull-requests:\s*write/);
  assert.doesNotMatch(release, /continue-on-error|\|\| true/, 'no step may be softened');
  assert.doesNotMatch(release, /secrets\./, 'the job needs no secret beyond the run\'s own token');

  // The steps, in order: state for the scan, the look for a pre-release of this commit, Trivy, scan (build + scan), login, push (or, for a
  // final tag on the commit of its pre-release, the re-tag), anonymous check, attach.
  const names = [...publish.matchAll(/\n      - (?:name: ([^\n]+)|uses: ([^\n@ ]+))/g)].map(match => match[1] ?? match[2]);
  assert.deepEqual(names, ['actions/checkout', 'actions/setup-node', 'Throwaway operator state for the build and the scan',
    'Reuse the images of the pre-release at this commit, if there is one', 'Install Trivy 0.76.0',
    'Build every image without the cache and scan it', 'Log in to ghcr.io', 'Push the images that were scanned and write release-images.json',
    'Re-tag the images of the pre-release and write release-images.json',
    'Check that the images pull without credentials', 'Attach release-images.json to the GitHub Release']);
  const step = name => `\n${publish.split(`\n      - name: ${name}\n`)[1].split(/\n      - /)[0]}`;
  // The scan is the repository's gate (npm run scan:images = scripts/scan-images.sh: a row no valid exception covers, an expired exception
  // or a failed scan exits 1, tests/image-scan.test.mjs), run as a plain step: its failure stops the job before any login or push.
  assert.match(step('Build every image without the cache and scan it'), /\n        run: npm run scan:images$/);
  assert.equal(JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).scripts['scan:images'], 'bash scripts/scan-images.sh');
  assert.ok(publish.indexOf('npm run scan:images') < publish.indexOf('docker login'), 'no build or scan step runs with a registry login');
  // The push call, not the earlier look for a pre-release (`--rehearsed`, which only reads), is what needs the login before it.
  assert.ok(publish.indexOf('docker login') < publish.indexOf('run: bash scripts/publish-images.sh "$GITHUB_REF_NAME"'));
  assert.ok(publish.indexOf('scripts/publish-images.sh') < publish.indexOf('docker manifest inspect'));
  assert.ok(publish.indexOf('docker manifest inspect') < publish.indexOf('gh release upload'));
  // The token reaches the login by environment and a pipe, never written into a command line.
  assert.match(step('Log in to ghcr.io'), /\n        env:\n          REGISTRY_TOKEN: \$\{\{ github\.token \}\}\n        run: printf '%s' "\$REGISTRY_TOKEN" \| docker login ghcr\.io -u "\$GITHUB_ACTOR" --password-stdin$/);
  for (const line of release.split('\n').filter(line => /\$\{\{ github\.token \}\}/.test(line))) assert.match(line, /^ {10}(REGISTRY_TOKEN|GH_TOKEN): /, `the token is only ever an environment value: ${line.trim()}`);
  assert.match(step('Push the images that were scanned and write release-images.json'), /\n        run: bash scripts\/publish-images\.sh "\$GITHUB_REF_NAME" "\$RUNNER_TEMP\/release-images\.json"$/);
  // A final tag on the commit of its newest pre-release builds and scans nothing and re-tags that pre-release's images; any other tag builds.
  // The build, the scan, Trivy and the push run only when no pre-release's images are reused; the re-tag only when they are.
  const reuse = step('Reuse the images of the pre-release at this commit, if there is one');
  assert.match(reuse, /\n        id: rehearsed\n/);
  assert.match(reuse, /git fetch --force --no-tags origin 'refs\/tags\/v\*:refs\/tags\/v\*'\n/, 'the tags of the pre-releases are fetched: a tag checkout has only its own');
  assert.match(reuse, /rc="\$\(bash scripts\/publish-images\.sh --rehearsed "\$GITHUB_REF_NAME" "\$RUNNER_TEMP\/rehearsed-images\.json"\)"\n\s+echo "rc=\$rc" >> "\$GITHUB_OUTPUT"/);
  for (const name of ['Install Trivy 0.76.0', 'Build every image without the cache and scan it', 'Push the images that were scanned and write release-images.json']) {
    assert.match(step(name), /\n        if: steps\.rehearsed\.outputs\.rc == ''\n/, `${name} runs only when no pre-release's images are reused`);
  }
  const retag = step('Re-tag the images of the pre-release and write release-images.json');
  assert.match(retag, /\n        if: steps\.rehearsed\.outputs\.rc != ''\n/);
  assert.match(retag, /\n        env:\n          REHEARSED: \$\{\{ steps\.rehearsed\.outputs\.rc \}\}\n/, 'the pre-release name reaches the script by environment, not written into the command');
  assert.match(retag, /\n        run: bash scripts\/publish-images\.sh --retag "\$GITHUB_REF_NAME" "\$REHEARSED" "\$RUNNER_TEMP\/rehearsed-images\.json" "\$RUNNER_TEMP\/release-images\.json"$/);
  assert.ok(publish.indexOf('docker login') < publish.indexOf('--retag'), 'the re-tag writes to the registry, so it logs in first');
  assert.doesNotMatch(reuse, /docker login|packages/, 'finding the pre-release needs no registry write');
  // The exposure of the job token is said where the job is defined: one job builds, scans and publishes.
  assert.match(release, /the job's token \(write access to the\n  # repository's contents and packages\) is held by the runner from the first step to the last, so the build, the scan, the Trivy\n  # binary and the repository's scripts all run in a job that holds it\. That is accepted:/);
  // The images must be readable without credentials, or no facility could pull them.
  const anonymous = step('Check that the images pull without credentials');
  assert.ok(anonymous.indexOf('docker logout ghcr.io') < anonymous.indexOf('docker manifest inspect "$ref"'));
  assert.match(anonymous, /jq -r '\.images\[\]\.ref' "\$RUNNER_TEMP\/release-images\.json"/);
  assert.match(anonymous, /exit 1; \}/, 'an unreadable image fails the run');
  // The list is attached to the release, replacing an earlier one of a rerun; a release that does not exist yet is made as a draft.
  const attach = step('Attach release-images.json to the GitHub Release');
  assert.match(attach, /gh release upload "\$GITHUB_REF_NAME" "\$RUNNER_TEMP\/release-images\.json" --repo "\$GITHUB_REPOSITORY" --clobber/);
  assert.match(attach, /gh release create "\$GITHUB_REF_NAME" [^\n]*--verify-tag --draft /);
  assert.match(attach, /GH_TOKEN: \$\{\{ github\.token \}\}/);
  // Trivy: the release archive of a pinned version (0.74.0 or later, as the checklist says), checked against a SHA-256 before it is unpacked.
  const trivy = step('Install Trivy 0.76.0');
  const version = /releases\/download\/v(\d+)\.(\d+)\.(\d+)\/trivy_\1\.\2\.\3_Linux-64bit\.tar\.gz/.exec(trivy);
  assert.ok(version && (Number(version[1]) > 0 || Number(version[2]) >= 74), 'a pinned Trivy of 0.74.0 or later');
  assert.match(trivy, /echo "[0-9a-f]{64}  \$RUNNER_TEMP\/trivy\.tar\.gz" \| sha256sum -c -\n[^]*tar -xzf/, 'the checksum is verified before the archive is unpacked');
  assert.match(readFileSync(new URL('../docs/RELEASE_CHECKLIST.md', import.meta.url), 'utf8'), /Trivy 0\.74\.0 or later/);
  // The state is the scan's: a throwaway one made by configure.mjs, exported for every later step.
  assert.match(step('Throwaway operator state for the build and the scan'), /node scripts\/configure\.mjs --state-dir "\$RUNNER_TEMP\/publish-images-state"[^]*echo "WAREHOUSE_STATE_DIR=\$RUNNER_TEMP\/publish-images-state" >> "\$GITHUB_ENV"/);
});

test('release.yml makes the draft of a pre-release a pre-release by the version alone: build metadata with a hyphen in it does not', () => {
  const release = readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');
  const attach = release.split('\n      - name: Attach release-images.json to the GitHub Release\n')[1];
  assert.ok(attach, 'the attach step exists');
  // The two lines of the step that decide it, run as they are.
  const lines = attach.split('\n').map(line => line.trim()).filter(line => line === 'prerelease=()' || line.startsWith('[[ ') && line.endsWith('|| prerelease=(--prerelease)'));
  assert.equal(lines.length, 2, 'the step declares prerelease and sets it in one test');
  for (const [ref, expected] of [['v1.2.3', ''], ['v1.2.3-rc.1', '--prerelease'], ['v1.2.3+build-5', ''], ['v1.2.3-rc.1+build-5', '--prerelease'], ['v1.2.3+build.5', ''], ['v1.2.3-beta', '--prerelease']]) {
    const run = spawnSync('bash', ['-c', `set -e\n${lines.join('\n')}\nprintf '%s' "\${prerelease[*]}"`], { encoding: 'utf8', env: { ...process.env, GITHUB_REF_NAME: ref } });
    assert.equal(run.status, 0, `${ref}: ${run.stderr}`);
    assert.equal(run.stdout, expected, `${ref} is ${expected ? 'a pre-release' : 'final'}`);
  }
});
