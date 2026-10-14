import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MONITOR_LIMITS, SUBMIT_TIMEOUT_MS, nextMonitorStep, monitorWorstCaseMs, observeJob, printWorstCaseMs, runMonitor, submitWithTimeout } from '../functions/_shared/print-monitor-rule.ts';

// PRINT3 (review 2026-10-13): the print monitor marked a job CUPS no longer listed
// as completed after seven polls, and a job still queued after twelve as failed,
// and its nominal loop (5 s + 12 x 5 s) outlived the 60 s worker. Only a state
// CUPS reports as final now finishes a job; a job that disappears, or that is
// still running when the time is up, is recorded as unknown.
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const workerTimeoutMs = Number(/workerTimeoutMs:\s*(\d+)/.exec(read('functions/main/index.ts'))?.[1]);

test('only a final CUPS state finishes a job', () => {
  for (const [state, status] of [[9, 'completed'], [7, 'cancelled'], [8, 'failed'], ['completed', 'completed'], ['canceled', 'cancelled'], ['aborted', 'failed']]) {
    assert.deepEqual(nextMonitorStep({ observation: { kind: 'state', state }, elapsedMs: 3000 }), { action: 'finish', status, completedAt: true }, String(state));
  }
  for (const observation of [{ kind: 'state', state: 3 }, { kind: 'state', state: 4 }, { kind: 'state', state: 5 }, { kind: 'state', state: 6 },
    { kind: 'state', state: 'processing' }, { kind: 'state', state: null }, { kind: 'state', state: 42 }, { kind: 'error' }, {}]) {
    assert.deepEqual(nextMonitorStep({ observation, elapsedMs: 10000 }), { action: 'wait', delayMs: MONITOR_LIMITS.pollIntervalMs }, JSON.stringify(observation));
  }
});

test('a job CUPS no longer lists is unknown, not completed', () => {
  for (const elapsedMs of [2000, 40000]) {
    const step = nextMonitorStep({ observation: { kind: 'missing' }, elapsedMs });
    assert.equal(step.action, 'finish');
    assert.equal(step.status, 'unknown');
    assert.equal(step.completedAt, false);
    assert.match(step.note, /no longer lists/);
  }
});

test('a job still running when the time is up is unknown, not failed', () => {
  const last = MONITOR_LIMITS.budgetMs - MONITOR_LIMITS.pollIntervalMs;
  assert.equal(nextMonitorStep({ observation: { kind: 'state', state: 5 }, elapsedMs: last }).action, 'wait');
  for (const observation of [{ kind: 'state', state: 5 }, { kind: 'error' }]) {
    const step = nextMonitorStep({ observation, elapsedMs: last + 1 });
    assert.deepEqual([step.action, step.status, step.completedAt], ['finish', 'unknown', false]);
    assert.match(step.note, /35 s/);
  }
});

test('the limits fit the worker lifetime', () => {
  assert.deepEqual([MONITOR_LIMITS.initialDelayMs, MONITOR_LIMITS.pollIntervalMs, MONITOR_LIMITS.budgetMs], [2000, 5000, 35000]);
  assert.equal(workerTimeoutMs, 60000);
  // The last query starts by the budget; it may then take every attempt, each up to its timeout, and the backoff between them.
  assert.equal(monitorWorstCaseMs(MONITOR_LIMITS), MONITOR_LIMITS.budgetMs
    + MONITOR_LIMITS.queryAttempts * MONITOR_LIMITS.requestTimeoutMs + MONITOR_LIMITS.retryBackoffMs.reduce((a, b) => a + b, 0));
  assert.ok(monitorWorstCaseMs(MONITOR_LIMITS) < workerTimeoutMs, `${monitorWorstCaseMs(MONITOR_LIMITS)} ms must be under ${workerTimeoutMs} ms`);
});

// Follow-up review 2026-10-13: the Print-Job submission had no timeout, so a slow
// submission plus the monitor (then 54 s) could outlive the 60 s worker.
test('the submission and the monitor together fit the worker lifetime', () => {
  const backoff = MONITOR_LIMITS.retryBackoffMs.slice(0, MONITOR_LIMITS.queryAttempts - 1).reduce((a, b) => a + b, 0);
  const worst = SUBMIT_TIMEOUT_MS + MONITOR_LIMITS.budgetMs + MONITOR_LIMITS.queryAttempts * MONITOR_LIMITS.requestTimeoutMs + backoff;
  assert.equal(SUBMIT_TIMEOUT_MS, 8000);
  assert.equal(printWorstCaseMs(), worst);
  assert.equal(worst, 52000);
  assert.ok(worst < workerTimeoutMs, `submission ${SUBMIT_TIMEOUT_MS} ms + monitor ${worst - SUBMIT_TIMEOUT_MS} ms = ${worst} ms must be under ${workerTimeoutMs} ms`);
  // The rest of the request (database reads before the submission, the print_jobs row after it) keeps some seconds.
  assert.ok(workerTimeoutMs - worst >= 5000, `only ${workerTimeoutMs - worst} ms left for the database work`);
  assert.match(read('functions/_shared/print-monitor-rule.ts'), /= 52 s/, 'the module comment states the arithmetic');
});

test('a submission without a reply in time is unconfirmed, and its late reply is dropped', async () => {
  let seen;
  const late = await submitWithTimeout(signal => { seen = signal; return new Promise(() => {}); }, 20);
  assert.equal(late, null);
  assert.equal(seen.aborted, true);
  assert.match(String(seen.reason?.message), /did not answer the submission within 0.02 s/);
  assert.deepEqual(await submitWithTimeout(async signal => ({ aborted: signal.aborted }), 1000), { aborted: false });
  await assert.rejects(submitWithTimeout(async () => { throw new Error('client-error-not-possible'); }, 1000), /client-error-not-possible/);
});

test('the three preprinted routes bound their submission', () => {
  for (const route of ['print-dispatch-preprinted', 'print-invoice-preprinted', 'print-grn-preprinted']) {
    const source = read(`functions/${route}/index.ts`);
    assert.match(source, /import \{ SUBMIT_TIMEOUT_MS, submitWithTimeout \} from '\.\.\/_shared\/print-monitor-rule\.ts'/, route);
    assert.match(source, /const result: any = await submitWithTimeout\(\(signal\) => new Promise/, route);
    assert.match(source, /if \(signal\.aborted\) \{/, route);
    assert.equal((source.match(/printer\.execute\("Print-Job"/g) ?? []).length, 1, route);
  }
});

// A fake clock: sleeping moves time on; each query takes queryMs.
function simulate(observations, { queryMs = 100 } = {}) {
  let now = 0;
  const updates = [];
  const queries = [];
  const deps = {
    now: () => now,
    sleep: async ms => { now += ms; },
    observe: async () => { queries.push(now); now += queryMs; return observations(queries.length); },
    update: async step => { updates.push({ ...step, at: now }); },
  };
  return { deps, updates, queries, end: () => now };
}

test('the monitor loop: completed when CUPS says so', async () => {
  const run = simulate(n => n < 3 ? { kind: 'state', state: 5 } : { kind: 'state', state: 9 });
  await runMonitor(run.deps);
  assert.deepEqual(run.updates.map(u => [u.status, u.completedAt]), [['completed', true]]);
  assert.equal(run.queries[0], MONITOR_LIMITS.initialDelayMs);
  assert.equal(run.queries.length, 3);
});

test('the monitor loop: a disappeared job and an expired budget end as unknown', async () => {
  const gone = simulate(n => n < 2 ? { kind: 'state', state: 4 } : { kind: 'missing' });
  await runMonitor(gone.deps);
  assert.deepEqual(gone.updates.map(u => [u.status, u.completedAt]), [['unknown', false]]);

  const stuck = simulate(() => ({ kind: 'state', state: 5 }), { queryMs: 1500 });
  await runMonitor(stuck.deps);
  assert.deepEqual(stuck.updates.map(u => [u.status, u.completedAt]), [['unknown', false]]);
  assert.ok(stuck.queries.at(-1) <= MONITOR_LIMITS.budgetMs, `last query at ${stuck.queries.at(-1)} ms`);
  assert.ok(stuck.end() < workerTimeoutMs, `ended at ${stuck.end()} ms`);
});

test('a query is retried with backoff and bounded by its timeout', async () => {
  let now = 0;
  const sleep = async ms => { now += ms; };
  let calls = 0;
  // Two failures, then a reply.
  const observation = await observeJob(async () => { calls += 1; if (calls < 3) throw new Error('socket hang up'); return { kind: 'state', state: 9 }; }, sleep, MONITOR_LIMITS);
  assert.deepEqual(observation, { kind: 'state', state: 9 });
  assert.equal(now, MONITOR_LIMITS.retryBackoffMs[0] + MONITOR_LIMITS.retryBackoffMs[1]);
  // Never answers: each attempt gives up at the timeout (real timers, short limits).
  const quick = { ...MONITOR_LIMITS, queryAttempts: 2, requestTimeoutMs: 20, retryBackoffMs: [5] };
  const started = Date.now();
  assert.deepEqual(await observeJob(() => new Promise(() => {}), ms => new Promise(resolve => setTimeout(resolve, ms)), quick), { kind: 'error' });
  assert.ok(Date.now() - started < 1000);
  // An incomplete reply is retried too; a missing job is not.
  calls = 0;
  assert.deepEqual(await observeJob(async () => { calls += 1; return { kind: 'missing' }; }, sleep, MONITOR_LIMITS), { kind: 'missing' });
  assert.equal(calls, 1);
});

test('the status monitor runs the rule and records unknown without a completion time', () => {
  const monitor = read('functions/_shared/print-status-monitor.ts');
  assert.match(monitor, /import \{[^}]*\brunMonitor\b[^}]*\} from ['"]\.\/print-monitor-rule\.ts['"]/);
  assert.ok(!monitor.includes('assuming completed') && !monitor.includes('attempts > 6') && !monitor.includes('maxAttempts'), 'the old guesses are gone');
  assert.match(monitor, /if \(step\.completedAt\)/, 'completed_at only for a confirmed end');
  const types = read('functions/_shared/ipp-validate.ts');
  assert.match(types, /export type PrintJobStatus = [^;]*'unknown'/);
});
