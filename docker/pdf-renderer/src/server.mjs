// HTTP front end: POST /render (multipart) and GET /health.

import http from 'node:http';
import { Readable } from 'node:stream';
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
    html: Buffer.from(await files['index.html'].arrayBuffer()),
    header: files['header.html'] ? await files['header.html'].text() : undefined,
    footer: files['footer.html'] ? await files['footer.html'].text() : undefined,
    params,
  };
}

// ---- server -----------------------------------------------------------------------------------------

const DRAIN_MS = 10000;

function sendJson(res, status, error, extraHeaders = {}) {
  if (res.headersSent || res.writableEnded || res.destroyed) return false;
  const body = JSON.stringify({ error, code: status });
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), ...extraHeaders });
  res.end(body);
  return true;
}

/**
 * After answering without having read the whole body: keep discarding the upload for a few seconds so the client can
 * finish sending and read the answer, then close. (Closing at once would reset the connection under the client.)
 */
function drain(req, limitBytes) {
  if (req.complete) return;
  let seen = 0;
  req.on('data', (chunk) => { seen += chunk.length; if (seen > limitBytes) req.destroy(); }); // discarded, never buffered
  const timer = setTimeout(() => req.destroy(), DRAIN_MS);
  timer.unref();
  req.once('close', () => clearTimeout(timer));
  req.once('end', () => clearTimeout(timer));
}

export function createServer({ supervisor, config, log }) {
  const server = http.createServer((req, res) => run(req, res, false));
  // Expect: 100-continue: decide before the client is told to send the body.
  server.on('checkContinue', (req, res) => run(req, res, true));
  server.keepAliveTimeout = config.keepAliveTimeoutMs;
  server.headersTimeout = config.headersTimeoutMs;

  function run(req, res, expectContinue) {
    handle(req, res, expectContinue).catch((err) => {
      log('request_error', { reason: safeMessage(err) });
      if (!sendJson(res, 500, 'internal error')) res.destroy();
      drain(req, config.maxBodyBytes);
    });
  }

  async function handle(req, res, expectContinue) {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/health') {
      if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, 'method not allowed');
      const { status, body } = supervisor.health();
      const text = JSON.stringify(body);
      res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(text) });
      return res.end(req.method === 'HEAD' ? undefined : text);
    }
    if (url.pathname !== '/render') { sendJson(res, 404, 'not found'); return drain(req, config.maxBodyBytes); }
    if (req.method !== 'POST') { sendJson(res, 405, 'method not allowed', { Allow: 'POST' }); return drain(req, config.maxBodyBytes); }
    return handleRender(req, res, expectContinue);
  }

  async function handleRender(req, res, expectContinue) {
    const arrivedAt = Date.now();
    const id = randomBytes(4).toString('hex');
    let drainLimit = config.maxBodyBytes; // raised to the declared length so a refused upload can finish
    const refuse = (status, message, bytes = 0) => {
      log('job', { id, bytes, pages: 0, queueMs: 0, renderMs: 0, outcome: 'refused', code: status, reason: status === 400 ? 'invalid input' : message });
      sendJson(res, status, message);
      drain(req, drainLimit);
    };

    const contentType = req.headers['content-type'] || '';
    if (!/^multipart\/form-data\s*;/i.test(contentType)) return refuse(400, 'content-type must be multipart/form-data');

    const declared = req.headers['content-length'];
    let declaredBytes = null; // unknown (chunked): treated as a large body
    if (declared !== undefined) {
      if (!/^\d+$/.test(declared)) return refuse(400, 'invalid Content-Length');
      declaredBytes = Number(declared);
      drainLimit = Math.max(drainLimit, declaredBytes);
      if (declaredBytes > config.maxBodyBytes) return refuse(413, 'body too large', declaredBytes);
    }

    // The client going away cancels the job (dropped from the queue, or the page is closed).
    const clientGone = new AbortController();
    res.once('close', () => { if (!res.writableEnded) clientGone.abort('client'); });

    // Admit before reading. The body stays unread on the socket until a slot is free.
    const admitted = supervisor.admit(declaredBytes, { id, arrivedAt, clientSignal: clientGone.signal });
    if (admitted.error) return refuse(admitted.error.status, admitted.error.message, declaredBytes || 0);
    const entry = admitted.entry;

    let cancelRead = null;
    entry.signal.addEventListener('abort', () => { if (cancelRead) cancelRead(new HttpError(504, 'deadline exceeded')); }, { once: true });

    const answer = (err) => {
      if (clientGone.signal.aborted) return;
      const status = err instanceof HttpError ? err.status : 500;
      if (!(err instanceof HttpError)) log('request_error', { id, reason: safeMessage(err) });
      sendJson(res, status, err instanceof HttpError ? err.message : 'internal error');
      drain(req, drainLimit);
    };

    try {
      await entry.started; // rejects: 503 / 504 / client gone
      if (expectContinue) res.writeContinue();

      // Read and parse in one pass, counting bytes. Nothing but the parsed parts is kept.
      let total = 0;
      let readError = null;
      let controllerRef = null;
      const counter = new TransformStream({
        start(controller) { controllerRef = controller; },
        transform(chunk, controller) {
          total += chunk.length;
          if (total > config.maxBodyBytes) {
            readError = new HttpError(413, 'body too large');
            controller.error(readError);
            return;
          }
          controller.enqueue(chunk);
        },
      });
      cancelRead = (err) => { readError = readError || err; if (controllerRef) controllerRef.error(err); };
      if (entry.signal.aborted) throw new HttpError(504, 'deadline exceeded');

      let parsed;
      try {
        const request = new Request('http://localhost/', {
          method: 'POST',
          headers: { 'content-type': contentType },
          body: Readable.toWeb(req).pipeThrough(counter),
          duplex: 'half',
        });
        parsed = await parseRenderForm(await request.formData());
      } catch (err) {
        if (readError) throw readError;
        if (clientGone.signal.aborted) throw Object.assign(new Error('client gone'), { dropped: true });
        if (err instanceof HttpError) throw err;
        throw new HttpError(400, 'invalid multipart body');
      }
      cancelRead = null;

      const resultPromise = entry.run({ id, ...parsed });
      parsed = null;
      const result = await resultPromise;
      res.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Length': result.pdf.length });
      res.end(result.pdf);
    } catch (err) {
      if (err && err.dropped) return; // client gone; the supervisor logged it
      // Idempotent: the supervisor may already have answered (and logged) this entry.
      entry.fail(err instanceof HttpError ? err : new HttpError(500, 'internal error'));
      answer(err);
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
    // Let responses that are still being written finish (a large PDF to a slow client), closing idle keep-alive
    // connections as they become idle; after 5 s whatever is left is cut.
    const closed = new Promise((resolve) => server.close(resolve));
    const poll = setInterval(() => server.closeIdleConnections(), 50);
    await Promise.race([closed, new Promise((resolve) => setTimeout(resolve, 5000))]);
    clearInterval(poll);
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
