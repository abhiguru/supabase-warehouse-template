// Browser lifecycle, admission and the job queue.
//
// A request is admitted BEFORE its body is read: it gets an entry in the queue, and the server reads the body only
// when the entry is granted a slot (`entry.started`). Until then the body stays unread on the socket (TCP backpressure),
// so waiting requests cost no memory. A slot is granted only while the browser is up.
//
// States: starting -> up <-> restarting (planned) ; up -> crashed -> (relaunch) -> up ; shutdown.
// There is never more than one transition (planned restart or crash relaunch) at a time.

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
   * @param {(engine:object) => Promise<number|null>} [opts.chromeMemory]  the browser's own process-tree memory
   * @param {() => Promise<number|null>} [opts.containerMemory]  the container's cgroup memory
   * @param {(event:string, fields?:object) => void} opts.log
   * @param {(code:number) => void} [opts.exit]
   */
  constructor({ config, launch, chromeMemory, containerMemory, log, exit = (code) => process.exit(code) }) {
    this.config = config;
    this.launchEngine = launch;
    this.chromeMemory = chromeMemory || ((engine) => engine.memoryBytes());
    this.containerMemory = containerMemory || (() => readCgroupMemory());
    this.log = log;
    this.exit = exit;

    this.engine = null;
    this.state = 'starting';
    this.queue = [];
    this.running = new Set();
    this.inflightBytes = 0;
    this.jobsSinceLaunch = 0;
    this.jobsTotal = 0;
    this.restarts = 0;
    this.launchCounter = 0;
    this.launchFailures = 0;
    this.crashStreak = 0;
    this.probeFailures = 0;
    this.chromeBytes = 0;
    this.containerBytes = 0;
    this.version = null;
    this.launchedAt = 0;
    this.firstRenderDone = false;
    this.stopping = false;
    this.transition = null;
    this.timers = [];
    this.fatal = false;
  }

  // ---- start and stop -------------------------------------------------------------------------

  async start() {
    await fs.mkdir(this.config.profilesDir, { recursive: true });
    await fs.mkdir(this.config.jobsDir, { recursive: true });
    this.timers.push(setInterval(() => this.#probe(), this.config.probeIntervalMs));
    this.timers.push(setInterval(() => this.#watchdog(), this.config.watchdogIntervalMs));
    for (const t of this.timers) t.unref();
    await this.#launchWithRetry('boot');
  }

  async shutdown() {
    this.stopping = true;
    this.log('shutdown_begin', { queued: this.queue.length, running: this.running.size });
    const deadline = Date.now() + this.config.shutdownMs;
    while ((this.queue.length || this.running.size) && Date.now() < deadline) await sleep(20);
    for (const entry of [...this.queue]) this.#removeQueued(entry, new HttpError(503, 'shutting down'));
    for (const entry of [...this.running]) this.#failRunning(entry, new HttpError(503, 'shutting down'));
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
    if (this.transition) await this.transition.catch(() => {});
    const engine = this.engine;
    this.engine = null;
    if (engine) await this.#retire(engine, 'close');
    this.log('shutdown_done');
  }

  // ---- admission ------------------------------------------------------------------------------

  /**
   * Admit a request before its body is read.
   * @param {number|null} declaredBytes  Content-Length, or null when unknown (treated as a large body)
   * @returns {{error: HttpError} | {entry: object}}
   */
  admit(declaredBytes, { id, arrivedAt = Date.now(), clientSignal = null } = {}) {
    if (this.stopping) return { error: new HttpError(503, 'shutting down') };
    if (this.state === 'crashed' && this.launchFailures > 0) return { error: new HttpError(503, 'browser unavailable') };
    if (this.queue.length >= this.config.maxQueue) return { error: new HttpError(503, 'queue full') };
    const bytes = declaredBytes === null || declaredBytes === undefined ? this.config.soloBodyBytes : declaredBytes;
    if (this.inflightBytes + bytes > this.config.maxQueueBytes) return { error: new HttpError(503, 'too many bytes in flight') };

    const entry = {
      id,
      bytes,
      big: bytes >= this.config.soloBodyBytes,
      arrivedAt,
      deadlineAt: arrivedAt + this.config.deadlineMs,
      queuedAt: Date.now(),
      grantedAt: 0,
      startedAt: 0,
      state: 'queued', // queued -> reading -> rendering
      ac: new AbortController(),
      settled: false,
      released: false,
      timers: [],
      cleanups: [],
      engine: null,
      cold: false,
      errMessage: null,
    };
    entry.started = new Promise((resolve, reject) => { entry.grant = resolve; entry.refuse = reject; });
    entry.result = new Promise((resolve, reject) => { entry.resolve = resolve; entry.reject = reject; });
    entry.started.catch(() => {});
    entry.result.catch(() => {});
    entry.signal = entry.ac.signal;
    /** Server side: the body is read and parsed; start the render. Resolves with { pdf, pages }. */
    entry.run = (job) => this.#run(entry, job);
    /** Server side: the request is rejected after the slot was granted (bad input, client gone). */
    entry.fail = (err) => { if (entry.state === 'reading') this.#failRunning(entry, err); };

    this.inflightBytes += bytes;
    this.queue.push(entry);
    entry.timers.push(setTimeout(() => this.#onDeadline(entry), Math.max(0, entry.deadlineAt - Date.now())));
    // Only when the browser cannot be started at all: a healthy restart or drain waits as long as the job's deadline.
    entry.timers.push(setTimeout(() => {
      if (!entry.settled && entry.state === 'queued' && this.state === 'crashed' && this.launchFailures > 0) {
        this.#removeQueued(entry, new HttpError(503, 'browser unavailable too long'));
      }
    }, this.config.restartWaitMs));
    if (clientSignal) {
      const onGone = () => this.#onClientGone(entry);
      if (clientSignal.aborted) queueMicrotask(onGone);
      else clientSignal.addEventListener('abort', onGone, { once: true });
      entry.cleanups.push(() => clientSignal.removeEventListener('abort', onGone));
    }
    this.#pump();
    return { entry };
  }

  // ---- queue ----------------------------------------------------------------------------------

  #pump() {
    while (this.state === 'up' && this.engine && !this.engine.retiring && this.queue.length) {
      const head = this.queue[0];
      if (this.running.size >= this.config.concurrency) return;
      if (this.running.size > 0) {
        if (head.big || [...this.running].some((e) => e.big)) return;
        // Container guard: do not start reading another body while the container is close to its memory limit.
        if (this.containerBytes >= this.config.containerGuardBytes) return;
        // Solo rule by memory: no second concurrent job while the browser already holds a lot.
        if (this.chromeBytes >= this.config.secondJobChromeBytes) return;
      }
      this.queue.shift();
      head.state = 'reading';
      head.engine = this.engine;
      head.grantedAt = Date.now();
      this.running.add(head);
      head.grant();
    }
  }

  #run(entry, job) {
    if (entry.settled || entry.state !== 'reading') return entry.result;
    const engine = entry.engine;
    entry.state = 'rendering';
    entry.startedAt = Date.now();
    entry.cold = !this.firstRenderDone;
    this.firstRenderDone = true;
    const payload = { id: entry.id, html: job.html, header: job.header, footer: job.footer, params: job.params };
    job.html = null;
    Promise.resolve()
      .then(() => engine.render(payload, { signal: entry.ac.signal, deadlineAt: entry.deadlineAt }))
      .then(
        (result) => this.#onRendered(entry, result, null),
        (err) => this.#onRendered(entry, null, err),
      );
    return entry.result;
  }

  async #onRendered(entry, result, err) {
    if (entry.released) return; // already answered and freed (crash, shutdown)
    if (err && err.crash) this.#engineDown(entry.engine, `target crash: ${safeMessage(err)}`);
    if (entry.released) return;

    this.jobsTotal += 1;
    if (entry.engine === this.engine && !entry.engine.retiring) this.jobsSinceLaunch += 1;

    if (!entry.settled) {
      let outcome;
      if (result) {
        outcome = isValidPdf(result.pdf) ? result : new HttpError(500, 'renderer produced an invalid PDF');
      } else if (entry.ac.signal.aborted) {
        outcome = entry.ac.signal.reason === 'client' ? 'dropped' : new HttpError(504, 'deadline exceeded');
      } else if (entry.engine !== this.engine || entry.engine.retiring) {
        outcome = new HttpError(503, 'browser restarted');
      } else {
        entry.errMessage = safeMessage(err);
        outcome = new HttpError(500, 'render failed');
      }
      if (outcome && outcome.pdf) this.crashStreak = 0;
      this.#settle(entry, outcome); // the client is answered now; the page is cleaned up before the slot is freed
    }
    if (result && result.cleanup) await withTimeout(Promise.resolve(result.cleanup()).catch(() => {}), 8000);
    this.#release(entry);
    this.#afterJob().catch((e) => this.log('after_job_error', { reason: safeMessage(e) }));
  }

  /** Answer the client (once). Frees the entry's bytes; the slot is freed separately by #release. */
  #settle(entry, outcome) {
    if (entry.settled) return;
    entry.settled = true;
    this.#cleanupEntry(entry);
    this.inflightBytes -= entry.bytes;
    const now = Date.now();
    const queueMs = (entry.grantedAt || now) - entry.queuedAt;
    const renderMs = entry.startedAt ? now - entry.startedAt : 0;
    const base = { id: entry.id, bytes: entry.bytes, queueMs, renderMs };
    if (outcome === 'dropped') {
      this.log('job', { ...base, pages: 0, outcome: 'dropped', code: 0 });
      const err = Object.assign(new Error('client gone'), { dropped: true });
      entry.refuse(err);
      entry.reject(err);
    } else if (outcome instanceof Error) {
      const code = outcome.status || 500;
      this.log('job', { ...base, pages: 0, outcome: 'error', code, reason: entry.errMessage || (code === 400 ? 'invalid input' : outcome.message) });
      entry.refuse(outcome);
      entry.reject(outcome);
    } else {
      this.log('job', { ...base, pages: outcome.pages, outcome: 'ok', code: 200, ...(entry.cold ? { cold: true } : {}) });
      entry.resolve({ pdf: outcome.pdf, pages: outcome.pages, queueMs, renderMs });
    }
  }

  #release(entry) {
    if (entry.released) return;
    entry.released = true;
    this.running.delete(entry);
    clearTimeout(entry.graceTimer);
    this.#pump();
  }

  #cleanupEntry(entry) {
    for (const t of entry.timers) clearTimeout(t);
    for (const fn of entry.cleanups) fn();
    entry.timers = [];
    entry.cleanups = [];
  }

  #removeQueued(entry, outcome) {
    const i = this.queue.indexOf(entry);
    if (i >= 0) this.queue.splice(i, 1);
    entry.released = true;
    this.#settle(entry, outcome);
  }

  /** The entry was granted a slot but has no live render (or the browser is gone): answer and free the slot now. */
  #failRunning(entry, outcome) {
    if (entry.released) return;
    entry.ac.abort(outcome === 'dropped' ? 'client' : 'failed');
    this.#settle(entry, outcome);
    this.#release(entry);
  }

  #onClientGone(entry) {
    if (entry.settled) return;
    if (entry.state === 'queued') {
      entry.ac.abort('client');
      this.#removeQueued(entry, 'dropped');
    } else if (entry.state === 'reading') {
      this.#failRunning(entry, 'dropped');
    } else {
      // Rendering: close the page; the slot frees when the render settles.
      entry.ac.abort('client');
      this.#settle(entry, 'dropped');
    }
  }

  #onDeadline(entry) {
    if (entry.settled) return;
    const err = new HttpError(504, 'deadline exceeded');
    if (entry.state === 'queued') {
      entry.ac.abort('deadline');
      this.#removeQueued(entry, err);
    } else if (entry.state === 'reading') {
      this.#failRunning(entry, err);
    } else {
      entry.ac.abort('deadline');
      this.#settle(entry, err);
      // The slot stays taken until the page has closed. If it does not, the browser is killed.
      entry.graceTimer = setTimeout(() => {
        if (!entry.released) {
          this.log('render_stuck', { id: entry.id });
          this.#engineDown(entry.engine, 'page did not close after deadline');
        }
      }, this.config.killGraceMs);
    }
  }

  // ---- after each job: planned restarts ---------------------------------------------------------------

  async #afterJob() {
    if (this.state !== 'up' || this.transition || this.stopping) return;
    let reason = null;
    if (this.jobsSinceLaunch >= this.config.restartAfterJobs) reason = `jobs=${this.jobsSinceLaunch}`;
    if (!reason) {
      const engine = this.engine;
      const used = await this.#readChrome(engine);
      if (used !== null && this.engine === engine && used >= this.config.restartMemoryBytes) reason = `memory=${Math.round(used / 1048576)}MB`;
    }
    if (reason && this.state === 'up' && !this.transition && !this.stopping) this.#plannedRestart(reason);
  }

  async #readChrome(engine) {
    try {
      const used = await this.chromeMemory(engine);
      if (used !== null && used !== undefined) this.chromeBytes = used;
      return used ?? null;
    } catch {
      return null;
    }
  }

  #plannedRestart(reason) {
    this.state = 'restarting';
    this.log('restart_begin', { reason, running: this.running.size, queued: this.queue.length });
    const old = this.engine;
    this.transition = (async () => {
      const cap = this.config.deadlineMs + this.config.drainExtraMs;
      const start = Date.now();
      while (this.running.size && Date.now() - start < cap) await sleep(10);
      if (this.running.size) {
        this.log('drain_timeout', { running: this.running.size });
        for (const entry of [...this.running]) this.#failRunning(entry, new HttpError(503, 'browser restarted'));
        await this.#retire(old, 'kill');
      } else {
        await this.#retire(old, 'close');
      }
      this.restarts += 1;
      if (!this.stopping) await this.#launchWithRetry('planned restart');
    })().catch((err) => this.log('transition_error', { reason: safeMessage(err) }))
      .finally(() => { this.transition = null; this.#pump(); });
  }

  // ---- crash handling ---------------------------------------------------------------------------

  /** Called by an engine (disconnect, process exit) or by the supervisor (watchdog, probes, stuck page). */
  #engineDown(engine, reason) {
    if (!engine || engine.retiring) return;
    engine.retiring = true;
    this.log('browser_down', { reason, running: this.running.size });
    // Running jobs fail with 503; queued jobs wait for the relaunched browser.
    for (const entry of [...this.running]) {
      if (entry.engine === engine) this.#failRunning(entry, new HttpError(503, 'browser crashed'));
    }
    if (this.stopping) {
      this.state = 'crashed';
      for (const entry of [...this.queue]) this.#removeQueued(entry, new HttpError(503, 'shutting down'));
      this.#retire(engine, 'kill');
      return;
    }
    if (this.transition) {
      // A restart is already in progress and will launch the one replacement; just make sure this browser is gone.
      this.#retire(engine, 'kill');
      return;
    }
    this.restarts += 1;
    this.state = 'crashed';
    if (Date.now() - this.launchedAt > 30000) this.crashStreak = 0;
    this.crashStreak += 1;
    this.transition = (async () => {
      await this.#retire(engine, 'kill');
      // The first crash relaunches at once; a repeat waits 1, 2, 4, 8 s.
      await this.#launchWithRetry('crash', this.crashStreak <= 1 ? 0 : this.#backoff(this.crashStreak - 1));
    })().catch((err) => this.log('transition_error', { reason: safeMessage(err) }))
      .finally(() => { this.transition = null; this.#pump(); });
  }

  #retire(engine, how) {
    engine.retiring = true;
    if (!engine.retirePromise) {
      engine.retirePromise = (async () => {
        try {
          if (how === 'close') await withTimeout(engine.close(), this.config.closeTimeoutMs + 3000);
          await withTimeout(engine.kill(), 8000);
        } catch (err) {
          this.log('retire_error', { reason: safeMessage(err) });
        }
        if (engine.profileDir) await fs.rm(engine.profileDir, { recursive: true, force: true }).catch(() => {});
      })();
    }
    return engine.retirePromise;
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
        this.log('launch_backoff', { delayMs: delay, launchFailures: this.launchFailures, crashStreak: this.crashStreak });
        await sleep(delay);
      }
      if (this.stopping && reason !== 'boot') return;
      const launchId = `${++this.launchCounter}-${randomBytes(3).toString('hex')}`;
      const profileDir = path.join(this.config.profilesDir, launchId);
      const t0 = Date.now();
      try {
        await fs.mkdir(profileDir, { recursive: true });
        const engine = await this.launchEngine({ launchId, profileDir, config: this.config });
        engine.profileDir = profileDir;
        engine.retiring = false;
        engine.onDown = (why) => this.#engineDown(engine, why);
        // Backstop: never leave a live browser behind when replacing it.
        const previous = this.engine;
        if (previous && previous !== engine && !previous.retiring) this.#retire(previous, 'kill');
        this.engine = engine;
        this.version = engine.version;
        this.jobsSinceLaunch = 0;
        this.probeFailures = 0;
        this.launchedAt = Date.now();
        this.firstRenderDone = false; // 'cold' is per browser launch
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
          this.fatal = true;
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
    if (this.state !== 'up' || !engine || engine.retiring || this.transition) return;
    let ok = false;
    try {
      const r = await withTimeout(engine.probe(), this.config.probeTimeoutMs);
      ok = r !== 'timeout';
    } catch { ok = false; }
    if (engine !== this.engine || engine.retiring || this.state !== 'up') return;
    if (ok) { this.probeFailures = 0; return; }
    this.probeFailures += 1;
    this.log('probe_failed', { count: this.probeFailures });
    // Health reports down from the second failure; the browser is killed only if it stays unresponsive.
    if (this.probeFailures >= this.config.probeKillAfter) this.#engineDown(engine, `${this.probeFailures} failed health probes`);
  }

  async #watchdog() {
    const container = await Promise.resolve(this.containerMemory()).catch(() => null);
    if (container !== null && container !== undefined) {
      this.containerBytes = container;
    }
    const engine = this.engine;
    if (!engine || engine.retiring || this.running.size === 0) return;
    const used = await this.#readChrome(engine);
    this.#pump(); // the guards above may have cleared
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
      memoryMB: Math.round(this.chromeBytes / 1048576),
      containerMB: Math.round(this.containerBytes / 1048576),
    };
    if (this.stopping || this.fatal) return { status: 503, body: { status: 'down', chromium } };
    if (this.state === 'restarting' || this.state === 'starting') return { status: 200, body: { status: 'restarting', chromium } };
    if (this.state === 'crashed' || this.probeFailures >= 2) {
      // A crash that is relaunching straight away is a restart; failed launches or probes are down.
      if (this.launchFailures > 0 || this.crashStreak > 1 || this.probeFailures >= 2) return { status: 503, body: { status: 'down', chromium } };
      return { status: 200, body: { status: 'restarting', chromium } };
    }
    return { status: 200, body: { status: 'up', chromium } };
  }

  whenIdle() {
    return new Promise((resolve) => {
      const check = () => (this.queue.length === 0 && this.running.size === 0 ? resolve() : setTimeout(check, 10));
      check();
    });
  }
}
