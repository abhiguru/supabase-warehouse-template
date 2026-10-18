// Browser lifecycle, admission and the job queue.
//
// States: starting -> up <-> restarting (planned) ; up -> crashed -> (relaunch) -> up ; stopping.
// Jobs wait in a FIFO queue; at most `concurrency` run at once, and a body of soloBodyBytes or more runs alone.

import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { isValidPdf } from './render.mjs';
import { safeMessage } from './log.mjs';

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function withTimeout(promise, ms) {
  let timer;
  const timeout = new Promise((resolve) => { timer = setTimeout(() => resolve('timeout'), ms); });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

export async function readCgroupMemory(root = '/sys/fs/cgroup') {
  try {
    const current = Number((await fs.readFile(path.join(root, 'memory.current'), 'utf8')).trim());
    const stat = await fs.readFile(path.join(root, 'memory.stat'), 'utf8');
    const match = /^inactive_file (\d+)$/m.exec(stat);
    const inactive = match ? Number(match[1]) : 0;
    if (!Number.isFinite(current)) return null;
    return Math.max(0, current - inactive);
  } catch {
    return null;
  }
}

export class Supervisor {
  /**
   * @param {object} opts
   * @param {object} opts.config
   * @param {(args:{launchId:string, profileDir:string, config:object}) => Promise<object>} opts.launch
   * @param {(engine:object) => Promise<number|null>} [opts.memoryReader]  bytes in use, or null when unknown
   * @param {(event:string, fields?:object) => void} opts.log
   * @param {(code:number) => void} [opts.exit]
   */
  constructor({ config, launch, memoryReader, log, exit = (code) => process.exit(code) }) {
    this.config = config;
    this.launchEngine = launch;
    this.memoryReader = memoryReader || (async (engine) => (await readCgroupMemory()) ?? (await engine.memoryBytes()));
    this.log = log;
    this.exit = exit;

    this.engine = null;
    this.state = 'starting';
    this.queue = [];
    this.running = new Set();
    this.readingCount = 0;
    this.inflightBytes = 0;
    this.jobsSinceLaunch = 0;
    this.jobsTotal = 0;
    this.restarts = 0;
    this.launchCounter = 0;
    this.launchFailures = 0;
    this.crashStreak = 0;
    this.probeFailures = 0;
    this.memoryBytes = 0;
    this.version = null;
    this.launchedAt = 0;
    this.firstRenderDone = false;
    this.stopping = false;
    this.transition = null;
    this.timers = [];
    this.idleWaiters = [];
  }

  // ---- start and stop -------------------------------------------------------------------------

  async start() {
    await fs.mkdir(this.config.profilesDir, { recursive: true });
    await fs.mkdir(this.config.jobsDir, { recursive: true });
    await this.#launchWithRetry('boot');
    this.timers.push(setInterval(() => this.#probe(), this.config.probeIntervalMs));
    this.timers.push(setInterval(() => this.#watchdog(), this.config.watchdogIntervalMs));
    for (const t of this.timers) t.unref();
  }

  async shutdown() {
    this.stopping = true;
    this.log('shutdown_begin', { queued: this.queue.length, running: this.running.size });
    const deadline = Date.now() + this.config.shutdownMs;
    while ((this.queue.length || this.running.size || this.readingCount) && Date.now() < deadline) {
      await sleep(20);
    }
    for (const job of [...this.queue]) this.#removeQueued(job, new HttpError(503, 'shutting down'));
    for (const job of [...this.running]) this.#settle(job, new HttpError(503, 'shutting down'));
    this.running.clear();
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    const engine = this.engine;
    this.engine = null;
    if (engine) await this.#retire(engine, 'close');
    this.log('shutdown_done');
  }

  // ---- admission ------------------------------------------------------------------------------

  /** Reserve room for a request before its body is read. Returns a reservation, or an HttpError to send. */
  reserve(declaredBytes) {
    if (this.stopping) return { error: new HttpError(503, 'shutting down') };
    if (this.state === 'crashed' && this.launchFailures > 0) return { error: new HttpError(503, 'browser unavailable') };
    if (this.queue.length + this.readingCount >= this.config.maxQueue) return { error: new HttpError(503, 'queue full') };
    if (this.inflightBytes + declaredBytes > this.config.maxQueueBytes) return { error: new HttpError(503, 'too many bytes in flight') };
    this.readingCount += 1;
    this.inflightBytes += declaredBytes;
    let bytes = declaredBytes;
    let released = false;
    const reservation = {
      get bytes() { return bytes; },
      /** Count more bytes than declared. Returns an error when the request must be refused. */
      grow: (total) => {
        if (total <= bytes) return null;
        const extra = total - bytes;
        if (this.inflightBytes + extra > this.config.maxQueueBytes) return new HttpError(503, 'too many bytes in flight');
        this.inflightBytes += extra;
        bytes = total;
        return null;
      },
      release: () => {
        if (released) return;
        released = true;
        this.readingCount -= 1;
        this.inflightBytes -= bytes;
        this.#checkIdle();
      },
      /** The body is read; the bytes now belong to the job. */
      handOver: () => {
        if (released) return bytes;
        released = true;
        this.readingCount -= 1;
        return bytes;
      },
    };
    return { reservation };
  }

  // ---- jobs -----------------------------------------------------------------------------------

  /**
   * @param {object} reservation  from reserve()
   * @param {object} job  { id, html, header, footer, params, arrivedAt, clientSignal }
   * @returns {Promise<{pdf:Buffer, pages:number, queueMs:number, renderMs:number}>}
   */
  submit(reservation, job) {
    const bytes = reservation.handOver();
    return new Promise((resolve, reject) => {
      const entry = {
        id: job.id,
        job,
        bytes,
        big: bytes >= this.config.soloBodyBytes,
        arrivedAt: job.arrivedAt,
        deadlineAt: job.arrivedAt + this.config.deadlineMs,
        queuedAt: Date.now(),
        startedAt: 0,
        ac: new AbortController(),
        resolve,
        reject,
        settled: false,
        timers: [],
        cleanups: [],
        engine: null,
        renderPromise: null,
      };
      if (this.stopping && !this.engine) {
        this.inflightBytes -= bytes;
        reject(new HttpError(503, 'shutting down'));
        return;
      }
      this.queue.push(entry);

      const untilDeadline = Math.max(0, entry.deadlineAt - Date.now());
      entry.timers.push(setTimeout(() => this.#onDeadline(entry), untilDeadline));
      entry.timers.push(setTimeout(() => {
        if (!entry.settled && this.queue.includes(entry) && this.state !== 'up') {
          this.#removeQueued(entry, new HttpError(503, 'browser unavailable too long'));
        }
      }, this.config.restartWaitMs));
      if (job.clientSignal) {
        const onGone = () => this.#onClientGone(entry);
        if (job.clientSignal.aborted) queueMicrotask(onGone);
        else job.clientSignal.addEventListener('abort', onGone, { once: true });
        entry.cleanups.push(() => job.clientSignal.removeEventListener('abort', onGone));
      }
      this.#pump();
    });
  }

  #pump() {
    while (this.state === 'up' && this.queue.length) {
      const head = this.queue[0];
      if (this.running.size >= this.config.concurrency) return;
      if (this.running.size > 0 && (head.big || [...this.running].some((j) => j.big))) return;
      this.queue.shift();
      this.#start(head);
    }
  }

  #start(entry) {
    const engine = this.engine;
    entry.engine = engine;
    entry.startedAt = Date.now();
    this.running.add(entry);
    const cold = !this.firstRenderDone;
    this.firstRenderDone = true;
    entry.cold = cold;
    const payload = { id: entry.id, html: entry.job.html, header: entry.job.header, footer: entry.job.footer, params: entry.job.params };
    entry.renderPromise = Promise.resolve()
      .then(() => engine.render(payload, { signal: entry.ac.signal, deadlineAt: entry.deadlineAt }))
      .then(
        (result) => this.#onRendered(entry, result, null),
        (err) => this.#onRendered(entry, null, err),
      );
  }

  #onRendered(entry, result, err) {
    this.running.delete(entry);
    let outcome;
    if (entry.settled) {
      outcome = null; // already answered (deadline, crash)
    } else if (result) {
      if (!isValidPdf(result.pdf)) {
        outcome = new HttpError(500, 'renderer produced an invalid PDF');
      } else {
        outcome = result;
      }
    } else if (err && err.crash) {
      outcome = new HttpError(503, 'browser crashed');
      this.#engineDown(entry.engine, `target crash: ${safeMessage(err)}`);
    } else if (entry.ac.signal.aborted) {
      outcome = entry.ac.signal.reason === 'client' ? 'dropped' : new HttpError(504, 'deadline exceeded');
    } else if (entry.engine !== this.engine || entry.engine.retiring) {
      outcome = new HttpError(503, 'browser restarted');
    } else {
      outcome = new HttpError(500, 'render failed');
      entry.errMessage = safeMessage(err);
    }

    if (outcome && outcome.pdf) this.crashStreak = 0;
    if (!entry.settled) {
      this.jobsSinceLaunch += 1;
      this.jobsTotal += 1;
    }
    if (outcome) this.#settle(entry, outcome);
    else this.#cleanupEntry(entry);
    this.#afterJob().catch((err) => this.log('after_job_error', { reason: safeMessage(err) }));
  }

  #settle(entry, outcome) {
    if (entry.settled) return;
    entry.settled = true;
    this.#cleanupEntry(entry);
    this.inflightBytes -= entry.bytes;
    const now = Date.now();
    const queueMs = (entry.startedAt || now) - entry.queuedAt;
    const renderMs = entry.startedAt ? now - entry.startedAt : 0;
    const base = { id: entry.id, bytes: entry.bytes, queueMs, renderMs };
    if (outcome === 'dropped') {
      this.log('job', { ...base, pages: 0, outcome: 'dropped', code: 0 });
      entry.reject(Object.assign(new Error('client gone'), { dropped: true }));
    } else if (outcome instanceof Error) {
      const code = outcome.status || 500;
      this.log('job', { ...base, pages: 0, outcome: 'error', code, ...(entry.errMessage ? { reason: entry.errMessage } : { reason: outcome.message }) });
      entry.reject(outcome);
    } else {
      this.log('job', { ...base, pages: outcome.pages, outcome: 'ok', code: 200, ...(entry.cold ? { cold: true } : {}) });
      entry.resolve({ pdf: outcome.pdf, pages: outcome.pages, queueMs, renderMs });
    }
    this.#checkIdle();
  }

  #cleanupEntry(entry) {
    for (const t of entry.timers) clearTimeout(t);
    for (const fn of entry.cleanups) fn();
    entry.timers = [];
    entry.cleanups = [];
    clearTimeout(entry.graceTimer);
  }

  #removeQueued(entry, outcome) {
    const i = this.queue.indexOf(entry);
    if (i >= 0) this.queue.splice(i, 1);
    this.#settle(entry, outcome);
  }

  #onClientGone(entry) {
    if (entry.settled) return;
    entry.ac.abort('client');
    if (this.queue.includes(entry)) this.#removeQueued(entry, 'dropped');
    else this.#settle(entry, 'dropped'); // running: the page closes; the slot frees when render settles
  }

  #onDeadline(entry) {
    if (entry.settled) return;
    entry.ac.abort('deadline');
    if (this.queue.includes(entry)) {
      this.#removeQueued(entry, new HttpError(504, 'deadline exceeded'));
      return;
    }
    this.#settle(entry, new HttpError(504, 'deadline exceeded'));
    // The slot stays taken until the page has closed. If it does not, the browser is killed.
    entry.graceTimer = setTimeout(() => {
      if (this.running.has(entry)) {
        this.log('render_stuck', { id: entry.id });
        this.#engineDown(entry.engine, 'page did not close after deadline');
      }
    }, this.config.killGraceMs);
  }

  // ---- after each job: planned restarts -----------------------------------------------------------

  async #afterJob() {
    this.#pump();
    this.#checkIdle();
    if (this.state !== 'up' || this.transition || this.stopping) return;
    let reason = null;
    if (this.jobsSinceLaunch >= this.config.restartAfterJobs) reason = `jobs=${this.jobsSinceLaunch}`;
    if (!reason) {
      const engine = this.engine;
      const used = await this.#readMemory(engine);
      if (used !== null && this.engine === engine && used >= this.config.restartMemoryBytes) reason = `memory=${Math.round(used / 1048576)}MB`;
    }
    if (reason && this.state === 'up' && !this.transition) this.#plannedRestart(reason);
  }

  async #readMemory(engine) {
    try {
      const used = await this.memoryReader(engine);
      if (used !== null && used !== undefined) this.memoryBytes = used;
      return used ?? null;
    } catch {
      return null;
    }
  }

  #plannedRestart(reason) {
    this.state = 'restarting';
    this.log('restart_begin', { reason, running: this.running.size, queued: this.queue.length });
    this.transition = (async () => {
      const old = this.engine;
      const drainCap = this.config.deadlineMs + this.config.drainExtraMs;
      const start = Date.now();
      while (this.running.size && Date.now() - start < drainCap) await sleep(10);
      if (this.running.size) {
        this.log('drain_timeout', { running: this.running.size });
        for (const entry of [...this.running]) this.#settle(entry, new HttpError(503, 'browser restarted'));
        this.running.clear();
        old.retiring = true;
        await this.#retire(old, 'kill');
      } else {
        await this.#retire(old, 'close');
      }
      this.restarts += 1;
      if (!this.stopping) await this.#launchWithRetry('planned restart');
    })().finally(() => { this.transition = null; this.#pump(); });
  }

  // ---- crash handling ---------------------------------------------------------------------------

  /** Called by an engine (disconnect, process exit) or by the supervisor (watchdog, probes, stuck page). */
  #engineDown(engine, reason) {
    if (!engine || engine !== this.engine || engine.retiring) return;
    engine.retiring = true;
    this.log('browser_down', { reason, running: this.running.size });
    this.restarts += 1;
    if (this.stopping) { this.state = 'crashed'; return; }
    this.state = 'crashed';
    if (Date.now() - this.launchedAt > 30000) this.crashStreak = 0;
    this.crashStreak += 1;
    const err = () => new HttpError(503, 'browser crashed');
    for (const entry of [...this.running]) this.#settle(entry, err());
    this.running.clear();
    for (const entry of [...this.queue]) this.#removeQueued(entry, err());
    this.transition = (async () => {
      await this.#retire(engine, 'kill');
      if (this.crashStreak >= this.config.maxLaunchFailures) {
        this.log('fatal', { reason: 'too many crashes in a row', streak: this.crashStreak });
        this.exit(1);
        return;
      }
      // The first crash relaunches at once; a repeat waits 1, 2, 4, 8 s.
      const wait = this.crashStreak <= 1 ? 0 : this.#backoff(this.crashStreak - 1);
      await this.#launchWithRetry('crash', wait);
    })().finally(() => { this.transition = null; this.#pump(); });
  }

  async #retire(engine, how) {
    engine.retiring = true;
    try {
      if (how === 'close') await withTimeout(engine.close(), this.config.closeTimeoutMs + 3000);
      await withTimeout(engine.kill(), 8000);
    } catch (err) {
      this.log('retire_error', { reason: safeMessage(err) });
    }
    if (engine.profileDir) await fs.rm(engine.profileDir, { recursive: true, force: true }).catch(() => {});
  }

  #backoff(n) {
    const list = this.config.launchBackoffMs;
    return list[Math.min(n - 1, list.length - 1)];
  }

  async #launchWithRetry(reason, firstDelay = 0) {
    let delay = firstDelay;
    for (;;) {
      if (this.stopping && reason !== 'boot') return;
      if (delay) {
        this.log('launch_backoff', { delayMs: delay, streak: this.launchFailures + this.crashStreak });
        await sleep(delay);
      }
      const launchId = `${++this.launchCounter}-${randomBytes(3).toString('hex')}`;
      const profileDir = path.join(this.config.profilesDir, launchId);
      const t0 = Date.now();
      let engine = null;
      try {
        await fs.mkdir(profileDir, { recursive: true });
        engine = await this.launchEngine({ launchId, profileDir, config: this.config });
        engine.profileDir = profileDir;
        engine.retiring = false;
        engine.onDown = (why) => this.#engineDown(engine, why);
        this.engine = engine;
        this.version = engine.version;
        this.jobsSinceLaunch = 0;
        this.probeFailures = 0;
        this.launchedAt = Date.now();
        this.launchFailures = 0;
        this.state = 'up';
        this.log('launch', { reason, launchId, pid: engine.pid ?? null, version: engine.version, ms: Date.now() - t0 });
        this.#pump();
        return;
      } catch (err) {
        this.launchFailures += 1;
        this.state = 'crashed';
        this.log('launch_failed', { reason: safeMessage(err), streak: this.launchFailures });
        await fs.rm(profileDir, { recursive: true, force: true }).catch(() => {});
        if (this.launchFailures >= this.config.maxLaunchFailures) {
          this.log('fatal', { reason: 'browser would not start', streak: this.launchFailures });
          for (const entry of [...this.queue]) this.#removeQueued(entry, new HttpError(503, 'browser unavailable'));
          this.exit(1);
          return;
        }
        delay = this.#backoff(this.launchFailures);
      }
    }
  }

  // ---- background checks ---------------------------------------------------------------------------

  async #probe() {
    const engine = this.engine;
    if (this.state !== 'up' || !engine || this.transition) return;
    let ok = false;
    try {
      const r = await withTimeout(engine.probe(), this.config.probeTimeoutMs);
      ok = r !== 'timeout';
    } catch { ok = false; }
    if (engine !== this.engine || this.state !== 'up') return;
    if (ok) { this.probeFailures = 0; return; }
    this.probeFailures += 1;
    if (this.probeFailures >= 2) this.#engineDown(engine, 'two failed health probes');
  }

  async #watchdog() {
    const engine = this.engine;
    if (!engine || engine.retiring || this.running.size === 0) return;
    const used = await this.#readMemory(engine);
    if (used !== null && engine === this.engine && !engine.retiring && this.running.size > 0 && used >= this.config.killMemoryBytes) {
      this.log('watchdog_kill', { memoryMB: Math.round(used / 1048576) });
      this.#engineDown(engine, 'memory watchdog');
    }
  }

  // ---- health ------------------------------------------------------------------------------------

  health() {
    const chromium = {
      version: this.version,
      jobs: this.jobsTotal,
      restarts: this.restarts,
      queue: this.queue.length,
      inflightBytes: this.inflightBytes,
      memoryMB: Math.round(this.memoryBytes / 1048576),
    };
    if (this.stopping) return { status: 503, body: { status: 'down', chromium } };
    if (this.state === 'restarting' || this.state === 'starting') return { status: 200, body: { status: 'restarting', chromium } };
    if (this.state === 'crashed' || this.probeFailures >= 2) {
      // A crash that is relaunching straight away is a restart; failed launches or probes are down.
      if (this.launchFailures > 0 || this.crashStreak > 1 || this.probeFailures >= 2) return { status: 503, body: { status: 'down', chromium } };
      return { status: 200, body: { status: 'restarting', chromium } };
    }
    return { status: 200, body: { status: 'up', chromium } };
  }

  // ---- idle helper ---------------------------------------------------------------------------------

  #checkIdle() {
    if (this.queue.length === 0 && this.running.size === 0 && this.readingCount === 0) {
      const waiters = this.idleWaiters;
      this.idleWaiters = [];
      for (const w of waiters) w();
    }
  }

  whenIdle() {
    return new Promise((resolve) => {
      if (this.queue.length === 0 && this.running.size === 0 && this.readingCount === 0) resolve();
      else this.idleWaiters.push(resolve);
    });
  }
}
