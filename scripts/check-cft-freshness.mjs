#!/usr/bin/env node
// Checks the chrome-headless-shell build pinned in docker/pdf-renderer/Dockerfile (ARG CHS_VERSION) against the
// current Stable of Chrome for Testing: more than 14 days behind it is "too old".
//
//   node scripts/check-cft-freshness.mjs --mode fail   exit 0 fresh, 1 too old, 2 unknown (the weekly issue, cft-freshness.yml)
//   node scripts/check-cft-freshness.mjs --mode warn   the default: the same findings as a warning, always exit 0 (release.yml)
//   node scripts/check-cft-freshness.mjs --json        the result, one JSON line on stdout, as well
//
// Owner decision of 2026-10-26: a stale Chrome pin never blocks a release. release.yml runs warn mode, so the tag
// goes ahead and the run shows a warning; the weekly issue stays the signal (docs/CONTAINER_SECURITY.md, "PDF renderer").
// In warn mode nothing fails: not an old pin, not an unknown age, not a network error. Only a mistyped --mode exits 2.
//
// "Behind" is measured from the day Google released the first Stable newer than the pin
// (chromiumdash's release list, which carries a time; Chrome for Testing's own
// last-known-good-versions.json carries none). If that list cannot be read or has no release
// newer than the pin (the service is down or its format changed), a pin behind Stable cannot be
// dated: the result is UNKNOWN (exit 2), never a pass. A failing network is retried 3 times.
// Why the pin matters: Trivy cannot see the CfT binary (docs/CONTAINER_SECURITY.md, "PDF renderer").
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const STABLE_URL = 'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json';
export const RELEASES_URL = 'https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Linux&num=60';
export const MAX_DAYS = 14;
export const MODES = ['warn', 'fail'];
const DAY = 86_400_000;

const parts = version => String(version).split('.').map(Number);
export function compareVersions(a, b) {
  const [left, right] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(left.length, right.length); i += 1) {
    const diff = (left[i] ?? 0) - (right[i] ?? 0);
    if (diff) return Math.sign(diff);
  }
  return 0;
}

export function pinnedVersion(dockerfileText) {
  const match = /^ARG CHS_VERSION=(\d+\.\d+\.\d+\.\d+)$/m.exec(dockerfileText);
  if (!match) throw new Error('docker/pdf-renderer/Dockerfile has no "ARG CHS_VERSION=<a.b.c.d>" line');
  return match[1];
}

// releases: [{ version, time (ms since epoch) }] in any order, Stable channel.
export function evaluate({ pinned, stable, releases, now }) {
  if (compareVersions(pinned, stable) >= 0) return { ok: true, pinned, stable, daysBehind: 0, basis: 'current' };
  const newer = (Array.isArray(releases) ? releases : []).filter(item => item && typeof item.time === 'number' && compareVersions(item.version, pinned) > 0);
  if (newer.length) {
    const first = Math.min(...newer.map(item => item.time));
    const daysBehind = Math.max(0, Math.floor((now - first) / DAY));
    return { ok: daysBehind <= MAX_DAYS, pinned, stable, daysBehind, basis: 'release date' };
  }
  // No dated release to measure from: the age is unknown, which is neither a pass nor a failure.
  return { ok: null, pinned, stable, daysBehind: null, basis: 'unknown (no dated release newer than the pin)' };
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// 3 tries with a growing pause; `delays` is injectable for tests.
export async function getJson(url, { fetchImpl = fetch, delays = [2000, 5000] } = {}) {
  let last;
  for (let attempt = 0; attempt <= delays.length; attempt += 1) {
    try {
      const response = await fetchImpl(url, { signal: AbortSignal.timeout(30_000), redirect: 'error' });
      if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
      return await response.json();
    } catch (error) {
      last = error;
      if (attempt < delays.length) await sleep(delays[attempt]);
    }
  }
  throw last;
}

// --mode warn (default) or --mode fail, also as --mode=fail; anything else is refused.
export function parseMode(argv) {
  const index = argv.findIndex(arg => arg === '--mode' || arg.startsWith('--mode='));
  if (index === -1) return 'warn';
  const value = argv[index] === '--mode' ? argv[index + 1] : argv[index].slice('--mode='.length);
  if (!MODES.includes(value)) throw new Error(`--mode must be one of ${MODES.join(' or ')} (got ${JSON.stringify(value)})`);
  return value;
}

// `deps` is for the tests: the network, the clock, the Dockerfile text, the environment and the two output streams.
export async function main(argv = process.argv.slice(2), deps = {}) {
  const {
    fetchImpl = fetch, delays, now = Date.now(), env = process.env, out = console.log, err = console.error,
    dockerfile = () => readFileSync(new URL('docker/pdf-renderer/Dockerfile', new URL('../', import.meta.url)), 'utf8'),
  } = deps;
  let mode;
  try { mode = parseMode(argv); } catch (error) { err(error.message); return 2; }
  // In GitHub Actions a warning is an annotation on the run; elsewhere it is a line of text.
  const warn = (title, message) => (env.GITHUB_ACTIONS === 'true' ? out(`::warning title=${title}::${message}`) : err(`Warning: ${message}`));
  try {
    const pinned = pinnedVersion(dockerfile());
    const stable = (await getJson(STABLE_URL, { fetchImpl, ...(delays && { delays }) })).channels?.Stable?.version;
    if (!/^\d+\.\d+\.\d+\.\d+$/.test(stable ?? '')) throw new Error('Chrome for Testing answered without a Stable version');
    let releases = [];
    try { releases = await getJson(RELEASES_URL, { fetchImpl, ...(delays && { delays }) }); } catch (error) { err(`Release dates unavailable (${error.message}).`); }
    const result = evaluate({ pinned, stable, releases, now });
    if (argv.includes('--json')) out(JSON.stringify(result));
    if (result.ok === null) {
      const text = `CHS_VERSION ${pinned}; Chrome for Testing Stable is ${stable}: ${result.basis}. Cannot say how far behind it is; check by hand.`;
      if (mode === 'warn') { warn('Chrome for Testing pin: age unknown', `${text} The release goes ahead.`); return 0; }
      err(text);
      return 2;
    }
    const line = `CHS_VERSION ${pinned}; Chrome for Testing Stable is ${stable}${result.daysBehind ? `, released ${result.daysBehind} day(s) ago` : ' (current)'}.`;
    if (result.ok) { out(`${line} Within ${MAX_DAYS} days.`); return 0; }
    const bump = 'bump CHS_VERSION, CHS_SHA256 and puppeteer-core together (docs/CONTAINER_SECURITY.md, "PDF renderer")';
    if (mode === 'warn') {
      warn(`Chrome for Testing pin is ${result.daysBehind} days behind Stable`,
        `${line} More than ${MAX_DAYS} days behind, and the release goes ahead (a stale pin is accepted for a release; the weekly issue tracks it): ${bump} when you can.`);
      return 0;
    }
    err(`${line} More than ${MAX_DAYS} days behind: ${bump}.`);
    return 1;
  } catch (error) {
    // Warn mode never fails the caller; fail mode keeps exit 2 for "the check itself did not work".
    if (mode === 'warn') { warn('Chrome for Testing freshness not checked', `${error.message}. The release goes ahead; check the pin by hand.`); return 0; }
    err(error.message);
    return 2;
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().then(code => { process.exitCode = code; }, error => { console.error(error.message); process.exitCode = 2; });
}
