// render.mjs against a scripted fake puppeteer: the order of CDP calls, the print parameters and the request filter.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { renderJob, loadModeFor, CSP, MAIN_URL, EMPTY_TEMPLATE, AbortedError } from '../src/render.mjs';
import { loadConfig } from '../src/config.mjs';
import { fakePdf } from './support.mjs';

function fakeBrowser({ requests = [], gotoHook } = {}) {
  const asEvent = (u, i) => (typeof u === 'string' ? { url: u, resourceType: 'Image' } : u);
  const calls = [];
  const state = { calls, handlers: {}, pageClosed: 0, contextClosed: 0, detached: 0, usedContext: false, usedDefault: false };
  const cdp = {
    on(event, fn) { state.handlers[event] = fn; },
    async detach() { state.detached += 1; },
    async send(method, params) {
      calls.push([method, params]);
      if (method === 'Page.printToPDF') return { stream: 's1' };
      if (method === 'IO.read') return { data: fakePdf(3).toString('base64'), base64Encoded: true, eof: true };
      if (method === 'Runtime.evaluate') return {};
      return {};
    },
  };
  const page = {
    once() {},
    on() {},
    async createCDPSession() { return cdp; },
    async goto(url) {
      calls.push(['goto', url]);
      if (gotoHook) await gotoHook(url);
      const main = { url, resourceType: 'Document' };
      for (const [i, u] of [main, ...requests].map((x, n) => [n, asEvent(x)])) state.handlers['Fetch.requestPaused']({ requestId: `r-${calls.length}-${i}`, resourceType: u.resourceType, request: { url: u.url } });
    },
    async close() { state.pageClosed += 1; },
  };
  state.browser = {
    async createBrowserContext() { state.usedContext = true; return { newPage: async () => page, close: async () => { state.contextClosed += 1; } }; },
    async newPage() { state.usedDefault = true; return page; },
  };
  return state;
}

const PARAMS = {
  paperWidth: 8.27, paperHeight: 11.69, marginTop: 0.39, marginRight: 0.55, marginBottom: 0.55, marginLeft: 0.55,
  landscape: false, printBackground: true, scale: 1, emulatedMediaType: 'print', preferCssPageSize: true,
};

async function run(over = {}, { configOver = {}, requests, gotoHook, signal } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pdfr-render-'));
  const config = loadConfig({}, { jobsDir: dir, ...configOver });
  const fake = fakeBrowser({ requests, gotoHook: gotoHook && ((u) => gotoHook(u, dir)) });
  const job = { id: 'job1', html: Buffer.from('<html><body>Hi</body></html>'), params: { ...PARAMS }, ...over };
  const result = await renderJob({ browser: fake.browser, job, config, signal: signal || new AbortController().signal, deadlineAt: Date.now() + 10000 });
  return { fake, result, config, dir, calls: fake.calls, methods: fake.calls.map((c) => c[0]) };
}

const find = (calls, method) => calls.filter((c) => c[0] === method).map((c) => c[1]);

test('call order: scripts off and Fetch before navigation; style, media, fonts, then print', async () => {
  const { methods } = await run();
  const idx = (m, n = 0) => methods.reduce((acc, x, i) => (x === m ? [...acc, i] : acc), [])[n];
  assert.ok(idx('Emulation.setScriptExecutionDisabled') < idx('goto'));
  assert.ok(idx('Fetch.enable') < idx('goto'));
  // evaluate #0 = print-colour style, #1 = fonts.ready
  assert.ok(idx('goto') < idx('Runtime.evaluate', 0));
  assert.ok(idx('Runtime.evaluate', 0) < idx('Emulation.setEmulatedMedia'));
  assert.ok(idx('Emulation.setEmulatedMedia') < idx('Runtime.evaluate', 1), 'fonts.ready runs after the media emulation');
  assert.ok(idx('Runtime.evaluate', 1) < idx('Page.printToPDF'));
  assert.ok(idx('Page.printToPDF') < idx('IO.read'));
  assert.equal(methods.at(-1), 'IO.close');
});

test('print parameters: stream, untagged, no outline, A4 margins, no header/footer unless sent', async () => {
  const { calls } = await run();
  const [p] = find(calls, 'Page.printToPDF');
  assert.deepEqual(p, {
    transferMode: 'ReturnAsStream', landscape: false, printBackground: true, scale: 1,
    paperWidth: 8.27, paperHeight: 11.69, marginTop: 0.39, marginRight: 0.55, marginBottom: 0.55, marginLeft: 0.55,
    preferCSSPageSize: true, generateTaggedPDF: false, generateDocumentOutline: false, displayHeaderFooter: false,
  });
  assert.equal(find(calls, 'Emulation.setEmulatedMedia')[0].media, 'print');
  assert.equal(find(calls, 'Emulation.setScriptExecutionDisabled')[0].value, true);
});

test('only a footer: header becomes the empty template and displayHeaderFooter is on', async () => {
  const { calls } = await run({ footer: '<p>footer</p>' });
  const [p] = find(calls, 'Page.printToPDF');
  assert.equal(p.displayHeaderFooter, true);
  assert.equal(p.headerTemplate, EMPTY_TEMPLATE);
  assert.equal(p.footerTemplate, '<p>footer</p>');
});

test('printBackground=false also strips html/body backgrounds in the injected style', async () => {
  const on = (await run()).calls;
  const off = (await run({ params: { ...PARAMS, printBackground: false } })).calls;
  const style = (calls) => find(calls, 'Runtime.evaluate')[0].expression;
  assert.ok(style(on).includes('print-color-adjust:exact !important'));
  assert.ok(!style(on).includes('background:none'));
  assert.ok(style(off).includes('background:none'));
  assert.equal(find(off, 'Page.printToPDF')[0].printBackground, false);
});

test('intercept mode: the document is served from memory with a CSP; everything else is blocked', async () => {
  const requests = [
    'http://example.com/a.png', 'https://example.com/b.css', 'file:///etc/passwd', 'ws://10.0.0.1/', 'ftp://10.0.0.1/x',
    'http://render.invalid/other.html', 'blob:http://render.invalid/1',
  ];
  const navigations = [
    { url: 'http://10.0.0.1/refresh', resourceType: 'Document' }, // meta refresh or link
    { url: 'file:///etc/hostname', resourceType: 'Document' },
  ];
  const { calls } = await run({}, { requests: [...requests, ...navigations] });
  const fulfilledAll = find(calls, 'Fetch.fulfillRequest');
  const fulfilled = fulfilledAll.filter((f) => f.responseCode === 200);
  assert.equal(fulfilled.length, 1);
  assert.deepEqual(fulfilledAll.filter((f) => f.responseCode === 204).length, navigations.length, 'other navigations are answered 204 and cancelled');
  assert.equal(fulfilled[0].responseCode, 200);
  assert.equal(Buffer.from(fulfilled[0].body, 'base64').toString(), '<html><body>Hi</body></html>');
  const headers = Object.fromEntries(fulfilled[0].responseHeaders.map((h) => [h.name, h.value]));
  assert.equal(headers['Content-Type'], 'text/html; charset=utf-8');
  assert.equal(headers['Content-Security-Policy'], CSP);
  const failed = find(calls, 'Fetch.failRequest');
  assert.equal(failed.length, requests.length);
  assert.ok(failed.every((f) => f.errorReason === 'BlockedByClient'));
  assert.equal(calls.find((c) => c[0] === 'goto')[1], MAIN_URL);
});

test('data: URLs that Chrome does pause are let through', async () => {
  const { calls } = await run({}, { requests: ['data:image/png;base64,AAAA'] });
  assert.equal(find(calls, 'Fetch.continueRequest').length, 1);
  assert.equal(find(calls, 'Fetch.failRequest').length, 0);
});

test('RENDERER_CSP=off sends no CSP header', async () => {
  const { calls } = await run({}, { configOver: { csp: 'off' } });
  const headers = find(calls, 'Fetch.fulfillRequest')[0].responseHeaders.map((h) => h.name);
  assert.ok(!headers.includes('Content-Security-Policy'));
});

test('JS on: scripts are not disabled', async () => {
  const { methods } = await run({}, { configOver: { js: 'on' } });
  assert.ok(!methods.includes('Emulation.setScriptExecutionDisabled'));
});

test('file mode: the bytes are written to the job directory, only that file and data: are allowed, the directory is removed', async () => {
  let seenDuringRender = null;
  const requests = ['file:///etc/passwd', 'http://example.com/x', 'file:///tmp/jobs/other/index.html'];
  const { calls, result, dir } = await run({}, {
    configOver: { load: 'file' },
    requests,
    gotoHook: async (url, d) => { seenDuringRender = { url, content: fsSync.readFileSync(path.join(d, 'job1', 'index.html'), 'utf8') }; },
  });
  assert.equal(seenDuringRender.url, `file://${dir}/job1/index.html`);
  assert.equal(seenDuringRender.content, '<html><body>Hi</body></html>');
  assert.equal(find(calls, 'Fetch.fulfillRequest').length, 0, 'nothing is fulfilled from memory in file mode');
  assert.equal(find(calls, 'Fetch.continueRequest').length, 1, 'only the job file continues');
  assert.equal(find(calls, 'Fetch.failRequest').length, requests.length);
  assert.ok(fsSync.existsSync(path.join(dir, 'job1')), 'directory exists until the cleanup');
  await result.cleanup();
  assert.ok(!fsSync.existsSync(path.join(dir, 'job1')), 'directory removed by the cleanup');
});

test('auto mode: file for large documents, intercept for small ones', async () => {
  const config = loadConfig({}, { load: 'auto', soloBodyBytes: 100 });
  assert.equal(loadModeFor(config, 99), 'intercept');
  assert.equal(loadModeFor(config, 100), 'file');
  const { calls } = await run({ html: Buffer.alloc(500, 97) }, { configOver: { load: 'auto', soloBodyBytes: 100 } });
  assert.equal(find(calls, 'Fetch.fulfillRequest').length, 0);
  assert.ok(calls.find((c) => c[0] === 'goto')[1].startsWith('file://'));
});

test('per-job context by default, the default context with RENDERER_CONTEXT=shared; both are closed by the cleanup', async () => {
  const a = await run();
  assert.equal(a.fake.usedContext, true);
  assert.equal(a.fake.usedDefault, false);
  assert.equal(a.fake.pageClosed, 0, 'the answer comes first; closing is the cleanup');
  await a.result.cleanup();
  assert.equal(a.fake.pageClosed, 1);
  assert.equal(a.fake.contextClosed, 1);
  assert.equal(a.fake.detached, 1);
  const b = await run({}, { configOver: { context: 'shared' } });
  assert.equal(b.fake.usedDefault, true);
  assert.equal(b.fake.usedContext, false);
  await b.result.cleanup();
  assert.equal(b.fake.pageClosed, 1);
});

test('the result is a PDF with a page count', async () => {
  const { result } = await run();
  assert.equal(result.pages, 3);
  assert.equal(result.pdf.subarray(0, 5).toString(), '%PDF-');
});

test('an aborted signal closes the page and rejects with AbortedError', async () => {
  const ac = new AbortController();
  ac.abort('deadline');
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pdfr-render-'));
  const fake = fakeBrowser();
  await assert.rejects(
    renderJob({ browser: fake.browser, job: { id: 'j', html: Buffer.from('x'), params: { ...PARAMS } }, config: loadConfig({}, { jobsDir: dir }), signal: ac.signal, deadlineAt: Date.now() + 1000 }),
    AbortedError,
  );
});

test('a failure inside the job cleans up before rejecting', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pdfr-render-'));
  const fake = fakeBrowser();
  fake.browser.createBrowserContext = async () => ({
    newPage: async () => ({ once() {}, on() {}, createCDPSession: async () => { throw new Error('boom'); }, close: async () => { fake.pageClosed += 1; } }),
    close: async () => { fake.contextClosed += 1; },
  });
  await assert.rejects(
    renderJob({ browser: fake.browser, job: { id: 'j', html: Buffer.from('x'), params: { ...PARAMS } }, config: loadConfig({}, { jobsDir: dir, load: 'file' }), signal: new AbortController().signal, deadlineAt: Date.now() + 1000 }),
    /boom/,
  );
  assert.equal(fake.pageClosed, 1);
  assert.equal(fake.contextClosed, 1);
  assert.deepEqual(await fs.readdir(dir), []);
});
