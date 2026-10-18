// HTTP front end: POST /render (multipart) and GET /health.

import http from 'node:http';
import { mkdirSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { loadConfig } from './config.mjs';
import { createLogger, safeMessage } from './log.mjs';
import { Supervisor, HttpError } from './supervisor.mjs';

const FILE_NAMES = new Set(['index.html', 'header.html', 'footer.html']);
const FIELD_NAMES = new Set([
  'paperWidth', 'paperHeight', 'marginTop', 'marginRight', 'marginBottom', 'marginLeft',
  'landscape', 'printBackground', 'scale', 'emulatedMediaType', 'preferCssPageSize', 'waitDelay',
]);
const MAX_PAPER_INCHES = 100;

// ---- input parsing ------------------------------------------------------------------------------

function parseNumber(name, raw) {
  const text = raw.trim();
  if (!/^[+-]?(\d+\.?\d*|\.\d+)$/.test(text)) throw new HttpError(400, `${name} must be a number`);
  return Number(text);
}

function parseBool(name, raw) {
  const text = raw.trim().toLowerCase();
  if (text === 'true') return true;
  if (text === 'false') return false;
  throw new HttpError(400, `${name} must be true or false`);
}

/** Turn a parsed FormData into { html, header, footer, params }, or throw HttpError(400). */
export async function parseRenderForm(form) {
  const files = {};
  const fields = {};
  for (const [name, value] of form.entries()) {
    if (typeof value === 'string') {
      if (!FIELD_NAMES.has(name)) throw new HttpError(400, `unknown field ${name}`);
      if (Object.hasOwn(fields, name)) throw new HttpError(400, `duplicate field ${name}`);
      fields[name] = value;
    } else {
      const filename = value.name;
      if (!FILE_NAMES.has(filename)) throw new HttpError(400, `unexpected file ${JSON.stringify(String(filename).slice(0, 40))}`);
      if (Object.hasOwn(files, filename)) throw new HttpError(400, `duplicate file ${filename}`);
      files[filename] = value;
    }
  }
  if (!files['index.html']) throw new HttpError(400, 'index.html is required');

  if (fields.waitDelay !== undefined && !/^0(ms|s)?$/.test(fields.waitDelay.trim())) {
    throw new HttpError(400, 'waitDelay is not supported');
  }

  const hasFooter = Boolean(files['footer.html']);
  const params = {
    paperWidth: 8.27,
    paperHeight: 11.69,
    marginTop: 0.39,
    marginRight: 0.55,
    marginBottom: hasFooter ? 1.0 : 0.55,
    marginLeft: 0.55,
    landscape: false,
    printBackground: true,
    scale: 1,
    emulatedMediaType: 'print',
    preferCssPageSize: true,
  };
  for (const name of ['paperWidth', 'paperHeight', 'marginTop', 'marginRight', 'marginBottom', 'marginLeft', 'scale']) {
    if (fields[name] !== undefined) params[name] = parseNumber(name, fields[name]);
  }
  for (const name of ['landscape', 'printBackground', 'preferCssPageSize']) {
    if (fields[name] !== undefined) params[name] = parseBool(name, fields[name]);
  }
  if (fields.emulatedMediaType !== undefined) {
    const media = fields.emulatedMediaType.trim();
    if (media !== 'print' && media !== 'screen') throw new HttpError(400, 'emulatedMediaType must be print or screen');
    params.emulatedMediaType = media;
  }

  if (params.scale < 0.1 || params.scale > 2) throw new HttpError(400, 'scale must be between 0.1 and 2');
  for (const name of ['paperWidth', 'paperHeight']) {
    if (!(params[name] > 0) || params[name] > MAX_PAPER_INCHES) throw new HttpError(400, `${name} must be positive and at most ${MAX_PAPER_INCHES}`);
  }
  for (const name of ['marginTop', 'marginRight', 'marginBottom', 'marginLeft']) {
    if (params[name] < 0) throw new HttpError(400, `${name} must not be negative`);
  }
  const width = params.landscape ? params.paperHeight : params.paperWidth;
  const height = params.landscape ? params.paperWidth : params.paperHeight;
  if (params.marginLeft + params.marginRight >= width || params.marginTop + params.marginBottom >= height) {
    throw new HttpError(400, 'margins leave no room on the page');
  }

  return {
    html: await files['index.html'].text(),
    header: files['header.html'] ? await files['header.html'].text() : undefined,
    footer: files['footer.html'] ? await files['footer.html'].text() : undefined,
    params,
  };
}

// ---- server -----------------------------------------------------------------------------------------

function sendJson(res, status, error, extraHeaders = {}) {
  const body = JSON.stringify({ error, code: status });
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), ...extraHeaders });
  res.end(body);
}

/** After answering without reading the whole body: drain it for a few seconds, then close, so the client sees the response. */
function drainAndClose(req) {
  req.resume();
  const timer = setTimeout(() => req.destroy(), 5000);
  timer.unref();
  req.once('close', () => clearTimeout(timer));
}

function refuseEarly(req, res, status, message) {
  sendJson(res, status, message, { Connection: 'close' });
  drainAndClose(req);
}

/** Read a request body with a byte counter. Never destroys the request, so an error response can still be sent. */
function readBody(req, limit, onTotal) {
  let cancel;
  const promise = new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let done = false;
    const finish = (fn, value) => {
      if (done) return;
      done = true;
      req.removeListener('data', onData);
      fn(value);
    };
    const onData = (chunk) => {
      total += chunk.length;
      if (total > limit) return finish(reject, new HttpError(413, 'body too large'));
      const refusal = onTotal(total);
      if (refusal) return finish(reject, refusal);
      chunks.push(chunk);
    };
    cancel = (err) => finish(reject, err);
    req.on('data', onData);
    req.once('end', () => finish(resolve, Buffer.concat(chunks, total)));
    req.once('error', (err) => finish(reject, err));
    req.once('close', () => finish(reject, new Error('connection closed')));
  });
  promise.catch(() => {});
  return { promise, cancel: (err) => cancel(err) };
}

export function createServer({ supervisor, config, log }) {
  const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => {
      log('request_error', { reason: safeMessage(err) });
      if (!res.headersSent) sendJson(res, 500, 'internal error');
      else res.destroy();
    });
  });
  server.keepAliveTimeout = config.keepAliveTimeoutMs;
  server.headersTimeout = config.headersTimeoutMs;

  async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/health') {
      if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, 'method not allowed');
      const { status, body } = supervisor.health();
      const text = JSON.stringify(body);
      res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text) });
      return res.end(req.method === 'HEAD' ? undefined : text);
    }
    if (url.pathname !== '/render') return sendJson(res, 404, 'not found');
    if (req.method !== 'POST') return sendJson(res, 405, 'method not allowed', { Allow: 'POST' });
    return handleRender(req, res);
  }

  async function handleRender(req, res) {
    const arrivedAt = Date.now();
    const id = randomBytes(4).toString('hex');

    const contentType = req.headers['content-type'] || '';
    if (!/^multipart\/form-data\s*;/i.test(contentType)) return refuseEarly(req, res, 400, 'content-type must be multipart/form-data');

    const declared = req.headers['content-length'];
    let declaredBytes = 0;
    if (declared !== undefined) {
      if (!/^\d+$/.test(declared)) return refuseEarly(req, res, 400, 'invalid Content-Length');
      declaredBytes = Number(declared);
      if (declaredBytes > config.maxBodyBytes) return refuseEarly(req, res, 413, 'body too large');
    }

    const admitted = supervisor.reserve(declaredBytes);
    if (admitted.error) return refuseEarly(req, res, admitted.error.status, admitted.error.message);
    const reservation = admitted.reservation;

    // The client going away cancels the job (dropped from the queue, or the page is closed).
    const clientGone = new AbortController();
    res.once('close', () => { if (!res.writableEnded) clientGone.abort('client'); });

    let handedOver = false;
    let reader = null;
    let timedOut = false;
    const failEarly = (err) => {
      if (!handedOver) reservation.release();
      if (clientGone.signal.aborted) return;
      const status = err instanceof HttpError ? err.status : 500;
      if (!(err instanceof HttpError)) log('request_error', { id, reason: safeMessage(err) });
      log('job', { id, bytes: reservation.bytes, pages: 0, queueMs: 0, renderMs: 0, outcome: 'error', code: status, reason: status === 400 ? 'invalid input' : err.message });
      sendJson(res, status, err instanceof HttpError ? err.message : 'internal error', { Connection: 'close' });
      drainAndClose(req);
    };

    // Whole-request deadline, from arrival, also while the body is still being read.
    const readDeadline = setTimeout(() => {
      if (!handedOver) {
        timedOut = true;
        const err = new HttpError(504, 'deadline exceeded');
        err.reported = true;
        failEarly(err);
        if (reader) reader.cancel(err);
      }
    }, config.deadlineMs);

    try {
      // Read the body, counting bytes whatever Content-Length said.
      reader = readBody(req, config.maxBodyBytes, (total) => reservation.grow(total));
      const body = await reader.promise;
      if (clientGone.signal.aborted) { reservation.release(); return; }

      let parsed;
      try {
        const form = await new Request('http://localhost/', { method: 'POST', headers: { 'content-type': contentType }, body }).formData();
        parsed = await parseRenderForm(form);
      } catch (err) {
        if (err instanceof HttpError) throw err;
        throw new HttpError(400, 'invalid multipart body');
      }

      if (timedOut) return;
      clearTimeout(readDeadline);
      handedOver = true;
      const result = await supervisor.submit(reservation, { id, ...parsed, arrivedAt, clientSignal: clientGone.signal });
      res.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Length': result.pdf.length });
      res.end(result.pdf);
    } catch (err) {
      clearTimeout(readDeadline);
      if (err && err.reported) return;
      if (err && err.dropped) return; // client gone; the supervisor logged it
      if (handedOver) {
        if (!res.headersSent && !clientGone.signal.aborted) {
          const status = err instanceof HttpError ? err.status : 500;
          sendJson(res, status, err instanceof HttpError ? err.message : 'internal error', status === 503 ? { Connection: 'close' } : {});
        }
        return;
      }
      failEarly(err);
    } finally {
      clearTimeout(readDeadline);
    }
  }

  return server;
}

// ---- process entry ------------------------------------------------------------------------------------

export async function main() {
  const config = loadConfig();
  const log = createLogger();
  // /tmp is a tmpfs that starts empty: create the directories the browser and the jobs use.
  for (const dir of [process.env.HOME, process.env.XDG_CONFIG_HOME, process.env.XDG_CACHE_HOME, process.env.XDG_DATA_HOME, config.profilesDir, config.jobsDir]) {
    if (dir) mkdirSync(dir, { recursive: true });
  }
  const { launchChrome } = await import('./chrome.mjs');
  const supervisor = new Supervisor({ config, launch: launchChrome, log });
  const server = createServer({ supervisor, config, log });

  let shuttingDown = false;
  const stop = async (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log('signal', { signal });
    await supervisor.shutdown();
    server.close();
    server.closeAllConnections();
    process.exit(0);
  };
  process.on('SIGTERM', () => stop('SIGTERM'));
  process.on('SIGINT', () => stop('SIGINT'));
  process.on('unhandledRejection', (err) => log('unhandled_rejection', { reason: safeMessage(err) }));

  await new Promise((resolve) => server.listen(config.port, config.host, resolve));
  log('listening', { port: config.port, deadlineMs: config.deadlineMs, context: config.context, js: config.js, load: config.load, fontsReady: config.fontsReady });
  await supervisor.start();
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((err) => {
    process.stderr.write(`fatal: ${safeMessage(err)}\n`);
    process.exit(1);
  });
}
