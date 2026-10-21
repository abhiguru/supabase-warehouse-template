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
  assert.equal(entries, 7, 'every ignore entry was read');
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
