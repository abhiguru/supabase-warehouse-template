#!/usr/bin/env node
// "App compatibility is a window, not a pin" (CONTRIBUTING.md, "Mobile companion pin"): app-compat.json names the oldest app build this
// backend answers, and MOBILE_MIN_REF (ci.yml) is the app commit that first carried that version. This script judges the three ways
// that promise breaks:
//   R1  the app at MOBILE_MIN_REF has the version app-compat.json declares as the minimum;
//   R2  the minimum is a plain MAJOR.MINOR.PATCH and not lower than in the previous final release;
//   R3  nothing that app calls (RPC, table, edge function) was dropped since the previous final release, unless the minimum was raised.
//
//   node scripts/check-app-compat.mjs --report FILE --app-json FILE [--previous TAG|auto] [--require-previous] [--root DIR] [--tag NAME]
//
// --report: the JSON that `scripts/check-mobile-contract.mjs <app checkout at MOBILE_MIN_REF> --output FILE` writes.
// --app-json: app.json of that checkout. --previous auto: the newest FINAL release tag (vX.Y.Z) reachable from HEAD whose version is not
// the version of --tag (default $GITHUB_REF_NAME), so a release candidate and its final are never compared with themselves. Without a
// previous tag R2 and R3 are skipped, or refused with --require-previous (the release workflow). --root: the checkout to judge (default:
// this one; the tests use throwaway repositories).
import { readFileSync, readdirSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { definedNames } from './contract-sql.mjs';
import { isMain } from './is-main.mjs';

/** Only MAJOR.MINOR.PATCH counts: a pre-release or a build suffix cannot be ordered the way the app orders its own version. */
export function parseVersion(text) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(typeof text === 'string' ? text : '');
  return match ? match.slice(1).map(Number) : null;
}

export function compareVersions(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}

/**
 * Pure judgement. minimum / previousMinimum / appVersion: version strings (previousMinimum null = unknown);
 * called, previousDefined, currentDefined: { rpc, tables, edge } arrays of names.
 * Returns the list of problems; each is { rule, message } and ends with the remedy.
 */
export function judge({ minimum, previousMinimum = null, previousLabel = 'the previous release', appVersion, called, previousDefined = null, currentDefined }) {
  const problems = [];
  const min = parseVersion(minimum);
  if (!min) {
    problems.push({ rule: 'R2', message: `minimumClientVersion "${minimum}" in app-compat.json is not MAJOR.MINOR.PATCH. Write it like 0.6.0.` });
    return problems;
  }
  const app = parseVersion(appVersion);
  if (!app) problems.push({ rule: 'R1', message: `The app at MOBILE_MIN_REF has the version "${appVersion}", which is not MAJOR.MINOR.PATCH. Move MOBILE_MIN_REF to an app commit with a plain version.` });
  else if (compareVersions(app, min) !== 0) {
    problems.push({ rule: 'R1', message: `The app at MOBILE_MIN_REF is version ${appVersion}, but minimumClientVersion is ${minimum}. MOBILE_MIN_REF must be the first app commit that carries version ${minimum}: move one of them so they agree.` });
  }
  let raised = false;
  if (previousMinimum !== null) {
    const before = parseVersion(previousMinimum);
    if (before) {
      const order = compareVersions(min, before);
      if (order < 0) problems.push({ rule: 'R2', message: `minimumClientVersion ${minimum} is lower than ${previousMinimum} in ${previousLabel}. A release never lowers the minimum (builds below ${previousMinimum} have already been told to update): restore ${previousMinimum} or higher.` });
      raised = order > 0;
    }
  }
  if (previousDefined && !raised) {
    for (const [group, label] of [['rpc', 'function'], ['tables', 'table'], ['edge', 'edge function']]) {
      const now = new Set(currentDefined[group]);
      const before = new Set(previousDefined[group]);
      for (const name of called[group] ?? []) {
        if (before.has(name) && !now.has(name)) {
          problems.push({ rule: 'R3', message: `The ${label} ${name} is called by the app at MOBILE_MIN_REF, existed in ${previousLabel} and is gone. Raise minimumClientVersion and move MOBILE_MIN_REF to the first commit of the new minimum, or keep ${name}.` });
        }
      }
    }
  }
  return problems;
}

const EDGE_SKIP = new Set(['main', '_shared']);
const bySqlOrder = (a, b) => (basename(a) < basename(b) ? -1 : 1);

function sqlFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? sqlFiles(path) : entry.name.endsWith('.sql') ? [path] : [];
  });
}

/** Names the working tree of ROOT defines (the same reading as scripts/check-mobile-contract.mjs). */
export function currentNames(root) {
  const { functions, relations } = definedNames(sqlFiles(join(root, 'migrations')).sort(bySqlOrder).map(path => readFileSync(path, 'utf8')));
  let edge = [];
  try { edge = readdirSync(join(root, 'functions'), { withFileTypes: true }).filter(e => e.isDirectory() && !EDGE_SKIP.has(e.name)).map(e => e.name); } catch { /* no functions directory */ }
  return { rpc: functions, tables: relations, edge };
}

function git(root, args) {
  const run = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (run.error || run.status !== 0) return null;
  return run.stdout;
}

/** Names TAG defines, read from git objects only. */
export function taggedNames(root, tag) {
  const listing = git(root, ['ls-tree', '-r', '--name-only', tag, '--', 'migrations']);
  if (listing === null) throw new Error(`cannot read migrations of ${tag}`);
  const files = listing.split('\n').filter(path => path.endsWith('.sql')).sort(bySqlOrder);
  const texts = files.map(path => {
    const text = git(root, ['show', `${tag}:${path}`]);
    if (text === null) throw new Error(`cannot read ${path} of ${tag}`);
    return text;
  });
  const { functions, relations } = definedNames(texts);
  const edge = (git(root, ['ls-tree', '--name-only', '-d', tag, 'functions/']) ?? '').split('\n').filter(Boolean).map(path => basename(path)).filter(name => !EDGE_SKIP.has(name));
  return { rpc: functions, tables: relations, edge };
}

/** The newest final release tag reachable from HEAD whose version differs from TAG's own; null when there is none. */
export function previousFinalTag(root, currentTag = '') {
  const tags = git(root, ['tag', '--merged', 'HEAD', '--list', 'v[0-9]*']);
  if (tags === null) return null;
  const own = currentTag.replace(/^v/, '').split(/[-+]/)[0];
  const finals = tags.split('\n').filter(tag => /^v\d+\.\d+\.\d+$/.test(tag) && tag.slice(1) !== own);
  finals.sort((a, b) => compareVersions(parseVersion(b.slice(1)), parseVersion(a.slice(1))));
  return finals[0] ?? null;
}

function main(argv) {
  const option = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : undefined; };
  const reportPath = option('--report');
  const appJson = option('--app-json');
  if (!reportPath || !appJson) {
    console.error('Usage: node scripts/check-app-compat.mjs --report FILE --app-json FILE [--previous TAG|auto] [--require-previous] [--root DIR] [--tag NAME]');
    return 2;
  }
  const root = resolve(option('--root') ?? fileURLToPath(new URL('..', import.meta.url)));
  const fail = message => { console.error(`App compatibility: ${message}`); return 1; };
  let report, app, compat;
  try { report = JSON.parse(readFileSync(reportPath, 'utf8')); } catch (error) { return fail(`cannot read the contract report ${reportPath}: ${error.message}`); }
  try { app = JSON.parse(readFileSync(appJson, 'utf8')); } catch (error) { return fail(`cannot read ${appJson}: ${error.message}`); }
  try { compat = JSON.parse(readFileSync(join(root, 'app-compat.json'), 'utf8')); } catch (error) { return fail(`cannot read app-compat.json: ${error.message}`); }
  const called = {};
  for (const group of ['rpc', 'tables', 'edge']) {
    if (!Array.isArray(report?.[group]?.called)) return fail(`the contract report has no ${group}.called list (write it with check-mobile-contract.mjs --output)`);
    called[group] = report[group].called;
  }
  const appVersion = app?.expo?.version ?? app?.version;

  let previous = option('--previous') ?? 'auto';
  if (previous === 'auto') previous = previousFinalTag(root, option('--tag') ?? process.env.GITHUB_REF_NAME ?? '');
  let previousMinimum = null;
  let previousDefined = null;
  if (previous === null) {
    if (argv.includes('--require-previous')) return fail('no previous final release tag is reachable, so the minimum cannot be compared. Fetch the tags (fetch-depth: 0) or name one with --previous.');
    console.log('App compatibility: no previous final release tag; only R1 (the pin matches the minimum) is checked.');
  } else {
    if (git(root, ['rev-parse', '--verify', '--quiet', `${previous}^{commit}`]) === null) return fail(`the previous release ${previous} is not in this checkout.`);
    const text = git(root, ['show', `${previous}:app-compat.json`]);
    if (text === null) console.log(`App compatibility: ${previous} has no app-compat.json; R2 is skipped.`);
    else {
      try { previousMinimum = JSON.parse(text).minimumClientVersion; } catch { return fail(`app-compat.json of ${previous} is not valid JSON.`); }
    }
    try { previousDefined = taggedNames(root, previous); } catch (error) { return fail(error.message); }
  }
  const problems = judge({ minimum: compat.minimumClientVersion, previousMinimum, previousLabel: previous ?? undefined, appVersion, called, previousDefined, currentDefined: currentNames(root) });
  for (const problem of problems) console.error(`${problem.rule}: ${problem.message}`);
  if (problems.length) return 1;
  console.log(`App compatibility: minimumClientVersion ${compat.minimumClientVersion}, app at MOBILE_MIN_REF ${appVersion}${previous ? `, compared with ${previous}` : ''}: ok.`);
  return 0;
}

if (isMain(import.meta.url)) process.exitCode = main(process.argv.slice(2));
