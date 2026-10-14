// When the print monitor (print-status-monitor.ts) records how a print job ended.
//
// PRINT3 (review 2026-10-13): the monitor recorded a job CUPS no longer listed
// as completed after seven polls, a job still queued after twelve as failed, and
// its loop (5 s, then 12 polls 5 s apart) outlived the router's 60 s worker. Now
// only a final state CUPS reports finishes a job (9 completed, 7 cancelled,
// 8 aborted = failed). A job CUPS no longer lists, or one still running when the
// time is up, is recorded as 'unknown' with a note and no completion time: its
// paper may or may not have come out, and it is never resubmitted on a guess.
// This module imports nothing so that the node tests can load it directly.
//
// The submission and the monitor share one worker, which the router stops at
// 60 s (workerTimeoutMs, functions/main/index.ts). The Print-Job submission is
// given up after SUBMIT_TIMEOUT_MS (an unanswered submission is unconfirmed,
// recorded as 'unknown' and never resubmitted), so the worst case is
//   submit           8 s  (SUBMIT_TIMEOUT_MS)
// + monitor budget  35 s  (no query starts later; the initial delay is inside it)
// + last observation 9 s  (3 queries x 2 s timeout + 1 s + 2 s backoff)
// = 52 s, which leaves 8 s of the 60 s for the database reads before the
// submission and the print_jobs row written after it. printWorstCaseMs computes
// this from the constants and tests/print-monitor.test.mjs holds it under 60 s.

export const MONITOR_LIMITS = {
  initialDelayMs: 2000,
  pollIntervalMs: 5000,
  // No query starts after this much time from the start of the monitor.
  budgetMs: 35000,
  // One observation: up to this many queries, each given up after the timeout, with these pauses between them.
  queryAttempts: 3,
  requestTimeoutMs: 2000,
  retryBackoffMs: [1000, 2000],
} as const;

export type MonitorLimits = {
  initialDelayMs: number;
  pollIntervalMs: number;
  budgetMs: number;
  queryAttempts: number;
  requestTimeoutMs: number;
  retryBackoffMs: readonly number[];
};

export type Observation = { kind: 'state'; state: unknown } | { kind: 'missing' } | { kind: 'error' };
export type MonitorStep =
  | { action: 'wait'; delayMs: number }
  | { action: 'finish'; status: 'completed' | 'cancelled' | 'failed' | 'unknown'; completedAt: boolean; note?: string };

function finalStatus(state: unknown): 'completed' | 'cancelled' | 'failed' | null {
  if (state === 9 || state === 'completed') return 'completed';
  if (state === 7 || state === 'canceled' || state === 'cancelled') return 'cancelled';
  if (state === 8 || state === 'aborted') return 'failed';
  return null;
}

export function nextMonitorStep(
  { observation, elapsedMs }: { observation: Observation | Record<string, unknown>; elapsedMs: number },
  limits: MonitorLimits = MONITOR_LIMITS,
): MonitorStep {
  if (observation?.kind === 'state') {
    const status = finalStatus((observation as { state: unknown }).state);
    if (status) return { action: 'finish', status, completedAt: true };
  }
  if (observation?.kind === 'missing') {
    return { action: 'finish', status: 'unknown', completedAt: false,
      note: 'CUPS no longer lists the job; its outcome was not confirmed. Check the printer.' };
  }
  // A job still queued or printing, an error or a reply without a usable state: look again if there is time.
  if (elapsedMs + limits.pollIntervalMs > limits.budgetMs) {
    return { action: 'finish', status: 'unknown', completedAt: false,
      note: `No final state from CUPS within ${limits.budgetMs / 1000} s; the outcome was not confirmed. Check the printer.` };
  }
  return { action: 'wait', delayMs: limits.pollIntervalMs };
}

// The longest the monitor can run: the last query starts by the budget and may
// take every attempt to its timeout, with the pauses between them.
export function monitorWorstCaseMs(limits: MonitorLimits = MONITOR_LIMITS): number {
  return limits.budgetMs + limits.queryAttempts * limits.requestTimeoutMs
    + limits.retryBackoffMs.slice(0, limits.queryAttempts - 1).reduce((sum, ms) => sum + ms, 0);
}

// The Print-Job submission is given up after this long (see the arithmetic above).
export const SUBMIT_TIMEOUT_MS = 8000;

// The longest a print request's worker runs after the print data is ready: the
// submission up to its timeout, then the monitor's worst case.
export function printWorstCaseMs(limits: MonitorLimits = MONITOR_LIMITS, submitTimeoutMs: number = SUBMIT_TIMEOUT_MS): number {
  return submitTimeoutMs + monitorWorstCaseMs(limits);
}

// Submit a print job with a request timeout. The submission gets an AbortSignal
// that fires at the timeout; a reply that has not come by then (or comes later)
// counts as no reply (null), which the caller records as an unconfirmed job
// ('unknown', never resubmitted). An error the submission raises in time is
// raised again.
export async function submitWithTimeout<T>(
  submit: (signal: AbortSignal) => Promise<T>,
  timeoutMs: number = SUBMIT_TIMEOUT_MS,
): Promise<T | null> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      submit(controller.signal),
      new Promise<null>(resolve => {
        timer = setTimeout(() => {
          controller.abort(new Error(`The printer did not answer the submission within ${timeoutMs / 1000} s`));
          resolve(null);
        }, timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

// One observation: the query is retried on an error or an unusable reply, each
// attempt bounded by the request timeout. A missing job or a state is final.
export async function observeJob(
  query: () => Promise<Observation>,
  sleep: (ms: number) => Promise<void>,
  limits: MonitorLimits = MONITOR_LIMITS,
): Promise<Observation> {
  for (let attempt = 1; ; attempt++) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    let observation: Observation;
    try {
      observation = await Promise.race([
        query(),
        new Promise<Observation>(resolve => { timer = setTimeout(() => resolve({ kind: 'error' }), limits.requestTimeoutMs); }),
      ]);
    } catch {
      observation = { kind: 'error' };
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
    if (observation?.kind !== 'error' || attempt >= limits.queryAttempts) return observation ?? { kind: 'error' };
    await sleep(limits.retryBackoffMs[attempt - 1] ?? 0);
  }
}

// The monitor loop, with its clock, sleep, query and database update passed in.
export async function runMonitor(
  deps: {
    now: () => number;
    sleep: (ms: number) => Promise<void>;
    observe: () => Promise<Observation>;
    update: (step: Extract<MonitorStep, { action: 'finish' }>) => Promise<void>;
  },
  limits: MonitorLimits = MONITOR_LIMITS,
): Promise<void> {
  const start = deps.now();
  await deps.sleep(limits.initialDelayMs);
  for (;;) {
    const observation = await deps.observe();
    const step = nextMonitorStep({ observation, elapsedMs: deps.now() - start }, limits);
    if (step.action === 'finish') {
      await deps.update(step);
      return;
    }
    await deps.sleep(step.delayMs);
  }
}
