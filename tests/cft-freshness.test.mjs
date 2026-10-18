import test from 'node:test';
import assert from 'node:assert/strict';
import { compareVersions, evaluate, pinnedVersion, MAX_DAYS } from '../scripts/check-cft-freshness.mjs';

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

test('without release dates an older major fails and the same major passes', () => {
  assert.equal(evaluate({ pinned: '154.0.1.1', stable: '155.0.8059.84', releases: [], now }).ok, false);
  assert.equal(evaluate({ pinned: '155.0.1.1', stable: '155.0.8059.84', releases: [], now }).ok, true);
});
