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

test('the operator-install job runs retention:apply against the real Storage API as its last use of the stack', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const job = ci.slice(ci.indexOf('\n  operator-install:'));
  const steps = job.split(/\n      - /).slice(1);
  const index = steps.findIndex(step => /npm run retention:apply/.test(step));
  assert.ok(index >= 0, 'a step runs retention:apply');
  const step = steps[index];
  // An object is made old enough first; without that the run deletes nothing and proves nothing.
  assert.match(step, /UPDATE storage\.objects SET created_at/);
  assert.match(step, /expired_generated_documents\(now\(\)\)"\)" = 1/);
  // Both halves of a Storage API delete are checked: the catalog row and the stored file.
  assert.ok(step.indexOf('npm run retention:apply') < step.indexOf("FROM storage.objects WHERE bucket_id = 'documents' AND name ="), 'the row is counted after the run');
  assert.match(step, /\/var\/lib\/storage\/stub\/stub\/documents\//);
  // It deletes a document, so no step that reads documents or compares fingerprints may follow it.
  const later = steps.slice(index + 1);
  assert.equal(later.length, 1, 'only the stop step follows');
  assert.match(later[0], /^name: Stop only this checkout's operator project\n\s+if: always\(\)/);
});
