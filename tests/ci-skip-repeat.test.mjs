import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decide } from '../scripts/ci-skip-repeat.mjs';
import { REQUIRED_CHECKS, judge } from '../scripts/check-release-ci.mjs';

const SHA = 'a'.repeat(40);
const HEAD = 'b'.repeat(40);
const TREE = 'c'.repeat(40);
const env = { GITHUB_EVENT_NAME: 'push', GITHUB_REF: 'refs/heads/main', GITHUB_REPOSITORY: 'o/r', GITHUB_SHA: SHA, GH_TOKEN: 't' };
const reply = body => ({ ok: true, status: 200, json: async () => body });
const job = (name, conclusion = 'success', id = 1) => ({ id, name, status: 'completed', conclusion });
const good = () => ({
  pulls: [{ number: 7, merged_at: 'x', merge_commit_sha: SHA, base: { ref: 'main' }, head: { sha: HEAD } }],
  runs: [{ id: 5, event: 'pull_request', head_sha: HEAD, status: 'completed' }],
  jobs: [job('validate', 'success', 11), job(REQUIRED_CHECKS[0]), job(REQUIRED_CHECKS[1]), job('storage-drill', 'skipped')],
  annotations: [{ title: 'Tested tree', message: `tree ${TREE}` }],
  tree: TREE,
});
const fake = (s, fail) => async url => {
  if (fail?.test(url)) return { ok: false, status: 500, json: async () => ({}) };
  if (url.includes('/pulls?')) return reply(s.pulls);
  if (url.includes('/workflows/ci.yml/runs')) return reply({ workflow_runs: s.runs });
  if (url.includes('/jobs?')) return reply({ jobs: s.jobs });
  if (url.includes('/annotations')) return reply(s.annotations);
  if (url.includes('/git/commits/')) return reply({ tree: { sha: s.tree } });
  throw new Error(`unexpected ${url}`);
};
const go = (s, fail, e = env) => decide({ env: e, fetchImpl: fake(s, fail) });

test('a merged PR whose run passed in full on the same tree skips, with a notice naming PR, run and tree', async () => {
  const r = await go(good());
  assert.equal(r.skip, true);
  assert.match(r.notice, /#7.*run 5.*tree c{40}/);
});

test('trees differ, missing or odd annotation, API error: full run', async () => {
  assert.equal((await go({ ...good(), tree: 'd'.repeat(40) })).skip, false);
  assert.equal((await go({ ...good(), annotations: [] })).skip, false);
  assert.equal((await go({ ...good(), annotations: [{ title: 'Tested tree', message: 'garbage' }] })).skip, false);
  assert.equal((await go({ ...good(), annotations: [{ title: 'Tested tree', message: `tree ${TREE}` }, { title: 'Tested tree', message: `tree ${'e'.repeat(40)}` }] })).skip, false);
  for (const part of [/pulls/, /runs/, /jobs/, /annotations/, /git\/commits/]) assert.equal((await go(good(), part)).skip, false, String(part));
});

test('no PR, two PRs, a PR with another merge commit, no run, running run: full run', async () => {
  assert.equal((await go({ ...good(), pulls: [] })).skip, false);
  const p = good().pulls[0];
  assert.equal((await go({ ...good(), pulls: [p, { ...p, number: 8 }] })).skip, false);
  assert.equal((await go({ ...good(), pulls: [{ ...p, merge_commit_sha: 'f'.repeat(40) }] })).skip, false);
  assert.equal((await go({ ...good(), runs: [] })).skip, false);
  assert.equal((await go({ ...good(), runs: [{ ...good().runs[0], status: 'in_progress' }] })).skip, false);
});

test('every job that ran must have succeeded; only jobs skipped by their own condition are ignored', async () => {
  for (const conclusion of ['failure', 'cancelled', 'timed_out', 'action_required', 'neutral', null]) {
    const s = good();
    s.jobs.push(job('migrations', conclusion));
    assert.equal((await go(s)).skip, false, String(conclusion));
  }
  const queued = good();
  queued.jobs.push({ id: 9, name: 'contract', status: 'queued', conclusion: null });
  assert.equal((await go(queued)).skip, false);
  for (const name of REQUIRED_CHECKS) {
    const s = good();
    s.jobs = s.jobs.map(j => (j.name === name ? job(name, 'skipped') : j));
    assert.equal((await go(s)).skip, false, `${name} skipped`);
    s.jobs = s.jobs.filter(j => j.name !== name);
    assert.equal((await go(s)).skip, false, `${name} absent`);
  }
});

test('other events and refs always run in full, with no request made', async () => {
  for (const e of [{ GITHUB_EVENT_NAME: 'workflow_dispatch' }, { GITHUB_EVENT_NAME: 'schedule' }, { GITHUB_EVENT_NAME: 'pull_request' }, { GITHUB_REF: 'refs/heads/release/1.0' }]) {
    const r = await decide({ env: { ...env, ...e }, fetchImpl: async () => { throw new Error('no request expected'); } });
    assert.equal(r.skip, false);
  }
});

test('a thrown fetch is a full run', async () => {
  assert.equal((await decide({ env, fetchImpl: async () => { throw new Error('down'); } })).skip, false);
});

test('a skipped job never satisfies the release gate', () => {
  const runs = REQUIRED_CHECKS.map(name => ({ name, app: { slug: 'github-actions' }, status: 'completed', conclusion: 'skipped' }));
  assert.equal(judge(runs).length, 2);
  assert.equal(judge([]).length, 2);
});

test('ci.yml: the long jobs wait for repeat with !cancelled(), the cheap required ones do not, and pull requests record the tree', () => {
  const ci = readFileSync(new URL('../.github/workflows/ci.yml', import.meta.url), 'utf8');
  const block = id => ci.slice(ci.indexOf(`\n  ${id}:\n`) + 1).split(/\n  [a-z-]+:\n/)[0];
  for (const id of ['migrations', 'contract', 'operator-install', 'operator-upgrade', 'storage-drill', 'pdf-renderer']) {
    assert.match(block(id), /needs\.repeat\.outputs\.skip != 'true'/, id);
    assert.match(block(id), /!cancelled\(\)/, id);
  }
  for (const id of ['validate', 'secrets', 'migration-order', 'bridge', 'changes']) assert.doesNotMatch(block(id), /needs\.repeat/, id);
  assert.match(block('repeat'), /if: github\.event_name == 'push' && github\.ref == 'refs\/heads\/main'/);
  assert.match(block('validate'), /::notice title=Tested tree::tree /);
});
