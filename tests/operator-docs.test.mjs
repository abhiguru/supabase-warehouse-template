import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('the troubleshooting guide acts only on the selected installation and has no reset', () => {
  const guide = read('docs/TROUBLESHOOTING.md');
  // Fixed container names belong to some other Compose project on the host (a separate
  // Supabase deployment, another installation); scripts/compose.sh selects this one by
  // WAREHOUSE_STATE_DIR and refuses another checkout's project.
  assert.doesNotMatch(guide, /docker (logs|exec|restart|stop|start|rm) (-\S+ )*supabase-/, 'a docker command names a fixed supabase-* container');
  assert.doesNotMatch(guide, /\bdown -v\b/, 'a reset that deletes the volumes');
  assert.doesNotMatch(guide, /^#+ .*Reset Everything/m);
  assert.match(guide, /export WAREHOUSE_STATE_DIR=/);
  assert.match(guide, /bash scripts\/compose\.sh/);
  // `docker stats` with no IDs lists every container on the host: never pass it an unchecked `ps -q`.
  assert.doesNotMatch(guide, /docker stats[^\n]*\$\(bash scripts\/compose\.sh ps -q\)/, 'docker stats on an unchecked ps -q');
  assert.match(guide, /ids=\$\(bash scripts\/compose\.sh ps -q\); \[ -n "\$ids" \] && docker stats --no-stream \$ids/);
  for (const heading of ['In-place restore of the same instance', 'Recover a lost host from the USB drive', 'Rerun and upgrade']) {
    assert.ok(read('docs/OPERATOR_INSTALL.md').includes(`# ${heading}`), `OPERATOR_INSTALL.md has no "${heading}" heading`);
    assert.ok(guide.includes(heading), `the guide does not point at "${heading}"`);
  }
});

test('the API contract guide names commands that exist', () => {
  const guide = read('docs/API_CONTRACT.md');
  const scripts = JSON.parse(read('package.json')).scripts;
  // `npm run test:api` was removed with the historical API demos.
  assert.doesNotMatch(guide, /test:api/);
  assert.equal(scripts['test:api'], undefined);
  assert.equal(scripts['check:contract'], 'node scripts/check-mobile-contract.mjs');
  assert.match(guide, /npm run check:contract -- \.\.\/rn-warehouse-template/);
  for (const name of [...guide.matchAll(/npm run ([a-z:-]+)/g)].map(match => match[1])) {
    assert.ok(scripts[name], `docs/API_CONTRACT.md names npm run ${name}, which package.json does not have`);
  }
});

test('the container security record names commands that exist', () => {
  const guide = read('docs/CONTAINER_SECURITY.md');
  const scripts = JSON.parse(read('package.json')).scripts;
  // `npm run test:api` was removed with the historical API demos; the contract check is check:contract,
  // described in docs/API_CONTRACT.md and docs/RELEASE_CHECKLIST.md (the old acceptance narrative that named it here is gone).
  assert.doesNotMatch(guide, /test:api/);
  for (const name of [...guide.matchAll(/npm run ([a-z:-]+)/g)].map(match => match[1])) {
    assert.ok(scripts[name], `docs/CONTAINER_SECURITY.md names npm run ${name}, which package.json does not have`);
  }
});

test('migration 123 does not create the OTP cleanup trigger again', () => {
  assert.doesNotMatch(read('migrations/00000000000123_slim_round2.sql').replace(/^--.*$/gm, ''), /CREATE\s+TRIGGER\s+trigger_auto_cleanup_otps/i);
});

test('no heading occurs twice in the operator runbook, the container security record or the monitoring guide', () => {
  // A merge of a branch that carries commits main took as a squash can add a whole section a second time without a conflict.
  for (const file of ['docs/OPERATOR_INSTALL.md', 'docs/CONTAINER_SECURITY.md', 'docs/MONITORING.md']) {
    let fenced = false;
    const seen = new Map();
    for (const line of read(file).split('\n')) {
      if (/^```/.test(line)) { fenced = !fenced; continue; }
      if (fenced || !/^#{1,6} /.test(line)) continue;
      seen.set(line, (seen.get(line) ?? 0) + 1);
    }
    const repeated = [...seen].filter(([, count]) => count > 1).map(([heading]) => heading);
    assert.deepEqual(repeated, [], `${file} repeats a heading`);
  }
});
