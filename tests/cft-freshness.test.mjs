import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { compareVersions, evaluate, getJson, main, parseMode, pinnedVersion, MAX_DAYS, RELEASES_URL, STABLE_URL } from '../scripts/check-cft-freshness.mjs';

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

// ---- modes (owner decision of 2026-10-26: a stale Chrome pin never blocks a release) ------------------------------------------

const PIN = '155.0.8059.84';
const STABLE = '156.0.8078.47';
const dockerfile = () => `FROM x\nARG CHS_VERSION=${PIN}\nARG CHS_SHA256=ab\n`;
// A network that serves Chrome for Testing's Stable version and the release list; `releases` null = the list is down, `down` = everything is.
const network = ({ releases, down = false } = {}) => async url => {
  if (down) throw new Error('network is down');
  if (url === STABLE_URL) return { ok: true, json: async () => ({ channels: { Stable: { version: STABLE } } }) };
  if (url === RELEASES_URL && releases) return { ok: true, json: async () => releases };
  return { ok: false, status: 503 };
};
const stale = days => [{ version: STABLE, time: now - days * day }];
async function run(argv, { releases = stale(15), down = false, actions = false, pin = dockerfile } = {}) {
  const out = [];
  const err = [];
  const code = await main(argv, { fetchImpl: network({ releases, down }), delays: [1, 1], now, dockerfile: pin, env: actions ? { GITHUB_ACTIONS: 'true' } : {}, out: line => out.push(line), err: line => err.push(line) });
  return { code, out: out.join('\n'), err: err.join('\n') };
}

test('--mode is warn by default, takes two spellings, and refuses anything else', () => {
  assert.equal(parseMode([]), 'warn');
  assert.equal(parseMode(['--json']), 'warn');
  assert.equal(parseMode(['--mode', 'fail']), 'fail');
  assert.equal(parseMode(['--mode=fail']), 'fail');
  assert.equal(parseMode(['--mode', 'warn']), 'warn');
  for (const bad of [['--mode'], ['--mode', 'block'], ['--mode=']]) assert.throws(() => parseMode(bad), /--mode must be one of warn or fail/);
});

test('a stale pin: warn mode exits 0 with the warning (pinned, Stable, age); fail mode exits 1', async () => {
  const warned = await run(['--mode', 'warn'], { actions: true });
  assert.equal(warned.code, 0, 'a stale pin never fails a release');
  assert.match(warned.out, new RegExp(`^::warning title=Chrome for Testing pin is 15 days behind Stable::CHS_VERSION ${PIN.replaceAll('.', '\\.')}; Chrome for Testing Stable is ${STABLE.replaceAll('.', '\\.')}, released 15 day\\(s\\) ago\\.`));
  assert.match(warned.out, /the release goes ahead/);
  // Outside GitHub Actions the same words are a plain line on stderr.
  const plain = await run([]);
  assert.equal(plain.code, 0, 'warn is the default mode');
  assert.match(plain.err, /^Warning: CHS_VERSION 155\.0\.8059\.84; .*released 15 day\(s\) ago/);
  const failed = await run(['--mode', 'fail']);
  assert.equal(failed.code, 1);
  assert.match(failed.err, /More than 14 days behind: bump CHS_VERSION, CHS_SHA256 and puppeteer-core together/);
  assert.equal(failed.out, '', 'fail mode prints no annotation');
});

test('an unknown age or an unreachable network: warn mode exits 0 with a warning, fail mode exits 2', async () => {
  for (const options of [{ releases: null }, { down: true }]) {
    const warned = await run(['--mode', 'warn'], { ...options, actions: true });
    assert.equal(warned.code, 0, JSON.stringify(options));
    assert.match(warned.out, /^::warning title=Chrome for Testing /);
    const failed = await run(['--mode', 'fail'], options);
    assert.equal(failed.code, 2, JSON.stringify(options));
  }
  // A Dockerfile without the pin is the check failing, not a Chrome finding: still no failure in warn mode.
  assert.equal((await run(['--mode', 'warn'], { pin: () => 'FROM x\n' })).code, 0);
  assert.equal((await run(['--mode', 'fail'], { pin: () => 'FROM x\n' })).code, 2);
});

test('a current pin, or one inside 14 days, passes in both modes without a warning', async () => {
  for (const mode of ['warn', 'fail']) {
    const recent = await run(['--mode', mode], { releases: stale(14), actions: true });
    assert.equal(recent.code, 0);
    assert.doesNotMatch(recent.out, /::warning/);
    assert.match(recent.out, /Within 14 days/);
    const current = await run(['--mode', mode], { pin: () => `ARG CHS_VERSION=${STABLE}\n` });
    assert.equal(current.code, 0);
    assert.match(current.out, /\(current\)/);
  }
});

test('a mistyped --mode is a usage error (exit 2), never a silent pass', async () => {
  const result = await run(['--mode', 'block']);
  assert.equal(result.code, 2);
  assert.match(result.err, /--mode must be one of warn or fail/);
});

test('release.yml runs the check in warn mode, and only the weekly workflow fails on it', () => {
  const release = readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');
  const step = release.slice(release.indexOf('- name: Chrome for Testing freshness')).split(/\n      - /)[0];
  assert.match(step, /\n        run: node scripts\/check-cft-freshness\.mjs --mode warn\n/);
  assert.doesNotMatch(release, /--mode fail|--mode=fail/);
  const weekly = readFileSync(new URL('../.github/workflows/cft-freshness.yml', import.meta.url), 'utf8');
  assert.match(weekly, /node scripts\/check-cft-freshness\.mjs --mode fail 2>/);
});
