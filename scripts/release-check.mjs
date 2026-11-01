// "A newer release exists" for doctor and the daily status: information only, never an alert and never a message of its own.
//
//   releaseLine({ root, state, run, fetchJson, now }) -> string | null
//
// The running release is the base tag (vX.Y.Z) of backendRelease in <state>/public/release.json (what `git describe` said at the last
// setup). The newest final release is read from the origin's tags (`git ls-remote --tags origin 'v*'`, 10 s). When it is newer:
//
//   vX.Y.Z is available (this facility runs vA.B.C)[ - Security release][; support for the vA.B line ends YYYY-MM-DD]
//
// "Security release": the GitHub release title of the newer tag says "security" (SECURITY.md, "How a fix is announced"); best effort, silent
// on any failure. The support-end note follows SECURITY.md's rule, from the dates of tags already in this checkout (no fetch): a line is
// supported 6 months after the next minor release came out, and no longer once the minor after that is out. A date that cannot be
// computed from the local tags is left out. Nothing here throws; any failure is null (or just no marker).
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

export const RELEASE_REPO = 'abhiguru/supabase-warehouse-template';
export const LOOKUP_TIMEOUT_MS = 10000;
export const SUPPORT_MONTHS = 6;

const FINAL_TAG = /^v(\d+)\.(\d+)\.(\d+)$/;
const BASE_TAG = /^(v\d+\.\d+\.\d+)(?:-.+)?$/;
const parts = tag => FINAL_TAG.exec(tag)?.slice(1).map(Number) ?? null;
export const compareTags = (a, b) => { const x = parts(a); const y = parts(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; };

// The newest final tag in `git ls-remote --tags` output: release candidates ("-rc") and peeled entries ("^{}") are not releases.
export function newestFinalTag(lsRemote) {
  let newest = null;
  for (const line of String(lsRemote).split('\n')) {
    const ref = line.split('\t')[1]?.trim();
    const tag = ref?.startsWith('refs/tags/') ? ref.slice('refs/tags/'.length) : null;
    if (tag && FINAL_TAG.test(tag) && (!newest || compareTags(tag, newest) > 0)) newest = tag;
  }
  return newest;
}

// The running release's base tag, or null when it is not a final tag's descendant ("unknown", a bare commit, a release candidate).
export function runningTag(backendRelease) {
  const base = BASE_TAG.exec(String(backendRelease ?? ''))?.[1];
  if (!base) return null;
  return /^v\d+\.\d+\.\d+-rc/i.test(String(backendRelease)) ? null : base;
}

const addMonths = (date, months) => { const d = new Date(date.getTime()); d.setUTCMonth(d.getUTCMonth() + months); return d; };
const day = date => date.toISOString().slice(0, 10);

// The support-end note for the line of `running`, or ''. `tagDate(tag)` is the commit date of a tag held locally, or null.
// Table-driven: [what ends it, tag that starts the clock, months]. The line ends at the earlier known date.
export function supportNote(running, newest, tagDate, now = Date.now()) {
  const [major, minor] = parts(running);
  const [newMajor, newMinor] = parts(newest);
  if (newMajor !== major || newMinor <= minor) return '';   // the same line (a patch is the fix), or another major: no rule to apply
  const rules = [[`v${major}.${minor + 1}.0`, SUPPORT_MONTHS], [`v${major}.${minor + 2}.0`, 0]];
  const ends = rules.map(([tag, months]) => { const at = tagDate(tag); return at ? addMonths(at, months) : null; }).filter(Boolean);
  if (!ends.length) return '';
  const end = ends.reduce((a, b) => (a < b ? a : b));
  return `; support for the v${major}.${minor} line ${end.getTime() <= now ? 'ended' : 'ends'} ${day(end)}`;
}

function defaultRun(command, args, { timeoutMs = LOOKUP_TIMEOUT_MS } = {}) {
  const r = spawnSync(command, args, { encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'ignore'], env: { ...process.env, GIT_TERMINAL_PROMPT: '0' } });
  return { status: r.status ?? (r.error ? 127 : 1), stdout: r.stdout ?? '' };
}
async function defaultFetchJson(url, { timeoutMs = LOOKUP_TIMEOUT_MS } = {}) {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), redirect: 'error', headers: { accept: 'application/vnd.github+json', 'user-agent': 'warehouse-release-check' } });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function releaseLine({ root, state, run = defaultRun, fetchJson = defaultFetchJson, now = () => Date.now() } = {}) {
  try {
    let record;
    try { record = JSON.parse(readFileSync(join(state, 'public/release.json'), 'utf8')); } catch { return null; }
    const running = runningTag(record?.backendRelease);
    if (!running) return null;
    const listed = run('git', ['-C', root, 'ls-remote', '--tags', 'origin', 'v*'], { timeoutMs: LOOKUP_TIMEOUT_MS });
    if (listed.status !== 0) return null;
    const newest = newestFinalTag(listed.stdout);
    if (!newest || compareTags(newest, running) <= 0) return null;
    let line = `${newest} is available (this facility runs ${running})`;
    try {
      const release = await fetchJson(`https://api.github.com/repos/${RELEASE_REPO}/releases/tags/${newest}`, { timeoutMs: LOOKUP_TIMEOUT_MS });
      if (/security/i.test(String(release?.name ?? ''))) line += ' — Security release';
    } catch { /* best effort: no marker */ }
    try {
      line += supportNote(running, newest, tag => {
        const r = run('git', ['-C', root, 'log', '-1', '--format=%cI', `refs/tags/${tag}`], { timeoutMs: LOOKUP_TIMEOUT_MS });
        const at = r.status === 0 ? new Date(r.stdout.trim()) : null;
        return at && !Number.isNaN(at.getTime()) ? at : null;
      }, now());
    } catch { /* no date */ }
    return line;
  } catch { return null; }
}
