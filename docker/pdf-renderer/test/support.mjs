// Shared helpers: a fake browser layer, a test server and request builders. No Chrome needed.

import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { loadConfig } from '../src/config.mjs';
import { createLogger } from '../src/log.mjs';
import { Supervisor } from '../src/supervisor.mjs';
import { createServer } from '../src/server.mjs';

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function waitFor(fn, ms = 3000, what = 'condition') {
  const start = Date.now();
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() - start > ms) throw new Error(`timed out waiting for ${what}`);
    await sleep(10);
  }
}

export function fakePdf(pages = 1, size = 0) {
  let body = '%PDF-1.4\n';
  for (let i = 0; i < pages; i += 1) body += `${i + 3} 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n`;
  body += '2 0 obj\n<< /Type /Pages /Count 1 >>\nendobj\n';
  if (size > body.length) body += '%'.repeat(size - body.length - 8) + '\n';
  return Buffer.from(`${body}%%EOF\n`, 'latin1');
}

export class FakeEngine {
  constructor(id, profileDir, behavior) {
    this.id = id;
    this.pid = 1000 + id;
    this.version = 'FakeChrome/1.0';
    this.profileDir = null;
    this.behavior = behavior;
    this.rendered = [];
    this.active = 0;
    this.closed = false;
    this.killed = false;
    this.onDown = null;
    this.exited = new Promise((resolve) => { this.markExited = resolve; });
    this.pendingRejects = new Set();
    fsSync.writeFileSync(path.join(profileDir, 'Preferences'), '{}');
  }

  async render(job, { signal }) {
    this.rendered.push(job.id);
    this.active += 1;
    this.behavior.active += 1;
    this.behavior.maxActive = Math.max(this.behavior.maxActive, this.behavior.active);
    this.behavior.started.push({ id: job.id, bytes: job.html.length, activeAtStart: this.behavior.active });
    try {
      return await new Promise((resolve, reject) => {
        const fail = (err) => reject(err);
        this.pendingRejects.add(fail);
        const onAbort = () => reject(Object.assign(new Error('page closed'), { name: 'AbortedError' }));
        if (!this.behavior.ignoreAbort) signal.addEventListener('abort', onAbort, { once: true });
        Promise.resolve(this.behavior.render(job, this, signal)).then(resolve, reject).finally(() => {
          this.pendingRejects.delete(fail);
          signal.removeEventListener('abort', onAbort);
        });
      });
    } finally {
      this.active -= 1;
      this.behavior.active -= 1;
    }
  }

  async probe() { return this.behavior.probe(this); }
  async memoryBytes() { return null; }
  async close() { this.closed = true; this.markExited(); }
  async kill() { this.killed = true; this.markExited(); }

  /** Simulate the browser dying: running renders reject, onDown fires. */
  crash(reason = 'crash') {
    for (const fail of this.pendingRejects) fail(new Error('Target closed'));
    this.markExited();
    if (this.onDown) this.onDown(reason);
  }
}

export function makeBehavior(overrides = {}) {
  return {
    active: 0,
    maxActive: 0,
    started: [],
    launches: 0,
    launchDelayMs: 0,
    failLaunches: 0, // fail this many launches (Infinity: all)
    engines: [],
    render: async () => ({ pdf: fakePdf(2), pages: 2 }),
    probe: async () => 'FakeChrome/1.0',
    ...overrides,
  };
}

export function makeLauncher(behavior) {
  return async ({ launchId, profileDir }) => {
    behavior.launches += 1;
    if (behavior.launchDelayMs) await sleep(behavior.launchDelayMs);
    if (behavior.failLaunches > 0) {
      behavior.failLaunches -= 1;
      throw new Error('cannot start fake browser');
    }
    const engine = new FakeEngine(behavior.launches, profileDir, behavior);
    behavior.engines.push(engine);
    return engine;
  };
}

export async function startService({ config: configOverrides = {}, behavior: behaviorOverrides = {}, memoryReader, containerMemory } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pdfr-test-'));
  const config = loadConfig({}, {
    port: 0,
    host: '127.0.0.1',
    profilesDir: path.join(dir, 'profiles'),
    jobsDir: path.join(dir, 'jobs'),
    deadlineMs: 5000,
    probeIntervalMs: 50,
    probeTimeoutMs: 200,
    watchdogIntervalMs: 20,
    launchBackoffMs: [10, 20, 40, 80],
    shutdownMs: 1000,
    closeTimeoutMs: 200,
    killGraceMs: 100,
    restartWaitMs: 2000,
    ...configOverrides,
  });
  const lines = [];
  const log = createLogger((line) => lines.push(line));
  const behavior = makeBehavior(behaviorOverrides);
  const exits = [];
  const supervisor = new Supervisor({
    config,
    launch: makeLauncher(behavior),
    chromeMemory: memoryReader || (async () => 100 * 1024 * 1024),
    containerMemory: containerMemory || (async () => 100 * 1024 * 1024),
    log,
    exit: (code) => exits.push(code),
  });
  const server = createServer({ supervisor, config, log });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  await supervisor.start();
  const service = {
    dir, config, lines, behavior, supervisor, server, url, exits,
    events: () => lines.map((l) => JSON.parse(l)),
    jobLogs: () => service.events().filter((e) => e.event === 'job'),
    async listDir(name) {
      try { return await fs.readdir(path.join(dir, name)); } catch { return []; }
    },
    async stop() {
      await supervisor.shutdown();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await fs.rm(dir, { recursive: true, force: true });
    },
  };
  return service;
}

export function formBody({ html = '<html><body>hello</body></html>', header, footer, fields = {}, files } = {}) {
  const form = new FormData();
  if (files) {
    for (const [name, content] of files) form.append('files', new Blob([content], { type: 'text/html' }), name);
  } else {
    form.append('files', new Blob([html], { type: 'text/html' }), 'index.html');
    if (header !== undefined) form.append('files', new Blob([header], { type: 'text/html' }), 'header.html');
    if (footer !== undefined) form.append('files', new Blob([footer], { type: 'text/html' }), 'footer.html');
  }
  for (const [key, value] of Object.entries(fields)) form.append(key, String(value));
  return form;
}

export async function render(service, options = {}, init = {}) {
  const res = await fetch(`${service.url}/render`, { method: 'POST', body: formBody(options), ...init });
  const body = Buffer.from(await res.arrayBuffer());
  return { status: res.status, headers: res.headers, body, json: () => JSON.parse(body.toString('utf8')) };
}

/** A raw HTTP request, for control over Content-Length and chunking. */
export function rawRequest(service, { headers = {}, body = null, chunks = null, path: reqPath = '/render' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(`${service.url}${reqPath}`, { method: 'POST', headers }, (res) => {
      const parts = [];
      res.on('data', (c) => parts.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(parts).toString('utf8') }));
    });
    req.on('error', reject);
    if (chunks) {
      (async () => { for (const c of chunks) { if (!req.write(c)) await new Promise((r) => req.once('drain', r)); } req.end(); })().catch(() => {});
    } else {
      if (body) req.write(body);
      req.end();
    }
  });
}
