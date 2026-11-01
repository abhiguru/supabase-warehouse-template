import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { compareVersions, judge, parseVersion, previousFinalTag } from '../scripts/check-app-compat.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const script = join(root, 'scripts/check-app-compat.mjs');
const none = { rpc: [], tables: [], edge: [] };

test('the real app-compat.json declares a plain MAJOR.MINOR.PATCH minimum', () => {
  const compat = JSON.parse(readFileSync(join(root, 'app-compat.json'), 'utf8'));
  assert.ok(parseVersion(compat.minimumClientVersion), compat.minimumClientVersion);
});

test('versions: only MAJOR.MINOR.PATCH parses, and order is numeric', () => {
  assert.deepEqual(parseVersion('0.6.0'), [0, 6, 0]);
  for (const bad of ['0.6', '0.6.0-rc.1', 'v0.6.0', '01.2.3', '', null, undefined, 6]) assert.equal(parseVersion(bad), null, String(bad));
  assert.equal(compareVersions([0, 10, 0], [0, 9, 0]), 1);
  assert.equal(compareVersions([1, 0, 0], [0, 99, 99]), 1);
  assert.equal(compareVersions([0, 6, 0], [0, 6, 0]), 0);
});

const base = { minimum: '0.6.0', appVersion: '0.6.0', called: none, currentDefined: none };
const rules = problems => problems.map(p => p.rule);

test('R1: the app at MOBILE_MIN_REF has exactly the declared minimum', () => {
  assert.deepEqual(judge(base), []);
  assert.deepEqual(rules(judge({ ...base, appVersion: '0.5.9' })), ['R1'], 'an older app than the minimum');
  // A newer pin than the declared minimum means the pin moved and the minimum did not: the oldest supported build is then not the pinned one.
  assert.deepEqual(rules(judge({ ...base, appVersion: '0.7.0' })), ['R1'], 'a pin newer than the declared minimum');
  assert.match(judge({ ...base, appVersion: '0.7.0' })[0].message, /first app commit that carries version 0\.6\.0/);
  assert.deepEqual(rules(judge({ ...base, appVersion: undefined })), ['R1']);
});

test('R2: the minimum never falls below the previous release', () => {
  assert.deepEqual(judge({ ...base, previousMinimum: '0.6.0' }), [], 'same');
  assert.deepEqual(judge({ ...base, minimum: '0.7.0', appVersion: '0.7.0', previousMinimum: '0.6.0' }), [], 'raised');
  const lower = judge({ ...base, previousMinimum: '0.7.0', previousLabel: 'v0.7.0' });
  assert.deepEqual(rules(lower), ['R2']);
  assert.match(lower[0].message, /lower than 0\.7\.0 in v0\.7\.0/);
  assert.deepEqual(rules(judge({ ...base, minimum: '0.10.0', appVersion: '0.10.0', previousMinimum: '0.9.0' })), [], '0.10.0 is above 0.9.0');
  assert.deepEqual(rules(judge({ ...base, minimum: '0.6', previousMinimum: '0.6.0' })), ['R2'], 'not semver');
  assert.deepEqual(judge({ ...base, previousMinimum: null }), [], 'no previous minimum: skipped');
});

test('R3: a name the app calls that was dropped fails unless the minimum rose', () => {
  const called = { rpc: ['restore_customer', 'get_items'], tables: ['customers'], edge: ['get-config'] };
  const previousDefined = { rpc: ['restore_customer', 'get_items'], tables: ['customers'], edge: ['get-config'] };
  const currentDefined = { rpc: ['get_items'], tables: [], edge: [] };
  const problems = judge({ ...base, called, previousDefined, currentDefined, previousMinimum: '0.6.0' });
  assert.deepEqual(rules(problems), ['R3', 'R3', 'R3']);
  assert.match(problems.map(p => p.message).join('\n'), /function restore_customer[\s\S]*table customers[\s\S]*edge function get-config/);
  assert.deepEqual(judge({ ...base, minimum: '0.7.0', appVersion: '0.7.0', called, previousDefined, currentDefined, previousMinimum: '0.6.0' }), [], 'raised');
  assert.deepEqual(judge({ ...base, called: { ...none, rpc: ['restore_customer'] }, previousDefined: none, currentDefined }), [], 'not defined before: not a drop');
  assert.deepEqual(judge({ ...base, called: { ...none, rpc: ['other'] }, previousDefined, currentDefined }), [], 'dropped but not called by the app');
});

// Throwaway repository with the layout the script reads: app-compat.json, migrations/*.sql, functions/<name>/.
function fixture() {
  const dir = mkdtempSync(join(tmpdir(), 'app-compat-'));
  const git = (...args) => {
    const run = spawnSync('git', ['-C', dir, '-c', 'user.name=Test', '-c', 'user.email=test@example.test', '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', ...args], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    return run.stdout;
  };
  git('init', '-q', '-b', 'main');
  const write = (path, text) => { mkdirSync(join(dir, path, '..'), { recursive: true }); writeFileSync(join(dir, path), text); };
  const commit = (message) => { git('add', '-A'); git('commit', '-q', '-m', message); };
  return { dir, git, write, commit };
}

function run(repo, called, { minimum, appVersion = '0.6.0', args = ['--previous', 'auto'], env = {} } = {}) {
  if (minimum) repo.write('app-compat.json', JSON.stringify({ minimumClientVersion: minimum }));
  const report = join(repo.dir, '..', `${repo.dir.split('/').pop()}-report.json`);
  writeFileSync(report, JSON.stringify({ rpc: { called: called.rpc ?? [] }, tables: { called: called.tables ?? [] }, edge: { called: called.edge ?? [] } }));
  const appJson = join(repo.dir, '..', `${repo.dir.split('/').pop()}-app.json`);
  writeFileSync(appJson, JSON.stringify({ expo: { version: appVersion } }));
  const result = spawnSync(process.execPath, [script, '--report', report, '--app-json', appJson, '--root', repo.dir, ...args], { encoding: 'utf8', env: { ...process.env, GITHUB_REF_NAME: '', ...env } });
  rmSync(report, { force: true }); rmSync(appJson, { force: true });
  return result;
}

function twoReleases() {
  const repo = fixture();
  repo.write('app-compat.json', '{"minimumClientVersion":"0.6.0"}');
  repo.write('migrations/00000000000001_a.sql', 'CREATE FUNCTION public.restore_customer(p_id uuid) RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\nCREATE FUNCTION public.get_items() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\nCREATE TABLE public.customers (id int);\n');
  repo.write('functions/get-config/index.ts', '');
  repo.commit('first');
  repo.git('tag', 'v1.0.0');
  repo.write('migrations/00000000000002_drop.sql', 'DROP FUNCTION public.restore_customer(uuid);\n');
  repo.commit('drop restore_customer');
  return repo;
}

test('CLI: a function dropped since the previous final tag fails and is named; without the call it passes', () => {
  const repo = twoReleases();
  try {
    const failed = run(repo, { rpc: ['restore_customer', 'get_items'] });
    assert.equal(failed.status, 1, failed.stdout + failed.stderr);
    assert.match(failed.stderr, /R3: The function restore_customer is called by the app at MOBILE_MIN_REF/);
    const passed = run(repo, { rpc: ['get_items'] });
    assert.equal(passed.status, 0, passed.stderr);
    assert.match(passed.stdout, /compared with v1\.0\.0: ok/);
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
});

test('CLI: raising the minimum (with the pin moved) allows the drop; raising it without the pin fails R1', () => {
  const repo = twoReleases();
  try {
    assert.equal(run(repo, { rpc: ['restore_customer'] }, { minimum: '0.7.0', appVersion: '0.7.0' }).status, 0);
    const unmoved = run(repo, { rpc: ['restore_customer'] }, { minimum: '0.7.0', appVersion: '0.6.0' });
    assert.equal(unmoved.status, 1);
    assert.match(unmoved.stderr, /R1:/);
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
});

test('CLI: lowering the minimum fails R2; a table and an edge function dropped fail R3', () => {
  const repo = twoReleases();
  try {
    repo.git('tag', '-d', 'v1.0.0');
    repo.write('app-compat.json', '{"minimumClientVersion":"0.8.0"}');
    repo.git('add', '-A'); repo.git('commit', '-q', '-m', 'second release minimum', '--allow-empty');
    repo.git('tag', 'v1.1.0');
    const lowered = run(repo, {}, { minimum: '0.6.0', appVersion: '0.6.0' });
    assert.equal(lowered.status, 1);
    assert.match(lowered.stderr, /R2: minimumClientVersion 0\.6\.0 is lower than 0\.8\.0 in v1\.1\.0/);
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
  const other = fixture();
  try {
    other.write('app-compat.json', '{"minimumClientVersion":"0.6.0"}');
    other.write('migrations/00000000000001_a.sql', 'CREATE TABLE public.customers (id int);\n');
    other.write('functions/get-config/index.ts', '');
    other.commit('first');
    other.git('tag', 'v1.0.0');
    other.write('migrations/00000000000002_drop.sql', 'DROP TABLE public.customers;\n');
    other.git('rm', '-q', '-r', 'functions/get-config');
    other.commit('drops');
    const result = run(other, { tables: ['customers'], edge: ['get-config'] });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /table customers[\s\S]*edge function get-config/);
  } finally { rmSync(other.dir, { recursive: true, force: true }); }
});

test('CLI: a previous tag without app-compat.json skips R2; no tag skips R2 and R3 unless required', () => {
  const repo = fixture();
  try {
    repo.write('app-compat.json', '{"minimumClientVersion":"0.6.0"}');
    repo.write('migrations/00000000000001_a.sql', 'CREATE FUNCTION public.get_items() RETURNS void LANGUAGE sql AS $$ SELECT 1 $$;\n');
    repo.git('add', 'migrations'); repo.git('commit', '-q', '-m', 'old release without the file');
    repo.git('tag', 'v0.9.0');
    repo.git('add', 'app-compat.json'); repo.git('commit', '-q', '-m', 'add the file');
    const skipped = run(repo, { rpc: ['get_items'] });
    assert.equal(skipped.status, 0, skipped.stderr);
    assert.match(skipped.stdout, /v0\.9\.0 has no app-compat\.json; R2 is skipped/);
    repo.git('tag', '-d', 'v0.9.0');
    const untagged = run(repo, { rpc: ['get_items'] });
    assert.equal(untagged.status, 0, untagged.stderr);
    assert.match(untagged.stdout, /no previous final release tag/);
    const required = run(repo, { rpc: ['get_items'] }, { args: ['--previous', 'auto', '--require-previous'] });
    assert.equal(required.status, 1);
    assert.match(required.stderr, /no previous final release tag/);
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
});

test('previous tag: the newest FINAL tag, never the version being released and never a release candidate', () => {
  const repo = fixture();
  try {
    repo.write('a', '1'); repo.commit('one');
    for (const tag of ['v0.9.0', 'v0.10.0', 'v0.11.0-rc.1', 'v0.11.0-rc.2']) repo.git('tag', tag);
    assert.equal(previousFinalTag(repo.dir, 'v0.11.0-rc.2'), 'v0.10.0', 'natural version order, not text order, and no candidate');
    repo.git('tag', 'v0.11.0');
    assert.equal(previousFinalTag(repo.dir, 'v0.11.0'), 'v0.10.0', 'the final tag does not compare with itself');
    assert.equal(previousFinalTag(repo.dir, ''), 'v0.11.0', 'outside a tag run the newest final tag counts');
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
});

test('CLI: usage and unreadable inputs are refused', () => {
  assert.equal(spawnSync(process.execPath, [script], { encoding: 'utf8' }).status, 2);
  const repo = twoReleases();
  try {
    const bad = spawnSync(process.execPath, [script, '--report', join(repo.dir, 'nope.json'), '--app-json', join(repo.dir, 'nope.json'), '--root', repo.dir], { encoding: 'utf8' });
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /cannot read the contract report/);
  } finally { rmSync(repo.dir, { recursive: true, force: true }); }
});
