#!/usr/bin/env node
// Release gate: end-to-end CI must have passed on the commit that is being tagged.
//
// Branch protection on main requires only validate, contract and migrations. operator-install and operator-upgrade are the only jobs that
// install and upgrade a real stack, and they are not required checks (they are long and run on one runner), so a tag could be pushed on a
// commit whose end-to-end run failed or never ran. release.yml runs this script first in the release job.
//
//   node scripts/check-release-ci.mjs [check-run name ...]
//
// The names are the check runs' names (the `name:` of the jobs in ci.yml); the default is the two below. For each name the newest run on
// GITHUB_SHA must be completed with the conclusion success. A missing, queued, running, failed, cancelled or skipped run fails the gate.
// A final tag on the commit of its release candidate asks about the same commit, so the same runs count.
//
// It never waits and never polls: the release job may share one runner with those jobs, and waiting for them would deadlock.
//
// Only a check run created by GitHub Actions counts (another app can post a check run with the same name). A job that skips itself with a
// notice (the upgrade drill when no starting point exists) still ends as a success, and counts.
//
// Environment: GITHUB_REPOSITORY (owner/name), GITHUB_SHA, GITHUB_API_URL (default https://api.github.com), GH_TOKEN or GITHUB_TOKEN
// (optional), GITHUB_REF_NAME (when set, the tag must name GITHUB_SHA). With a token the API is asked with it first; when that answers 401,
// 403 or 404 the same request is repeated without a token, which a public repository answers. A failure of both fails the gate, with the
// message and x-ratelimit-remaining of the last answer.
import { execFileSync } from 'node:child_process';
import { isMain } from './is-main.mjs';

export const REQUIRED_CHECKS = ['Isolated operator installation', 'Upgrade from the previous release'];
const TIMEOUT_MS = 10_000;
const PER_PAGE = 100;
const MAX_PAGES = 30;
const RETRY_ANONYMOUSLY = new Set([401, 403, 404]);

class GateError extends Error {}

async function getPage(fetchImpl, url, token) {
  const headers = { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'check-release-ci' };
  if (token) headers.Authorization = `Bearer ${token}`;
  let response;
  try {
    response = await fetchImpl(url, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (error) {
    throw new GateError(`the GitHub API could not be reached (${error?.name === 'TimeoutError' ? 'timed out after 10 s' : error?.message ?? error})`);
  }
  if (!response.ok) {
    let message = '';
    try { message = String((await response.json())?.message ?? ''); } catch { /* no body */ }
    const remaining = response.headers?.get?.('x-ratelimit-remaining');
    const failure = new GateError(`the GitHub API answered ${response.status}${message ? ` "${message.slice(0, 200)}"` : ''}${remaining != null ? ` (x-ratelimit-remaining ${remaining})` : ''}`);
    failure.status = response.status;
    throw failure;
  }
  try {
    return await response.json();
  } catch {
    throw new GateError('the GitHub API answer is not JSON');
  }
}

async function getPageWithFallback(fetchImpl, url, state) {
  if (state.token) {
    try {
      return await getPage(fetchImpl, url, state.token);
    } catch (error) {
      if (!RETRY_ANONYMOUSLY.has(error.status)) throw error;
      state.token = '';
    }
  }
  return getPage(fetchImpl, url, '');
}

export async function listCheckRuns({ fetchImpl = fetch, apiUrl = 'https://api.github.com', repository, sha, token = '', name, state = { token } }) {
  const runs = [];
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const url = `${apiUrl.replace(/\/+$/, '')}/repos/${repository}/commits/${sha}/check-runs?check_name=${encodeURIComponent(name)}&filter=latest&per_page=${PER_PAGE}&page=${page}`;
    const body = await getPageWithFallback(fetchImpl, url, state);
    if (!body || !Array.isArray(body.check_runs)) throw new GateError('the GitHub API answer has no check_runs list');
    runs.push(...body.check_runs);
    if (body.check_runs.length === 0 || runs.length >= Number(body.total_count ?? 0)) return runs;
  }
  throw new GateError(`more than ${MAX_PAGES * PER_PAGE} check runs on the commit`);
}

const stamp = run => Date.parse(run.completed_at || run.started_at || '') || 0;

// Pure: the problems found in `runs` for the required names (an empty list means the gate passes).
export function judge(runs, required = REQUIRED_CHECKS) {
  const problems = [];
  for (const name of required) {
    const same = runs.filter(run => run.name === name && run.app?.slug === 'github-actions');
    if (same.length === 0) { problems.push(`${name}: no run on this commit`); continue; }
    const newest = same.reduce((a, b) => (stamp(b) > stamp(a) ? b : a));
    if (newest.status !== 'completed') problems.push(`${name}: ${newest.status ?? 'unknown status'}, not finished`);
    else if (newest.conclusion !== 'success') problems.push(`${name}: ${newest.conclusion ?? 'no conclusion'}`);
  }
  return problems;
}

function gitResolveTag(name) {
  try {
    return execFileSync('git', ['rev-parse', '--verify', '--quiet', `refs/tags/${name}^{commit}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
}

export async function run({ env = process.env, argv = [], fetchImpl = fetch, log = console.log, resolveTag = gitResolveTag } = {}) {
  const repository = env.GITHUB_REPOSITORY;
  const sha = env.GITHUB_SHA;
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? '') || !/^[0-9a-f]{40}$/.test(sha ?? '')) {
    log('::error title=Release gate: CI::GITHUB_REPOSITORY (owner/name) and GITHUB_SHA (40 hex digits) must be set.');
    return 1;
  }
  const required = argv.length ? argv : REQUIRED_CHECKS;
  const where = `commit ${sha.slice(0, 12)} of ${repository}`;
  try {
    if (env.GITHUB_REF_NAME) {
      const tagged = resolveTag(env.GITHUB_REF_NAME);
      if (tagged !== sha) throw new GateError(`the tag ${env.GITHUB_REF_NAME} names ${tagged || 'no commit'}, not the commit this run was started on (${sha})`);
    }
    const runs = [];
    const state = { token: env.GH_TOKEN || env.GITHUB_TOKEN || '' };
    for (const name of required) {
      runs.push(...await listCheckRuns({ fetchImpl, apiUrl: env.GITHUB_API_URL || 'https://api.github.com', repository, sha, name, state }));
    }
    const problems = judge(runs, required);
    if (problems.length) {
      log(`::error title=Release gate: CI::End-to-end CI has not passed on ${where}: ${problems.join('; ')}. Wait for CI on this commit (the push to main, or Actions > CI > the run of this commit > Re-run jobs), re-run the failed job, then re-run this workflow.`);
      return 1;
    }
    log(`CI passed on ${where}: ${required.join(', ')}.`);
    return 0;
  } catch (error) {
    if (!(error instanceof GateError)) throw error;
    log(`::error title=Release gate: CI::Could not verify CI on ${where}: ${error.message}. The gate fails closed; re-run this workflow once the API answers.`);
    return 1;
  }
}

if (isMain(import.meta.url)) process.exitCode = await run({ argv: process.argv.slice(2) });
