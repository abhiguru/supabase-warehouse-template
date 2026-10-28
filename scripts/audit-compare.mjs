#!/usr/bin/env node
// The advisories of the two frozen npm trees, docker/storage and docker/pdf-renderer (production dependencies,
// HIGH and CRITICAL only), as a pull-request gate and as a weekly report.
//
//   node scripts/audit-compare.mjs --base-ref SHA [--exceptions FILE]
//     The pull-request gate (ci.yml, job `validate`). For each tree whose package.json or package-lock.json differs
//     from the one at SHA, `npm audit --json` runs on the change and on the base, and the gate fails ONLY when the
//     change introduces an advisory the base did not have and no valid exception covers it. A tree the change does not
//     touch is not audited: an advisory published after the last merge never blocks an unrelated pull request. A change
//     that leaves a tree with a package.json and no package-lock.json fails (npm audit and the image build need the lock).
//     --with-root adds the repository's own tree (the root package.json: devDependencies included, since they run in the
//     release job) and is for release.yml, where the base is the previous release tag.
//   node scripts/audit-compare.mjs --live [--exceptions FILE] [--report FILE]
//     The weekly run (dependency-audit.yml): audits both trees as they are and reports every advisory with no valid
//     exception, every expired exception and every exception that expires within 14 days; --report writes that as Markdown.
//
//   Exit 0 nothing to report; 1 the gate refuses (a new advisory, an invalid ledger) or the weekly run has findings;
//   2 the audit could not be read (registry unreachable, no base commit): never a pass.
//
// Owner decision of 2026-10-26: the live audit leaves the required pull-request check (a frozen tree of about 900
// packages meets a new advisory in any week, and every pull request stayed red until the lock was rebuilt, 2026-10-24);
// the weekly run finds new advisories, the gate only refuses a change that makes the audit worse.
//
// The exception ledger, docker/npm-audit-exceptions.json (docs/CONTAINER_SECURITY.md, "Dependency advisory exceptions"):
//   { "schemaVersion": 1, "exceptions": [ { id, package, manifest, reason, owner, reviewed, expires } ] }
// `id` is the advisory (GHSA-xxxx-xxxx-xxxx, the id npm prints in the advisory URL; the numeric npm id when it prints no
// GHSA), `package` the vulnerable package, `manifest` the tree (docker/storage or docker/pdf-renderer). Like the image
// ledger, an entry that is malformed, reviewed in the future or valid for more than 90 days rejects the whole ledger. An
// entry past its `expires` date covers nothing: an advisory it would have covered is a failure that says to renew it.
import { readFileSync, existsSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';
import { MAX_EXCEPTION_DAYS, utcToday } from './validate-image-report.mjs';

export const TREES = ['docker/storage', 'docker/pdf-renderer'];
export const ROOT_TREE = '.';
export const LEDGER = 'docker/npm-audit-exceptions.json';
export const SOON_DAYS = 14;
const DAY = 24 * 60 * 60 * 1000;
const FILES = ['package.json', 'package-lock.json'];
const SEVERITIES = ['high', 'critical'];
const FIELDS = ['id', 'package', 'manifest', 'reason', 'owner', 'reviewed', 'expires'];
const fail = message => { throw new Error(message); };
const nonEmptyString = value => typeof value === 'string' && value.trim().length > 0;

function day(value, what) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) fail(`${what} is not a YYYY-MM-DD date`);
  const time = Date.parse(`${value}T00:00:00Z`);
  if (Number.isNaN(time) || new Date(time).toISOString().slice(0, 10) !== value) fail(`${what} is not a real date`);
  return time;
}

// Returns the entries, each with `expired` (true past its expires date), or throws naming the first invalid one.
// An invalid entry rejects the whole ledger; an expired one does not (it only stops covering anything).
export function validateExceptions(ledger, today = utcToday()) {
  if (!ledger || typeof ledger !== 'object' || Array.isArray(ledger)) fail('npm audit exception ledger is not a JSON object');
  if (ledger.schemaVersion !== 1) fail('npm audit exception ledger schemaVersion must be 1');
  if (!Array.isArray(ledger.exceptions)) fail('npm audit exception ledger has no exceptions list');
  const seen = new Set();
  return ledger.exceptions.map(entry => {
    const where = `npm audit exception ${nonEmptyString(entry?.id) ? entry.id : '(no id)'}`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) fail(`${where} is not an object`);
    const unknown = Object.keys(entry).filter(key => !FIELDS.includes(key));
    if (unknown.length) fail(`${where}: unknown field ${unknown.join(', ')}`);
    for (const field of FIELDS) if (entry[field] === undefined) fail(`${where}: no ${field}`);
    if (typeof entry.id !== 'string' || !/^(?:GHSA(?:-[0-9a-z]{4}){3}|\d+)$/.test(entry.id)) fail(`${where}: id must be a GHSA id (GHSA-xxxx-xxxx-xxxx) or a numeric npm advisory id`);
    if (typeof entry.package !== 'string' || !/^(?:@[a-z0-9~-][a-z0-9._~-]*\/)?[a-z0-9~-][a-z0-9._~-]*$/i.test(entry.package)) fail(`${where}: package is not an npm package name`);
    if (![...TREES, ROOT_TREE].includes(entry.manifest)) fail(`${where}: manifest must be one of ${[...TREES, ROOT_TREE].join(', ')}`);
    if (!nonEmptyString(entry.reason) || entry.reason.trim().length < 20) fail(`${where}: no reason (say why the advisory does not apply or cannot be fixed yet)`);
    if (typeof entry.owner !== 'string' || !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/.test(entry.owner)) fail(`${where}: no named owner`);
    const reviewed = day(entry.reviewed, `${where}: reviewed`);
    const expires = day(entry.expires, `${where}: expires`);
    if (reviewed > today) fail(`${where}: reviewed ${entry.reviewed} is in the future`);
    if (expires <= reviewed) fail(`${where}: expires ${entry.expires} is not after its review`);
    if (expires - reviewed > MAX_EXCEPTION_DAYS * DAY) fail(`${where}: expires more than ${MAX_EXCEPTION_DAYS} days after its review`);
    const key = `${entry.manifest}|${entry.package}|${entry.id}`;
    if (seen.has(key)) fail(`${where}: listed twice for ${entry.package} in ${entry.manifest}`);
    seen.add(key);
    return { ...entry, expired: expires < today };
  });
}

// The advisory id npm prints: the GHSA of the advisory URL, else npm's own number.
const advisoryId = via => {
  const ghsa = /\/advisories\/GHSA((?:-[0-9a-z]{4}){3})\b/i.exec(String(via.url ?? ''))?.[1];
  return ghsa ? `GHSA${ghsa.toLowerCase()}` : String(via.source);
};

// `audit` is the JSON of `npm audit --json` (auditReportVersion 2). Returns Map key -> advisory for the HIGH and
// CRITICAL ones. A vulnerability lists, in `via`, either an advisory (an object) or the name of another vulnerable
// package (a string: its own entry holds the advisory), so only the objects count.
export function advisoriesOf(audit, manifest) {
  const found = new Map();
  for (const vulnerability of Object.values(audit.vulnerabilities ?? {})) {
    for (const via of vulnerability?.via ?? []) {
      if (!via || typeof via !== 'object' || !SEVERITIES.includes(via.severity)) continue;
      const advisory = { id: advisoryId(via), package: String(via.name ?? vulnerability.name), manifest, severity: via.severity, title: String(via.title ?? ''), url: String(via.url ?? '') };
      found.set(`${manifest}|${advisory.package}|${advisory.id}`, advisory);
    }
  }
  return found;
}

const keyOf = advisory => `${advisory.manifest}|${advisory.package}|${advisory.id}`;
const describe = advisory => `${advisory.manifest}: ${advisory.package} ${advisory.id} (${advisory.severity}${advisory.title ? `, ${advisory.title}` : ''})${advisory.url ? ` ${advisory.url}` : ''}`;

// Sorts advisories by what the ledger says: covered by a valid entry, covered only by an expired one, or not at all.
export function classify(advisories, entries) {
  const result = { covered: [], expired: [], uncovered: [] };
  for (const advisory of advisories) {
    const matches = entries.filter(entry => keyOf(entry) === keyOf(advisory));
    const valid = matches.find(entry => !entry.expired);
    if (valid) result.covered.push({ advisory, entry: valid });
    else if (matches.length) result.expired.push({ advisory, entry: matches[0] });
    else result.uncovered.push(advisory);
  }
  return result;
}

// The gate: what the change added to the base's advisories, and what of that no valid exception covers.
export function compare({ base, head, entries }) {
  const added = [...head.values()].filter(advisory => !base.has(keyOf(advisory)));
  return { added, ...classify(added, entries) };
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// `npm audit --json` in DIR (which holds the two manifest files). An answer that is not an audit report (the registry
// is unreachable or rate limits, the lock is unreadable) is tried again after a pause and then throws: never an empty pass.
export async function runNpmAudit(dir, { spawn = spawnSync, delays = [5000, 15000], omitDev = true } = {}) {
  let last;
  for (let attempt = 0; attempt <= delays.length; attempt += 1) {
    const run = spawn('npm', ['audit', '--json', ...(omitDev ? ['--omit=dev'] : [])], { cwd: dir, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 180_000 });
    if (run.error) last = new Error(`npm audit could not run in ${dir}: ${run.error.message}`);
    else {
      let audit;
      try { audit = JSON.parse(run.stdout); } catch { audit = undefined; }
      if (audit?.auditReportVersion === 2 && audit.vulnerabilities && typeof audit.vulnerabilities === 'object') return audit;
      last = new Error(`npm audit gave no report for ${dir} (exit ${run.status}): ${audit?.message ?? (String(run.stderr).trim().split('\n')[0] || 'no output')}`);
    }
    if (attempt < delays.length) await sleep(delays[attempt]);
  }
  throw last;
}

function git(root, args) {
  const run = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return run.status === 0 ? run.stdout : undefined;
}

// A scratch directory holding the two manifest files (given as texts), for npm to audit.
function scratch(texts) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-audit-'));
  for (const [name, text] of Object.entries(texts)) writeFileSync(join(dir, name), text);
  return dir;
}

async function auditTexts(texts, manifest, deps) {
  const dir = scratch(texts);
  try { return advisoriesOf(await (deps.audit ?? runNpmAudit)(dir, { ...deps, omitDev: manifest !== ROOT_TREE }), manifest); } finally { rmSync(dir, { recursive: true, force: true }); }
}

function loadEntries(path, today) {
  if (!existsSync(path)) fail(`${path} is missing: the npm audit exception ledger must exist (empty is fine)`);
  return validateExceptions(JSON.parse(readFileSync(path, 'utf8')), today);
}

const expiredNotice = ({ advisory, entry }) => `${describe(advisory)}: covered only by an exception that expired on ${entry.expires}. Renew it in ${LEDGER} (a new review date and an expiry at most ${MAX_EXCEPTION_DAYS} days later) or fix the advisory`;

// The pull-request gate. Returns the exit code.
export async function gate({ root, baseRef, withRoot = false, ledger = join(root, LEDGER), today = utcToday(), out = console.log, err = console.error, env = process.env, ...deps }) {
  const annotate = (title, message, level = 'error') => { if (env.GITHUB_ACTIONS === 'true') out(`::${level} title=${title}::${message.replace(/%/g, '%25').replace(/\r?\n/g, ' ')}`); };
  let entries;
  try { entries = loadEntries(ledger, today); } catch (error) { err(`Dependency audit refused: ${error.message}`); annotate('Dependency audit exceptions invalid', error.message); return 1; }
  const expiredEntries = entries.filter(entry => entry.expired);
  if (expiredEntries.length) err(`Warning: expired npm audit exception(s) cover nothing: ${expiredEntries.map(entry => `${entry.package} ${entry.id} (expired ${entry.expires})`).join(', ')}. Renew or remove them.`);
  if (git(root, ['cat-file', '-e', `${baseRef}^{commit}`]) === undefined) {
    err(`Dependency audit could not run: the base commit ${baseRef} is not in this checkout (git fetch --no-tags --depth=1 origin ${baseRef}).`);
    return 2;
  }
  const problems = [];
  const problem = (text, title = 'This change adds a dependency advisory') => problems.push({ title, text });
  for (const tree of withRoot ? [...TREES, ROOT_TREE] : TREES) {
    const head = Object.fromEntries(FILES.map(name => [name, existsSync(join(root, tree, name)) ? readFileSync(join(root, tree, name), 'utf8') : '']));
    const base = Object.fromEntries(FILES.map(name => [name, git(root, ['show', `${baseRef}:${tree === ROOT_TREE ? '' : `${tree}/`}${name}`]) ?? '']));
    if (FILES.every(name => head[name] === base[name])) {
      out(`${tree}: package.json and package-lock.json are the base's; nothing new can come from this change, no audit run.`);
      continue;
    }
    if (head['package-lock.json'] === '') {
      // The whole tree removed leaves nothing to audit; a package.json without its lock is a tree that npm audit cannot read and
      // the image build (COPY package.json package-lock.json) cannot build: not a pass.
      if (head['package.json'] === '') out(`${tree}: this change removes the tree; nothing is left to audit.`);
      else problem(`${tree} has a package.json but no package-lock.json: npm audit and the image build need the lock`, 'A dependency tree has no package-lock.json');
      continue;
    }
    let result;
    try {
      const headAdvisories = await auditTexts(head, tree, deps);
      // A tree the base did not have has no advisories to compare with: everything the change adds is new.
      const baseAdvisories = base['package-lock.json'] === '' ? new Map() : await auditTexts(base, tree, deps);
      result = compare({ base: baseAdvisories, head: headAdvisories, entries });
    } catch (error) {
      err(`Dependency audit could not run for ${tree}: ${error.message}\nRun the check again; a failed audit is never a pass.`);
      return 2;
    }
    out(`${tree}: ${result.added.length} HIGH/CRITICAL advisor${result.added.length === 1 ? 'y' : 'ies'} added by this change` +
      `${result.covered.length ? `, ${result.covered.length} covered by an exception` : ''}.`);
    // The ledger is read from the change's own tree, so a pull request can add a dependency and the exception for it together:
    // the annotation puts that on the checks page, where a reviewer looks, and not only in the log.
    for (const { advisory, entry } of result.covered) {
      out(`  accepted: ${describe(advisory)} (exception until ${entry.expires}: ${entry.reason})`);
      annotate('Advisory accepted by an exception', `${describe(advisory)} (until ${entry.expires}: ${entry.reason})`, 'warning');
    }
    for (const item of result.expired) problem(expiredNotice(item));
    for (const advisory of result.uncovered) problem(`${describe(advisory)}: added by this change. Raise the dependency so the advisory is gone, or record a reviewed exception in ${LEDGER} (at most ${MAX_EXCEPTION_DAYS} days)`);
  }
  for (const { title, text } of problems) { err(`Dependency audit: ${text}.`); annotate(title, text); }
  return problems.length ? 1 : 0;
}

// The weekly run. Returns the exit code and the Markdown report.
export async function live({ root, ledger = join(root, LEDGER), today = utcToday(), out = console.log, err = console.error, reportPath, ...deps }) {
  let entries;
  try { entries = loadEntries(ledger, today); } catch (error) {
    err(`Dependency audit refused: ${error.message}`);
    if (reportPath) writeFileSync(reportPath, `**The exception ledger \`${LEDGER}\` is invalid, so the audit was not run:** ${error.message}\n`);
    return 1;
  }
  const all = [];
  for (const tree of TREES) {
    try {
      const texts = Object.fromEntries(FILES.map(name => [name, readFileSync(join(root, tree, name), 'utf8')]));
      all.push(...(await auditTexts(texts, tree, deps)).values());
    } catch (error) {
      err(`Dependency audit could not run for ${tree}: ${error.message}`);
      return 2;
    }
  }
  const { covered, expired, uncovered } = classify(all, entries);
  const soonLimit = today + SOON_DAYS * DAY;
  const lines = [];
  if (uncovered.length) lines.push('**Advisories with no exception** (HIGH or CRITICAL, production dependencies):', '', ...uncovered.map(advisory => `- ${describe(advisory)}`), '');
  if (expired.length) lines.push('**Advisories whose exception has expired**:', '', ...expired.map(item => `- ${expiredNotice(item)}`), '');
  const lapsed = entries.filter(entry => entry.expired && !expired.some(item => item.entry === entry));
  if (lapsed.length) lines.push('**Expired exceptions that match no advisory** (remove them from the ledger):', '', ...lapsed.map(entry => `- ${entry.manifest}: ${entry.package} ${entry.id}, expired ${entry.expires}`), '');
  const soon = covered.filter(({ entry }) => Date.parse(`${entry.expires}T00:00:00Z`) <= soonLimit);
  if (soon.length) lines.push(`**Exceptions that expire within ${SOON_DAYS} days** (renew, or raise the dependency):`, '', ...soon.map(({ advisory, entry }) => `- ${describe(advisory)}: until ${entry.expires}`), '');
  if (!lines.length) {
    out(`No HIGH or CRITICAL advisory without a valid exception in ${TREES.join(' and ')}${covered.length ? ` (${covered.length} covered by an exception)` : ''}.`);
    return 0;
  }
  const report = [...lines, `What to do: raise the dependency (docker/storage/README.md, "Moving to a new publisher tag" for the Storage tree), or record a reviewed exception in \`${LEDGER}\` (a reason, and an expiry at most ${MAX_EXCEPTION_DAYS} days after the review; docs/CONTAINER_SECURITY.md, "Dependency advisory exceptions").`].join('\n');
  out(report);
  if (reportPath) writeFileSync(reportPath, `${report}\n`);
  return 1;
}

export async function main(argv = process.argv.slice(2), deps = {}) {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const options = {};
  const rest = [...argv];
  while (rest.length) {
    const flag = rest.shift();
    if (flag === '--live') options.live = true;
    else if (flag === '--with-root') options.withRoot = true;
    else if (['--base-ref', '--exceptions', '--report'].includes(flag) && rest.length) options[flag.slice(2)] = rest.shift();
    else { console.error(`unknown or incomplete option ${flag}\nusage: audit-compare.mjs --base-ref SHA [--with-root] [--exceptions FILE] | --live [--exceptions FILE] [--report FILE]`); return 2; }
  }
  if (Boolean(options.live) === Boolean(options['base-ref']) || (options.live && options.withRoot)) { console.error('usage: audit-compare.mjs --base-ref SHA [--with-root] [--exceptions FILE] | --live [--exceptions FILE] [--report FILE]'); return 2; }
  const common = { root, ...(options.exceptions && { ledger: options.exceptions }), ...deps };
  return options.live ? live({ ...common, reportPath: options.report }) : gate({ ...common, baseRef: options['base-ref'], withRoot: Boolean(options.withRoot) });
}

if (isMain(import.meta.url)) {
  main().then(code => { process.exitCode = code; }, error => { console.error(error.message); process.exitCode = 2; });
}
