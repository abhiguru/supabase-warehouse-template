#!/usr/bin/env node
// CI helper (the `repeat` job of .github/workflows/ci.yml): decides whether a push to main repeats code that its pull request's CI run
// already tested in full, so the long jobs can be skipped on main.
//
//   node scripts/ci-skip-repeat.mjs
//
// It answers `skip=true` only when ALL of these hold, and `skip=false` (the full suite runs) on anything else, including every error:
//   1. the pushed commit is the merge commit of exactly one merged pull request into main (a squash merge);
//   2. that pull request's newest CI run (event pull_request, on the pull request's last head commit) is completed, and the newest attempt
//      of EVERY job in it concluded success, except jobs skipped by their own condition; `validate`, `operator-install` and
//      `operator-upgrade` must be successes (never skipped); cancelled, timed_out, action_required, failure and the like mean a full run;
//   3. the tree that run tested (recorded by its `validate` job as a "Tested tree" annotation) is present, readable and identical to the
//      tree of the pushed commit.
// It never exits non-zero, and a failure to decide is a full run. The release gate (scripts/check-release-ci.mjs) is untouched: it asks for
// `operator-install` and `operator-upgrade` to have succeeded on the exact commit, which a skipped main run does not produce.
//
// Environment: GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_EVENT_NAME, GITHUB_REF, GITHUB_OUTPUT, GITHUB_API_URL (optional), GH_TOKEN.
import { appendFileSync } from 'node:fs';
import { isMain } from './is-main.mjs';

export const TREE_TITLE = 'Tested tree';
export const TREE_MESSAGE = /^tree ([0-9a-f]{40}|[0-9a-f]{64})$/;
export const MUST_SUCCEED = ['validate', 'Isolated operator installation', 'Upgrade from the previous release'];
const TIMEOUT_MS = 10_000;
const PER_PAGE = 100;
const MAX_PAGES = 10;

class Unsure extends Error {}

async function get(fetchImpl, base, path, token) {
  const headers = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'ci-skip-repeat' };
  if (token) headers.Authorization = `Bearer ${token}`;
  let response;
  try {
    response = await fetchImpl(`${base.replace(/\/+$/, '')}${path}`, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (error) {
    throw new Unsure(`the GitHub API could not be reached (${error?.message ?? error})`);
  }
  if (!response.ok) throw new Unsure(`the GitHub API answered ${response.status} for ${path.split('?')[0]}`);
  try {
    return await response.json();
  } catch {
    throw new Unsure('the GitHub API answer is not JSON');
  }
}

async function getAll(fetchImpl, base, path, token, key) {
  const items = [];
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const body = await get(fetchImpl, base, `${path}${path.includes('?') ? '&' : '?'}per_page=${PER_PAGE}&page=${page}`, token);
    const list = key ? body?.[key] : body;
    if (!Array.isArray(list)) throw new Unsure(`the answer for ${path.split('?')[0]} has no list`);
    items.push(...list);
    if (list.length < PER_PAGE) return items;
  }
  throw new Unsure(`more than ${MAX_PAGES * PER_PAGE} entries for ${path.split('?')[0]}`);
}

// Resolves to { skip: true, notice } or { skip: false, reason }. Never throws.
export async function decide({ env = process.env, fetchImpl = fetch } = {}) {
  try {
    if (env.GITHUB_EVENT_NAME !== 'push' || env.GITHUB_REF !== 'refs/heads/main') return { skip: false, reason: 'not a push to main' };
    const repo = env.GITHUB_REPOSITORY;
    const sha = env.GITHUB_SHA;
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo ?? '') || !/^[0-9a-f]{40}$/.test(sha ?? '')) throw new Unsure('GITHUB_REPOSITORY or GITHUB_SHA is not set');
    const api = env.GITHUB_API_URL || 'https://api.github.com';
    const token = env.GH_TOKEN || env.GITHUB_TOKEN || '';
    const call = (path, key) => getAll(fetchImpl, api, path, token, key);

    const pulls = (await call(`/repos/${repo}/commits/${sha}/pulls`)).filter(pr => pr?.merged_at && pr.merge_commit_sha === sha && pr.base?.ref === 'main');
    if (pulls.length !== 1) throw new Unsure(`${pulls.length} merged pull requests have this commit as their merge commit (one is required)`);
    const pr = pulls[0];
    const head = pr.head?.sha;
    if (!/^[0-9a-f]{40}$/.test(head ?? '')) throw new Unsure(`pull request #${pr.number} has no head commit`);

    const runs = (await call(`/repos/${repo}/actions/workflows/ci.yml/runs?event=pull_request&head_sha=${head}`, 'workflow_runs')).filter(r => r.event === 'pull_request' && r.head_sha === head);
    if (runs.length === 0) throw new Unsure(`pull request #${pr.number} has no CI run on ${head.slice(0, 12)}`);
    const newest = runs.reduce((a, b) => (Number(b.id) > Number(a.id) ? b : a));
    if (newest.status !== 'completed') throw new Unsure(`CI run ${newest.id} of pull request #${pr.number} is ${newest.status}`);

    // filter=latest: the newest attempt of each job decides.
    const jobs = await call(`/repos/${repo}/actions/runs/${newest.id}/jobs?filter=latest`, 'jobs');
    if (jobs.length === 0) throw new Unsure(`CI run ${newest.id} has no jobs`);
    for (const job of jobs) {
      const fine = job.status === 'completed' && (job.conclusion === 'success' || (job.conclusion === 'skipped' && !MUST_SUCCEED.includes(job.name)));
      if (!fine) throw new Unsure(`job "${job.name}" of CI run ${newest.id} is ${job.status}/${job.conclusion}`);
    }
    for (const name of MUST_SUCCEED) {
      const found = jobs.filter(job => job.name === name);
      if (found.length !== 1 || found[0].conclusion !== 'success') throw new Unsure(`CI run ${newest.id} has no single successful "${name}"`);
    }

    const validate = jobs.find(job => job.name === 'validate');
    const trees = new Set((await call(`/repos/${repo}/check-runs/${validate.id}/annotations`))
      .filter(a => a?.title === TREE_TITLE && TREE_MESSAGE.test(a.message ?? '')).map(a => a.message.match(TREE_MESSAGE)[1]));
    if (trees.size !== 1) throw new Unsure(`CI run ${newest.id} did not record exactly one readable tested tree`);
    const [tested] = trees;

    const commit = await get(fetchImpl, api, `/repos/${repo}/git/commits/${sha}`, token);
    const pushed = commit?.tree?.sha;
    if (!/^[0-9a-f]{40,64}$/.test(pushed ?? '')) throw new Unsure('the pushed commit has no tree');
    if (pushed !== tested) return { skip: false, reason: `the pushed tree ${pushed} differs from the tree ${tested} that CI run ${newest.id} of pull request #${pr.number} tested` };

    return { skip: true, notice: `Skipping the long jobs: this push repeats pull request #${pr.number}, whose CI run ${newest.id} passed in full on tree ${pushed}. Run CI by hand (workflow_dispatch) before tagging this commit.` };
  } catch (error) {
    return { skip: false, reason: error instanceof Unsure ? error.message : `unexpected error: ${error?.message ?? error}` };
  }
}

export async function main({ env = process.env, fetchImpl = fetch, log = console.log } = {}) {
  const result = await decide({ env, fetchImpl });
  if (result.skip) log(`::notice title=Repeat run skipped::${result.notice}`);
  else log(`Full suite runs: ${result.reason}.`);
  if (env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT, `skip=${result.skip}\n`);
  return result;
}

if (isMain(import.meta.url)) await main().catch(() => {});
