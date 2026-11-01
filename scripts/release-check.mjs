// "A newer release exists" for doctor and the daily status: information only, never an alert and never a message of its own.
//
//   releaseLine({ root, state, run, fetchJson, now }) -> Promise<string | null>
//
// The running release is the base tag (vX.Y.Z) of backendRelease in <state>/public/release.json (what `git describe` said at the last
// setup). The newest final release is read from the origin's tags (`git ls-remote --tags origin 'v*'`, 10 s). When it is newer:
//
//   vX.Y.Z is available (this facility runs vA.B.C)[ - Security release][; support for the vA.B line ends YYYY-MM-DD]
//
// When the running line has its own newer release that is not the newest overall, that one is named first:
//   vA.B.D is available for your line (this facility runs vA.B.C); newest is vX.Y.Z
//
// One GitHub API call (the public releases list of the origin, when the origin is on github.com; unauthenticated, 10 s, no redirects, best
// effort and silent on failure) gives: the Security marker (any final release newer than the running one with "security" in its title,
// SECURITY.md, "How a fix is announced") and the publication dates for the support-end note. The note follows SECURITY.md's rule: a line is
// supported 6 months after the next minor release came out, and no longer once the minor after that is out; the dates come from the
// API, else from tags already in this checkout (no fetch); a date that cannot be told is left out. Every git command runs without any
// prompt (gitEnv). Nothing here throws; any failure is null (or just no marker).
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

export const LOOKUP_TIMEOUT_MS = 10000;
export const SUPPORT_MONTHS = 6;
// git must never ask anything (a terminal, a password, an ssh host key): it runs with no stdin and this environment.
export const gitEnv = (base = process.env) => ({ ...base, GIT_TERMINAL_PROMPT: '0', GIT_ASKPASS: '/bin/false', SSH_ASKPASS: '',
  GIT_SSH_COMMAND: 'ssh -o BatchMode=yes -o ConnectTimeout=5' });

const FINAL_TAG = /^v(\d+)\.(\d+)\.(\d+)$/;
const BASE_TAG = /^(v\d+\.\d+\.\d+)(?:-.+)?$/;
const parts = tag => FINAL_TAG.exec(tag)?.slice(1).map(Number) ?? null;
export const compareTags = (a, b) => { const x = parts(a); const y = parts(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; };

// The final tags in `git ls-remote --tags` output, oldest first: release candidates ("-rc") and peeled entries ("^{}") are not releases.
export function finalTags(lsRemote) {
  const tags = new Set();
  for (const line of String(lsRemote).split('\n')) {
    const ref = line.split('\t')[1]?.trim();
    const tag = ref?.startsWith('refs/tags/') ? ref.slice('refs/tags/'.length) : null;
    if (tag && FINAL_TAG.test(tag)) tags.add(tag);
  }
  return [...tags].sort(compareTags);
}
export const newestFinalTag = lsRemote => finalTags(lsRemote).at(-1) ?? null;

// The running release's base tag, or null when it is not a final tag's descendant ("unknown", a bare commit, a release candidate).
export function runningTag(backendRelease) {
  const base = BASE_TAG.exec(String(backendRelease ?? ''))?.[1];
  if (!base) return null;
  return /^v\d+\.\d+\.\d+-rc/i.test(String(backendRelease)) ? null : base;
}

// Calendar months later in UTC; a day that the target month does not have becomes its last day (31 August + 6 months is 28 February).
export const addMonths = (date, months) => {
  const total = date.getUTCFullYear() * 12 + date.getUTCMonth() + months;
  const year = Math.floor(total / 12);
  const month = total % 12;
  const last = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  return new Date(Date.UTC(year, month, Math.min(date.getUTCDate(), last), date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds()));
};
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

function defaultRun(command, args, { timeoutMs = LOOKUP_TIMEOUT_MS, env = gitEnv() } = {}) {
  const r = spawnSync(command, args, { encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'ignore'], env });
  return { status: r.status ?? (r.error ? 127 : 1), stdout: r.stdout ?? '' };
}
export async function fetchGithubJson(url, { timeoutMs = LOOKUP_TIMEOUT_MS, fetchImpl = fetch } = {}) {
  const response = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs), redirect: 'error', headers: { accept: 'application/vnd.github+json', 'user-agent': 'warehouse-release-check' } });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// "owner/repo" of a github.com origin (https or ssh form), else null.
export function githubRepo(url) {
  return /^(?:https:\/\/|git@|ssh:\/\/git@)github\.com[:/]([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?\/?$/.exec(String(url).trim())?.[1] ?? null;
}

export async function releaseLine({ root, state, run = defaultRun, fetchJson = fetchGithubJson, now = () => Date.now() } = {}) {
  try {
    let record;
    try { record = JSON.parse(readFileSync(join(state, 'public/release.json'), 'utf8')); } catch { return null; }
    const running = runningTag(record?.backendRelease);
    if (!running) return null;
    const options = { timeoutMs: LOOKUP_TIMEOUT_MS, env: gitEnv() };
    const listed = run('git', ['-C', root, 'ls-remote', '--tags', 'origin', 'v*'], options);
    if (listed.status !== 0) return null;
    const tags = finalTags(listed.stdout);
    const newest = tags.at(-1);
    if (!newest || compareTags(newest, running) <= 0) return null;
    const [major, minor] = parts(running);
    const lineNewest = tags.filter(t => { const p = parts(t); return p[0] === major && p[1] === minor; }).at(-1);
    let line = lineNewest && lineNewest !== newest && compareTags(lineNewest, running) > 0
      ? `${lineNewest} is available for your line (this facility runs ${running}); newest is ${newest}`
      : `${newest} is available (this facility runs ${running})`;
    // The releases list of the origin: Security marker and publication dates. Any failure leaves both out (dates fall back to local tags).
    const published = new Map();
    try {
      const repo = githubRepo(run('git', ['-C', root, 'remote', 'get-url', 'origin'], options).stdout);
      if (repo) {
        const releases = await fetchJson(`https://api.github.com/repos/${repo}/releases?per_page=100`, { timeoutMs: LOOKUP_TIMEOUT_MS });
        let security = false;
        for (const release of Array.isArray(releases) ? releases : []) {
          if (!release || release.draft || release.prerelease || !FINAL_TAG.test(String(release.tag_name))) continue;
          const at = new Date(release.published_at);
          if (!Number.isNaN(at.getTime())) published.set(release.tag_name, at);
          if (compareTags(release.tag_name, running) > 0 && /security/i.test(String(release.name ?? ''))) security = true;
        }
        if (security) line += ' \u2014 Security release';
      }
    } catch { /* best effort: no marker */ }
    try {
      line += supportNote(running, newest, tag => {
        if (published.has(tag)) return published.get(tag);
        const r = run('git', ['-C', root, 'log', '-1', '--format=%cI', `refs/tags/${tag}`], options);
        const at = r.status === 0 ? new Date(r.stdout.trim()) : null;
        return at && !Number.isNaN(at.getTime()) ? at : null;
      }, now());
    } catch { /* no date */ }
    return line;
  } catch { return null; }
}
