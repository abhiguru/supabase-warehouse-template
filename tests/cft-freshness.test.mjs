import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { compareVersions, evaluate, getJson, pinnedVersion, MAX_DAYS } from '../scripts/check-cft-freshness.mjs';

const day = 86_400_000;
const now = Date.UTC(2026, 9, 18);

test('versions compare numerically per part, not as text', () => {
  assert.equal(compareVersions('155.0.8059.84', '155.0.8059.84'), 0);
  assert.equal(compareVersions('155.0.8059.84', '155.0.8059.9'), 1);
  assert.equal(compareVersions('154.0.9999.1', '155.0.1.1'), -1);
});

test('the pin is read from the Dockerfile build arg', () => {
  assert.equal(pinnedVersion('FROM x\nARG CHS_VERSION=155.0.8059.84\nARG CHS_SHA256=ab\n'), '155.0.8059.84');
  assert.throws(() => pinnedVersion('ARG CHS_VERSION=stable\n'), /no "ARG CHS_VERSION/);
});

test('a pin equal to or ahead of Stable passes', () => {
  assert.equal(evaluate({ pinned: '155.0.8059.84', stable: '155.0.8059.84', releases: [], now }).ok, true);
  assert.equal(evaluate({ pinned: '156.0.1.1', stable: '155.0.8059.84', releases: [], now }).ok, true);
});

test('a pin behind Stable fails only after 14 days from the first newer Stable release', () => {
  const releases = version => [
    { version: '155.0.8059.84', time: now - 15 * day },
    { version: '155.0.8059.79', time: now - 40 * day },
    { version: version, time: now - 60 * day },
  ];
  const old = evaluate({ pinned: '155.0.8059.70', stable: '155.0.8059.84', releases: releases('155.0.8059.70'), now });
  assert.equal(old.daysBehind, 40, 'measured from 155.0.8059.79, the first release after the pin');
  assert.equal(old.ok, false);
  const recent = evaluate({ pinned: '155.0.8059.79', stable: '155.0.8059.84', releases: releases('155.0.8059.79'), now });
  assert.equal(recent.daysBehind, 15);
  assert.equal(recent.ok, false, `15 days is over the ${MAX_DAYS}-day limit`);
  const edge = evaluate({ pinned: '155.0.8059.79', stable: '155.0.8059.84', releases: [{ version: '155.0.8059.84', time: now - 14 * day }], now });
  assert.equal(edge.ok, true, 'exactly 14 days is allowed');
});

test('without release dates a pin behind Stable is unknown (never a pass, never a failure)', () => {
  for (const releases of [[], undefined, { unexpected: 'format' }, [{ version: '155.0.8059.84' }]]) {
    const result = evaluate({ pinned: '155.0.1.1', stable: '155.0.8059.84', releases, now });
    assert.equal(result.ok, null);
    assert.equal(result.daysBehind, null);
  }
  assert.equal(evaluate({ pinned: '154.0.1.1', stable: '155.0.8059.84', releases: [], now }).ok, null, 'an older major is unknown too');
  assert.equal(evaluate({ pinned: '155.0.8059.84', stable: '155.0.8059.84', releases: [], now }).ok, true, 'a current pin needs no dates');
});

test('getJson tries three times with a pause and then gives the last error', async () => {
  let calls = 0;
  const flaky = async () => { calls += 1; if (calls < 3) throw new Error(`down ${calls}`); return { ok: true, json: async () => ({ fine: calls }) }; };
  assert.deepEqual(await getJson('https://example.test/a', { fetchImpl: flaky, delays: [1, 1] }), { fine: 3 });
  calls = 0;
  await assert.rejects(() => getJson('https://example.test/b', { fetchImpl: async () => { calls += 1; return { ok: false, status: 503 }; }, delays: [1, 1] }), /HTTP 503/);
  assert.equal(calls, 3, 'three tries in all');
});

test('the CLI exits 2 on an unknown result, and the weekly workflow neither opens nor closes an issue for it', () => {
  const script = readFileSync(new URL('../scripts/check-cft-freshness.mjs', import.meta.url), 'utf8');
  assert.match(script, /if \(result\.ok === null\) \{[\s\S]*?return 2;/);
  const workflow = readFileSync(new URL('../.github/workflows/cft-freshness.yml', import.meta.url), 'utf8');
  assert.match(workflow, /name: Open or update the issue[^\n]*\n(?:\s+#[^\n]*\n)*\s+if: steps\.check\.outputs\.status != '2'/);
  assert.match(workflow, /\[\[ "\$status" != 2 \]\] \|\| exit 2/);
});
