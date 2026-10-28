import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, copyFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { MAX_EXCEPTION_DAYS } from '../scripts/validate-image-report.mjs';
import { LEDGER, ROOT_TREE, TREES, advisoriesOf, classify, compare, gate, live, runNpmAudit, validateExceptions } from '../scripts/audit-compare.mjs';

const DAY = 24 * 60 * 60 * 1000;
const repo = new URL('..', import.meta.url).pathname;
const date = offset => new Date(Date.now() + offset * DAY).toISOString().slice(0, 10);

// `npm audit --json` (auditReportVersion 2) as npm prints it: an advisory is an object in `via`; a package that only
// depends on a vulnerable one lists that package's name (a string).
const via = (id, name, severity, source = 1000) => ({ source, name, dependency: name, title: `${name} problem`, url: `https://github.com/advisories/${id}`, severity, range: '<9' });
const report = vulnerabilities => ({ auditReportVersion: 2, vulnerabilities, metadata: { vulnerabilities: {} } });
const UNDICI = via('GHSA-xjj6-f33q-929c', 'undici', 'high', 1);
const LODASH = via('GHSA-35jh-r3h4-6jhm', 'lodash', 'critical', 2);
const FASTIFY = via('GHSA-389g-gv7q-r4x8', 'fastify', 'low', 3);
const MODERATE = via('GHSA-29mw-wpgm-hmr9', 'lodash', 'moderate', 4);
const entry = (overrides = {}) => ({
  id: 'GHSA-xjj6-f33q-929c', package: 'undici', manifest: 'docker/storage', reason: 'Only reachable through an upload path the gateway blocks.',
  owner: 'abhiguru', reviewed: date(0), expires: date(MAX_EXCEPTION_DAYS), ...overrides,
});

// ---- reading an audit ---------------------------------------------------------------------------------------------------------

test('only HIGH and CRITICAL advisories count, each named by its GHSA id, and a package that merely depends on a vulnerable one adds none', () => {
  const audit = report({
    undici: { name: 'undici', severity: 'high', via: [UNDICI, MODERATE], nodes: ['node_modules/undici'] },
    lodash: { name: 'lodash', severity: 'critical', via: [LODASH, FASTIFY] },
    'fetch-wrapper': { name: 'fetch-wrapper', severity: 'high', via: ['undici'] },
  });
  const found = advisoriesOf(audit, 'docker/storage');
  assert.deepEqual([...found.keys()].sort(), ['docker/storage|lodash|GHSA-35jh-r3h4-6jhm', 'docker/storage|undici|GHSA-xjj6-f33q-929c']);
  assert.equal(found.get('docker/storage|lodash|GHSA-35jh-r3h4-6jhm').severity, 'critical');
  // No GHSA in the URL: npm's own number identifies it. Upper-case GHSA letters are folded to the usual lower case.
  const old = { source: 1234, name: 'minimist', title: 't', url: 'https://npmjs.com/advisories/1234', severity: 'high' };
  const upper = via('GHSA-XJJ6-F33Q-929C', 'undici', 'high', 9);
  assert.deepEqual([...advisoriesOf(report({ minimist: { via: [old] }, undici: { via: [upper] } }), 'docker/pdf-renderer').keys()].sort(),
    ['docker/pdf-renderer|minimist|1234', 'docker/pdf-renderer|undici|GHSA-xjj6-f33q-929c']);
  assert.equal(advisoriesOf(report({}), 'docker/storage').size, 0);
});

// ---- the comparison -----------------------------------------------------------------------------------------------------------

const set = (...advisories) => new Map(advisories.flatMap(via => [...advisoriesOf(report({ [via.name]: { via: [via] } }), 'docker/storage')]));

test('an advisory the base did not have is added; the same set, or fewer, adds nothing', () => {
  const base = set(UNDICI);
  assert.deepEqual(compare({ base, head: set(UNDICI, LODASH), entries: [] }).uncovered.map(advisory => advisory.package), ['lodash']);
  assert.equal(compare({ base, head: set(UNDICI), entries: [] }).added.length, 0, 'the same set passes');
  assert.equal(compare({ base, head: set(), entries: [] }).added.length, 0, 'a fix passes');
  assert.equal(compare({ base: set(), head: set(UNDICI), entries: [] }).uncovered.length, 1, 'a tree with no advisories before');
});

test('a valid exception covers the new advisory; an expired one does not and is named', () => {
  const [valid, expired] = validateExceptions({ schemaVersion: 1, exceptions: [entry(), entry({ id: 'GHSA-35jh-r3h4-6jhm', package: 'lodash', reviewed: date(-100), expires: date(-10) })] });
  const covered = compare({ base: set(), head: set(UNDICI), entries: [valid] });
  assert.equal(covered.covered.length, 1);
  assert.equal(covered.uncovered.length + covered.expired.length, 0);
  const lapsed = compare({ base: set(), head: set(LODASH), entries: [expired] });
  assert.equal(lapsed.expired.length, 1);
  assert.equal(lapsed.covered.length + lapsed.uncovered.length, 0);
  // An exception is for one advisory, one package, one tree.
  assert.equal(compare({ base: set(), head: set(LODASH), entries: [valid] }).uncovered.length, 1, 'another advisory');
  assert.equal(classify([...set(UNDICI).values()].map(advisory => ({ ...advisory, manifest: 'docker/pdf-renderer' })), [valid]).uncovered.length, 1, 'another tree');
});

// ---- the ledger ---------------------------------------------------------------------------------------------------------------

const ledger = (...exceptions) => ({ schemaVersion: 1, exceptions });
const rejects = (exceptions, pattern, today) => assert.throws(() => validateExceptions(ledger(...exceptions), today), pattern);

test('the ledger: valid entries pass, an expired one is flagged, and one invalid entry rejects the whole ledger', () => {
  assert.deepEqual(validateExceptions(ledger()), []);
  assert.deepEqual(validateExceptions(ledger(entry())).map(item => item.expired), [false]);
  assert.deepEqual(validateExceptions(ledger(entry({ reviewed: date(-100), expires: date(-10) }))).map(item => item.expired), [true], 'expired is not invalid');
  rejects([entry(), entry({ id: 'GHSA-35jh-r3h4-6jhm', package: 'lodash', expires: date(MAX_EXCEPTION_DAYS + 1) })], /GHSA-35jh-r3h4-6jhm: expires more than 90 days after its review/);
  rejects([entry({ expires: date(MAX_EXCEPTION_DAYS + 1) })], /more than 90 days/);
  rejects([entry({ expires: date(0) })], /not after its review/);
  rejects([entry({ reviewed: date(5), expires: date(40) })], /in the future/);
  rejects([entry({ id: 'undici' })], /GHSA id/);
  rejects([entry({ package: 'Not A Package' })], /npm package name/);
  rejects([entry({ package: 'JSON Stream' })], /npm package name/);
  rejects([entry({ package: '' })], /npm package name/);
  rejects([entry({ manifest: 'docker/cups' })], /manifest must be one of docker\/storage, docker\/pdf-renderer/);
  rejects([entry({ reason: 'too short' })], /no reason/);
  rejects([entry({ owner: '' })], /named owner/);
  rejects([entry({ reviewed: '2026-02-30' })], /not a real date/);
  rejects([entry({ expires: undefined })], /no expires/);
  rejects([entry({ comment: 'x' })], /unknown field comment/);
  rejects([entry(), entry()], /listed twice/);
  rejects(['not an object'], /not an object/);
  assert.throws(() => validateExceptions({ schemaVersion: 2, exceptions: [] }), /schemaVersion must be 1/);
  assert.throws(() => validateExceptions({ schemaVersion: 1 }), /no exceptions list/);
  assert.throws(() => validateExceptions([]), /not a JSON object/);
});

test('the ledger: legacy npm package names with capitals (JSONStream) can be written, scoped or not', () => {
  assert.deepEqual(validateExceptions(ledger(entry({ package: 'JSONStream' }), entry({ package: '@Types/Legacy', id: 'GHSA-35jh-r3h4-6jhm' }))).map(item => item.package), ['JSONStream', '@Types/Legacy']);
});

test('the ledger: an entry is valid through its expires date and expired from the day after (the docs say "past its expires date")', async () => {
  const day = date => Date.parse(`${date}T00:00:00Z`);
  const lastDay = entry({ reviewed: '2026-08-01', expires: '2026-10-26' });
  assert.deepEqual(validateExceptions(ledger(lastDay), day('2026-10-25')).map(item => item.expired), [false], 'the day before');
  assert.deepEqual(validateExceptions(ledger(lastDay), day('2026-10-26')).map(item => item.expired), [false], 'on the expiry day');
  assert.deepEqual(validateExceptions(ledger(lastDay), day('2026-10-27')).map(item => item.expired), [true], 'the day after');
  // The same through the gate: on its last day the exception still covers a new advisory, the next day it does not.
  const f = fixture({ 'docker/storage': 'fastify', 'docker/pdf-renderer': 'fastify' });
  try {
    f.change('docker/storage', 'fastify undici');
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(lastDay)));
    const onTheDay = await runGate(f, { audit: standIn(), today: day('2026-10-26') });
    assert.equal(onTheDay.code, 0, onTheDay.err);
    assert.match(onTheDay.out, /accepted: docker\/storage: undici/);
    const after = await runGate(f, { audit: standIn(), today: day('2026-10-27') });
    assert.equal(after.code, 1);
    assert.match(after.err, /covered only by an exception that expired on 2026-10-26/);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('the shipped ledger is well formed (shape and the 90-day rule as of its newest review) and starts empty of anything unreviewed', () => {
  const shipped = JSON.parse(readFileSync(join(repo, LEDGER), 'utf8'));
  const newest = Math.max(Date.now() - 365 * DAY, ...shipped.exceptions.map(item => Date.parse(`${item.reviewed}T00:00:00Z`)));
  const entries = validateExceptions(shipped, newest);
  for (const item of entries) assert.equal(item.owner, 'abhiguru', `${item.id}: owner`);
  assert.deepEqual(Object.keys(shipped), ['schemaVersion', 'exceptions']);
});

// ---- running npm audit --------------------------------------------------------------------------------------------------------

test('npm audit: a report with advisories (exit 1) is read; anything that is not a report is tried again, then refused, never an empty pass', async () => {
  const good = report({ undici: { via: [UNDICI] } });
  const answers = [];
  const spawn = () => answers.shift();
  // npm exits 1 when it finds advisories; the report on stdout is what counts.
  answers.push({ status: 1, stdout: JSON.stringify(good), stderr: '' });
  assert.deepEqual(await runNpmAudit('/x', { spawn, delays: [1, 1] }), good);
  // The registry rate limits once, then answers.
  answers.push({ status: 1, stdout: JSON.stringify({ message: 'request failed, reason: 429', error: { summary: '', detail: '' } }), stderr: '' }, { status: 0, stdout: JSON.stringify(good), stderr: '' });
  assert.deepEqual(await runNpmAudit('/x', { spawn, delays: [1, 1] }), good);
  // It never answers.
  let calls = 0;
  const silent = () => { calls += 1; return { status: 1, stdout: JSON.stringify({ message: 'request failed, reason: ECONNREFUSED', error: {} }), stderr: '' }; };
  await assert.rejects(() => runNpmAudit('/x', { spawn: silent, delays: [1, 1] }), /npm audit gave no report for \/x \(exit 1\): request failed, reason: ECONNREFUSED/);
  assert.equal(calls, 3, 'three tries in all');
  await assert.rejects(() => runNpmAudit('/x', { spawn: () => ({ status: 1, stdout: '', stderr: 'npm ERR! code ELOCKVERIFY\nmore' }), delays: [] }), /ELOCKVERIFY/);
  await assert.rejects(() => runNpmAudit('/x', { spawn: () => ({ status: 0, stdout: JSON.stringify({ auditReportVersion: 2 }), stderr: '' }), delays: [] }), /no report/, 'a report without its vulnerabilities is not a clean one');
  await assert.rejects(() => runNpmAudit('/x', { spawn: () => ({ error: new Error('spawn npm ENOENT') }), delays: [] }), /could not run in \/x: spawn npm ENOENT/);
});

// ---- the pull-request gate ----------------------------------------------------------------------------------------------------

function git(root, ...args) {
  const run = spawnSync('git', ['-C', root, '-c', 'user.name=Test', '-c', 'user.email=test@example.test', ...args], { encoding: 'utf8' });
  assert.equal(run.status, 0, `git ${args.join(' ')}: ${run.stderr}`);
  return run.stdout.trim();
}

// A repository whose base commit holds both trees; `lock` is what each lock file says (a marker the stand-in audit reads).
function fixture(baseLocks = { 'docker/storage': 'base', 'docker/pdf-renderer': 'base' }) {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-audit-test-'));
  git(root, 'init', '-q', '-b', 'main');
  for (const tree of TREES) {
    mkdirSync(join(root, tree), { recursive: true });
    writeFileSync(join(root, tree, 'package.json'), '{"name":"tree","version":"1.0.0"}\n');
    if (baseLocks[tree] !== undefined) writeFileSync(join(root, tree, 'package-lock.json'), `${baseLocks[tree]}\n`);
  }
  writeFileSync(join(root, LEDGER), `${JSON.stringify(ledger(), null, 2)}\n`);
  git(root, 'add', '.');
  git(root, 'commit', '-q', '-m', 'base');
  return {
    root, base: git(root, 'rev-parse', 'HEAD'),
    change: (tree, lock) => writeFileSync(join(root, tree, 'package-lock.json'), `${lock}\n`),
    manifest: (tree, json) => writeFileSync(join(root, tree, 'package.json'), `${JSON.stringify(json)}\n`),
  };
}

// A stand-in for npm audit: the advisories a lock file "has" are named by its text, e.g. "undici lodash". A package.json can add
// some too (its "also" field, as an `overrides` edit can change what npm resolves), so a change to the manifest alone shows.
const ADVISORIES = { undici: UNDICI, lodash: LODASH, fastify: FASTIFY };
function standIn(calls = []) {
  return async dir => {
    const lock = readFileSync(join(dir, 'package-lock.json'), 'utf8').trim();
    const also = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8')).also ?? '';
    calls.push(lock);
    if (lock === 'broken') throw new Error('request failed, reason: ECONNREFUSED');
    return report(Object.fromEntries(`${lock} ${also}`.split(' ').filter(name => ADVISORIES[name]).map(name => [name, { via: [ADVISORIES[name]] }])));
  };
}

async function runGate(options, extra = {}) {
  const out = [];
  const err = [];
  const code = await gate({ root: options.root, baseRef: options.base, out: line => out.push(line), err: line => err.push(line), env: {}, ...extra });
  return { code, out: out.join('\n'), err: err.join('\n') };
}

test('gate: a change that leaves both trees alone passes without any audit, whatever has been published since', async () => {
  const f = fixture({ 'docker/storage': 'undici lodash', 'docker/pdf-renderer': 'undici' });
  try {
    const calls = [];
    const result = await runGate(f, { audit: standIn(calls) });
    assert.equal(result.code, 0);
    assert.deepEqual(calls, [], 'no audit was run');
    assert.match(result.out, /docker\/storage: package\.json and package-lock\.json are the base's; nothing new can come from this change, no audit run/);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: a new advisory fails with what to do; the same advisories, or a fix, pass', async () => {
  const f = fixture({ 'docker/storage': 'undici', 'docker/pdf-renderer': 'undici' });
  try {
    f.change('docker/storage', 'undici lodash');
    const added = await runGate(f, { audit: standIn() });
    assert.equal(added.code, 1);
    assert.match(added.err, /docker\/storage: lodash GHSA-35jh-r3h4-6jhm \(critical, lodash problem\).*: added by this change\. Raise the dependency so the advisory is gone, or record a reviewed exception in docker\/npm-audit-exceptions\.json/);
    assert.doesNotMatch(added.err, /undici/, 'the advisory the base already had is not blamed on the change');
    f.change('docker/storage', 'undici');
    f.change('docker/pdf-renderer', 'undici fastify');
    const same = await runGate(f, { audit: standIn() });
    assert.equal(same.code, 0, 'a low advisory and the old HIGH one: nothing new at HIGH');
    f.change('docker/storage', 'fastify');
    assert.equal((await runGate(f, { audit: standIn() })).code, 0, 'removing an advisory is a pass');
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: a new advisory covered by a valid exception passes and is shown; by an expired one it fails with the message to renew it', async () => {
  const f = fixture({ 'docker/storage': 'fastify', 'docker/pdf-renderer': 'fastify' });
  try {
    f.change('docker/storage', 'fastify undici');
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(entry())));
    const covered = await runGate(f, { audit: standIn() });
    assert.equal(covered.code, 0);
    assert.match(covered.out, /accepted: docker\/storage: undici GHSA-xjj6-f33q-929c .*exception until/);
    const expiredEntry = entry({ reviewed: date(-100), expires: date(-10) });
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(expiredEntry)));
    const expired = await runGate(f, { audit: standIn() });
    assert.equal(expired.code, 1);
    assert.match(expired.err, new RegExp(`covered only by an exception that expired on ${expiredEntry.expires}\\. Renew it in docker/npm-audit-exceptions\\.json`));
    // An expired exception that covers nothing in this change does not hold up an unrelated pull request, but is mentioned.
    f.change('docker/storage', 'fastify');
    const unrelated = await runGate(f, { audit: standIn() });
    assert.equal(unrelated.code, 0);
    assert.match(unrelated.err, /expired npm audit exception\(s\) cover nothing: undici GHSA-xjj6-f33q-929c/);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: a ledger that breaks a rule rejects everything, and the audit that cannot be read is never a pass', async () => {
  const f = fixture();
  try {
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(entry({ expires: date(MAX_EXCEPTION_DAYS + 30) }))));
    const bad = await runGate(f, { audit: standIn() });
    assert.equal(bad.code, 1);
    assert.match(bad.err, /Dependency audit refused: npm audit exception GHSA-xjj6-f33q-929c: expires more than 90 days after its review/);
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger()));
    f.change('docker/storage', 'broken');
    const unreadable = await runGate(f, { audit: standIn() });
    assert.equal(unreadable.code, 2);
    assert.match(unreadable.err, /could not run for docker\/storage: request failed.*a failed audit is never a pass/s);
    // The base cannot be audited: the comparison is impossible, so it is not a pass either.
    const g = fixture({ 'docker/storage': 'broken', 'docker/pdf-renderer': 'base' });
    try {
      g.change('docker/storage', 'undici');
      assert.equal((await runGate(g, { audit: standIn() })).code, 2);
    } finally { rmSync(g.root, { recursive: true, force: true }); }
    const missing = await runGate({ root: f.root, base: '0'.repeat(40) }, { audit: standIn() });
    assert.equal(missing.code, 2);
    assert.match(missing.err, /base commit 0{40} is not in this checkout \(git fetch --no-tags --depth=1 origin 0{40}\)/);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: a tree the base did not have has no advisories to compare with, so what it brings is new', async () => {
  const f = fixture({ 'docker/storage': 'base' });
  try {
    f.change('docker/pdf-renderer', 'lodash');
    const calls = [];
    const added = await runGate(f, { audit: standIn(calls) });
    assert.equal(added.code, 1);
    assert.match(added.err, /docker\/pdf-renderer: lodash/);
    assert.deepEqual(calls, ['lodash'], 'only the change was audited: there is no base lock');
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: a lock deleted while package.json stays fails (the audit and the image build need it); a tree removed whole leaves nothing to audit', async () => {
  const f = fixture({ 'docker/storage': 'base' });
  try {
    f.change('docker/pdf-renderer', 'lodash');
    rmSync(join(f.root, 'docker/storage/package-lock.json'));
    const calls = [];
    const removed = await runGate({ root: f.root, base: f.base }, { audit: standIn(calls) });
    assert.equal(removed.code, 1, 'a package.json without its lock is not a pass');
    assert.match(removed.err, /Dependency audit: docker\/storage has a package\.json but no package-lock\.json: npm audit and the image build need the lock\./);
    assert.doesNotMatch(removed.out, /nothing is left to audit/);
    // The check goes on to the next tree: its advisory is reported as well.
    assert.match(removed.err, /docker\/pdf-renderer: lodash GHSA-35jh-r3h4-6jhm/);
    assert.deepEqual(calls, ['lodash'], 'pdf-renderer was audited, the lock-less tree could not be');
    const annotated = await runGate({ root: f.root, base: f.base }, { audit: standIn(), env: { GITHUB_ACTIONS: 'true' } });
    assert.match(annotated.out, /^::error title=A dependency tree has no package-lock\.json::docker\/storage has a package\.json but no package-lock\.json/m);
    // The tree removed whole (both files) leaves nothing to audit; with the other tree back at the base's lock the gate passes.
    rmSync(join(f.root, 'docker/storage/package.json'));
    rmSync(join(f.root, 'docker/pdf-renderer/package-lock.json'));
    const gone = await runGate({ root: f.root, base: f.base }, { audit: standIn() });
    assert.equal(gone.code, 0, gone.err);
    assert.match(gone.out, /docker\/storage: this change removes the tree; nothing is left to audit/);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: a change to package.json alone (an overrides edit, say) is audited too: either manifest file differing is enough', async () => {
  const f = fixture({ 'docker/storage': 'undici', 'docker/pdf-renderer': 'undici' });
  try {
    f.manifest('docker/pdf-renderer', { name: 'tree', version: '1.0.0', also: 'lodash' });
    const calls = [];
    const result = await runGate(f, { audit: standIn(calls) });
    assert.equal(result.code, 1, 'the manifest alone brought a critical advisory');
    assert.deepEqual(calls, ['undici', 'undici'], 'the change and the base of pdf-renderer were audited, and storage was not');
    assert.match(result.err, /docker\/pdf-renderer: lodash GHSA-35jh-r3h4-6jhm/);
    assert.match(result.out, /docker\/storage: package\.json and package-lock\.json are the base's/);
    // A manifest edit that adds nothing is audited and passes.
    f.manifest('docker/pdf-renderer', { name: 'tree', version: '1.0.1' });
    const harmless = [];
    assert.equal((await runGate(f, { audit: standIn(harmless) })).code, 0);
    assert.equal(harmless.length, 2, 'audited all the same');
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: GitHub shows each problem as an error annotation', async () => {
  const f = fixture({ 'docker/storage': 'base', 'docker/pdf-renderer': 'base' });
  try {
    f.change('docker/storage', 'lodash');
    const result = await runGate(f, { audit: standIn(), env: { GITHUB_ACTIONS: 'true' } });
    assert.equal(result.code, 1);
    assert.match(result.out, /^::error title=This change adds a dependency advisory::docker\/storage: lodash GHSA-35jh-r3h4-6jhm/m);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('gate: an exception that covers an advisory the change adds is shown as a warning annotation, with its reason, where a reviewer looks', async () => {
  const f = fixture({ 'docker/storage': 'fastify', 'docker/pdf-renderer': 'fastify' });
  try {
    f.change('docker/storage', 'fastify undici');
    // The change brings the dependency and the exception for it together: green, but never silent.
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(entry({ reason: 'Only reachable through an upload path the gateway blocks (100% of uploads).' }))));
    const result = await runGate(f, { audit: standIn(), env: { GITHUB_ACTIONS: 'true' } });
    assert.equal(result.code, 0);
    assert.match(result.out, new RegExp(`^::warning title=Advisory accepted by an exception::docker/storage: undici GHSA-xjj6-f33q-929c \\(high, undici problem\\) https://github\\.com/advisories/GHSA-xjj6-f33q-929c \\(until ${date(MAX_EXCEPTION_DAYS)}: Only reachable through an upload path the gateway blocks \\(100%25 of uploads\\)\\.\\)$`, 'm'));
    assert.equal(result.out.split('\n').filter(line => line.startsWith('::warning')).length, 1, 'one per covered advisory');
    assert.doesNotMatch(result.out, /^::error/m);
    const quiet = await runGate(f, { audit: standIn(), env: {} });
    assert.equal(quiet.code, 0);
    assert.doesNotMatch(quiet.out, /::warning/, 'annotations only on GitHub');
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

// ---- the weekly run -----------------------------------------------------------------------------------------------------------

async function runLive(options, extra = {}) {
  const out = [];
  const err = [];
  const code = await live({ root: options.root, out: line => out.push(line), err: line => err.push(line), ...extra });
  return { code, out: out.join('\n'), err: err.join('\n') };
}

test('weekly: clean exits 0; advisories without an exception, expired exceptions and exceptions about to expire are reported (exit 1) and written to the report file', async () => {
  const f = fixture({ 'docker/storage': 'undici', 'docker/pdf-renderer': 'base' });
  try {
    const reportPath = join(f.root, 'advisories.md');
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(entry())));
    const clean = await runLive(f, { audit: standIn(), reportPath });
    assert.equal(clean.code, 0, 'the one advisory has a valid exception');
    assert.match(clean.out, /No HIGH or CRITICAL advisory without a valid exception.*\(1 covered by an exception\)/);
    assert.equal(existsSync(reportPath), false, 'no report when clean');
    f.change('docker/storage', 'undici lodash');
    const open = await runLive(f, { audit: standIn(), reportPath });
    assert.equal(open.code, 1);
    const text = readFileSync(reportPath, 'utf8');
    assert.match(text, /\*\*Advisories with no exception\*\*[^]*- docker\/storage: lodash GHSA-35jh-r3h4-6jhm \(critical/);
    assert.doesNotMatch(text, /- docker\/storage: undici/, 'a covered advisory is not a finding');
    assert.match(text, /What to do: raise the dependency[^]*docker\/npm-audit-exceptions\.json/);
    // An exception about to expire is a reminder even when nothing else is open.
    f.change('docker/storage', 'undici');
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(entry({ reviewed: date(-80), expires: date(7) }))));
    const soon = await runLive(f, { audit: standIn(), reportPath });
    assert.equal(soon.code, 1);
    assert.match(readFileSync(reportPath, 'utf8'), /expire within 14 days[^]*undici GHSA-xjj6-f33q-929c[^]*until/);
    // An expired exception whose advisory is still there, and one whose advisory is gone.
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(entry({ reviewed: date(-100), expires: date(-10) }), entry({ id: 'GHSA-389g-gv7q-r4x8', package: 'fastify', reviewed: date(-100), expires: date(-10) }))));
    const lapsed = await runLive(f, { audit: standIn(), reportPath });
    assert.equal(lapsed.code, 1);
    const lapsedText = readFileSync(reportPath, 'utf8');
    assert.match(lapsedText, /exception has expired[^]*Renew it in docker\/npm-audit-exceptions\.json/);
    assert.match(lapsedText, /match no advisory[^]*fastify GHSA-389g-gv7q-r4x8, expired/);
    // An invalid ledger is a finding of its own, in the report; an unreadable audit is exit 2.
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger(entry({ expires: date(MAX_EXCEPTION_DAYS + 30) }))));
    assert.equal((await runLive(f, { audit: standIn(), reportPath })).code, 1);
    assert.match(readFileSync(reportPath, 'utf8'), /exception ledger .* is invalid, so the audit was not run.*more than 90 days/);
    writeFileSync(join(f.root, LEDGER), JSON.stringify(ledger()));
    f.change('docker/pdf-renderer', 'broken');
    assert.equal((await runLive(f, { audit: standIn() })).code, 2);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

// ---- the command line, with a stand-in `npm` ----------------------------------------------------------------------------------

test('command line: the same decisions through scripts/audit-compare.mjs with an npm that is not the real one', () => {
  const f = fixture({ 'docker/storage': 'undici', 'docker/pdf-renderer': 'base' });
  try {
    mkdirSync(join(f.root, 'scripts'));
    for (const name of ['audit-compare.mjs', 'is-main.mjs', 'validate-image-report.mjs']) copyFileSync(join(repo, 'scripts', name), join(f.root, 'scripts', name));
    mkdirSync(join(f.root, 'bin'));
    const log = join(f.root, 'npm.log');
    // The "npm" prints an audit report naming the advisories its lock file lists, and records that it ran.
    writeFileSync(join(f.root, 'bin/npm'), `#!${process.execPath}
const fs = require('fs');
fs.appendFileSync(${JSON.stringify(log)}, process.argv.slice(2).join(' ') + '\\n');
const names = fs.readFileSync('package-lock.json', 'utf8').trim().split(' ').filter(Boolean);
const via = { undici: { source: 1, name: 'undici', title: 't', url: 'https://github.com/advisories/GHSA-xjj6-f33q-929c', severity: 'high' }, lodash: { source: 2, name: 'lodash', title: 't', url: 'https://github.com/advisories/GHSA-35jh-r3h4-6jhm', severity: 'critical' } };
const vulnerabilities = Object.fromEntries(names.filter(name => via[name]).map(name => [name, { via: [via[name]] }]));
console.log(JSON.stringify({ auditReportVersion: 2, vulnerabilities }));
process.exit(names.some(name => via[name]) ? 1 : 0);
`, { mode: 0o700 });
    const run = (...args) => spawnSync(process.execPath, ['scripts/audit-compare.mjs', ...args], { cwd: f.root, encoding: 'utf8', env: { ...process.env, PATH: `${join(f.root, 'bin')}:${process.env.PATH}`, GITHUB_ACTIONS: '' } });
    const unchanged = run('--base-ref', f.base);
    assert.equal(unchanged.status, 0, unchanged.stderr);
    assert.equal(existsSync(log), false, 'npm never ran for a change that touches no manifest');
    f.change('docker/storage', 'undici lodash');
    const added = run('--base-ref', f.base);
    assert.equal(added.status, 1);
    assert.match(added.stderr, /lodash GHSA-35jh-r3h4-6jhm/);
    assert.match(readFileSync(log, 'utf8'), /^audit --json --omit=dev\n/);
    const weekly = run('--live', '--report', join(f.root, 'r.md'));
    assert.equal(weekly.status, 1);
    assert.match(readFileSync(join(f.root, 'r.md'), 'utf8'), /lodash GHSA-35jh-r3h4-6jhm/);
    for (const args of [[], ['--live', '--base-ref', f.base], ['--base-ref'], ['--bogus']]) assert.equal(run(...args).status, 2, args.join(' '));
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

// ---- where it runs ------------------------------------------------------------------------------------------------------------

test('ci.yml: the live audit is not in the pull-request check; the comparison with the base is, and the weekly workflow runs the live audit', () => {
  const ci = readFileSync(join(repo, '.github/workflows/ci.yml'), 'utf8');
  const commands = ci.split('\n').filter(line => !line.trim().startsWith('#')).join('\n');
  assert.doesNotMatch(commands, /check:container-dependencies|npm audit/, 'no live audit in ci.yml');
  const validate = ci.slice(ci.indexOf('\n  validate:\n') + 1).split(/\n  [a-z-]+:\n/)[0];
  const step = validate.slice(validate.indexOf('- name: Dependency advisories this change adds'));
  assert.match(step, /\n        if: github\.event_name == 'pull_request'\n/);
  assert.match(step, /BASE_SHA: \$\{\{ github\.event\.pull_request\.base\.sha \}\}/);
  assert.match(step, /git fetch --no-tags --depth=1 origin "\$BASE_SHA"\n          node scripts\/audit-compare\.mjs --base-ref "\$BASE_SHA"(?:\n|$)/);
  assert.ok(validate.indexOf('- run: npm test') < validate.indexOf('- name: Dependency advisories this change adds'), 'after npm test');
  const weekly = readFileSync(join(repo, '.github/workflows/dependency-audit.yml'), 'utf8');
  assert.match(weekly, /\n  schedule:\n    - cron: '[0-9]+ [0-9]+ \* \* [0-7]'\n/, 'weekly');
  assert.match(weekly, /node scripts\/audit-compare\.mjs --live --report "\$RUNNER_TEMP\/advisories\.md"/);
  // A finding (exit 1) never fails the run; the audit that could not be read (exit 2) does.
  assert.match(weekly, /status=\$\?\n[^\n]*\n[^\n]*\n[^\n]*\n\s+\[\[ "\$status" != 2 \]\] \|\| exit 2/);
  assert.match(weekly, /gh issue edit "\$number"[^\n]*--title "\$title" --body-file/, 'edited in place');
  assert.match(weekly, /gh issue close "\$number"/);
  // An edit sends no notification, so a finding that is new in an already open issue gets ONE comment that lists only the new lines
  // (a deliberate change to the earlier "no comment at all" rule); a week with nothing new edits silently. The step is run for real in
  // tests/workflows.test.mjs.
  assert.equal(weekly.match(/gh issue comment/g).length, 1, 'one comment, and only for new lines');
  assert.match(weekly, /if \[\[ -n "\$new" \]\]; then\n[^\n]*\n\s+gh issue comment "\$number"[^\n]*\n\s+fi\n\s+gh issue edit "\$number"/, 'the comment sits under the "new findings" condition, before the edit');
  assert.match(weekly, /permissions:\n  contents: read\n  issues: write\n/);
  assert.match(readFileSync(join(repo, 'package.json'), 'utf8'), /"check:container-dependencies": "npm audit --prefix docker\/storage --omit=dev --audit-level=high && npm audit --prefix docker\/pdf-renderer --omit=dev --audit-level=high"/, 'the live audit stays available by hand');
});

// ---- the release job's root tree ----------------------------------------------------------------------------------------------

test('gate --with-root: the repository root (devDependencies included) is compared with the base like the container trees; without the flag it is left alone', async () => {
  const f = fixture({ 'docker/storage': 'base', 'docker/pdf-renderer': 'base' });
  try {
    writeFileSync(join(f.root, 'package.json'), '{"name":"root"}\n');
    writeFileSync(join(f.root, 'package-lock.json'), 'undici\n');
    git(f.root, 'add', 'package.json', 'package-lock.json');
    git(f.root, 'commit', '-q', '-m', 'root');
    const base = git(f.root, 'rev-parse', 'HEAD');
    const seen = [];
    const audit = async (dir, options) => { seen.push(options.omitDev); return standIn()(dir); };
    const same = await runGate({ ...f, base }, { audit, withRoot: true });
    assert.equal(same.code, 0);
    assert.match(same.out, /^\.: package\.json and package-lock\.json are the base's/m, 'an unchanged root is not audited');
    writeFileSync(join(f.root, 'package-lock.json'), 'undici lodash\n');
    const without = await runGate({ ...f, base }, { audit });
    assert.equal(without.code, 0, 'the container-tree gate of a pull request never looks at the root');
    const added = await runGate({ ...f, base }, { audit, withRoot: true });
    assert.equal(added.code, 1);
    assert.match(added.err, /\.: lodash GHSA-35jh-r3h4-6jhm .*added by this change/);
    assert.doesNotMatch(added.err, /undici/, 'what the previous tag already had is not blamed on this one');
    assert.deepEqual(seen, [false, false], 'the root audit includes devDependencies (jose is one)');
    // A ledger entry for the root covers it.
    writeFileSync(join(f.root, LEDGER), `${JSON.stringify(ledger(entry({ id: 'GHSA-35jh-r3h4-6jhm', package: 'lodash', manifest: ROOT_TREE })), null, 2)}\n`);
    assert.equal((await runGate({ ...f, base }, { audit, withRoot: true })).code, 0);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
});

test('release.yml gates the root audit on the previous release tag with audit-compare, and no longer runs a bare npm audit', () => {
  const release = readFileSync(join(repo, '.github/workflows/release.yml'), 'utf8');
  const commands = release.split('\n').filter(line => !line.trim().startsWith('#')).join('\n');
  assert.doesNotMatch(commands, /npm audit/);
  assert.match(release, /fetch-depth: 0/, 'the previous tag must be in the checkout');
  assert.match(release, /node scripts\/audit-compare\.mjs --base-ref "\$previous" --with-root/);
  assert.ok(release.indexOf('- run: npm test') < release.indexOf('--with-root'), 'after npm test');
});
