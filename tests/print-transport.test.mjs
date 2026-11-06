import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { Buffer } from 'node:buffer';
import './print-harness.mjs'; // registers the TypeScript hook (ipp-client.ts needs a transform, not only a strip)
const { submitRawJob, jobOutcome, printFailureBody, configuredPrinterName, UNCONFIRMED_NOTE } = await import('../functions/_shared/print-transport.ts');

// WH-109: the one path every print function uses to hand finished printer bytes to the printer. The bridge side runs against a real
// HTTP server on 127.0.0.1 (an ephemeral port): the contract is POST <url>/print/raw, application/octet-stream, X-Printer, X-Doc-Name,
// X-Print-Token, answer JSON {success}. The CUPS side runs against a stand-in for the one IPP Print-Job call. No real printer or bridge.
const TOKEN = 'unit-test-bridge-token-0123456789abcdef';
// ESC C 0 6 (page length), LF, FF, CR, 0x88, 0xFF: the bytes that text handling, line-ending translation or UTF-8 would damage.
const TRICKY = Uint8Array.from([0x1b, 0x43, 0x00, 0x06, 0x0a, 0x0c, 0x0d, 0x88, 0xff]);
const ALL_BYTES = Uint8Array.from({ length: 256 }, (_, i) => i);

// A bridge on 127.0.0.1. `answer(request, response)` decides; every request is recorded.
async function bridge(answer) {
  const seen = [];
  const sockets = new Set();
  const server = createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      seen.push({ method: request.method, url: request.url, headers: request.headers, body: Buffer.concat(chunks) });
      answer(request, response, seen.length);
    });
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    seen,
    url: `http://127.0.0.1:${server.address().port}`,
    port: server.address().port,
    close: () => new Promise(resolve => { for (const socket of sockets) socket.destroy(); server.close(resolve); }),
  };
}
const reply = (status, body) => (_request, response) => {
  response.writeHead(status, { 'Content-Type': 'application/json' });
  response.end(typeof body === 'string' ? body : JSON.stringify(body));
};

const environment = (url, extra = {}) => {
  const values = { PRINT_TRANSPORT: 'bridge', PRINTER_NAME: 'LQ1310_RAW', PRINTBRIDGE_URL: url, PRINTBRIDGE_TOKEN: TOKEN, ...extra };
  return name => values[name];
};
const unusedIpp = async () => { throw new Error('IPP must not be used on the bridge path'); };
const deps = (env, extra = {}) => ({ env, fetch: globalThis.fetch, ippPrintJob: unusedIpp, timeoutMs: 2000, ...extra });
const job = (bytes = TRICKY, docName = 'Invoice-1-to-2') => ({ bytes, docName, jobType: 'Invoice' });

test('bridge: one POST to /print/raw with the contract headers, the bytes unchanged, and no Authorization header', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    const result = await submitRawJob(job(ALL_BYTES), deps(environment(server.url)));
    assert.deepEqual(result, { ok: true, transport: 'bridge', jobId: null, confirmed: false });
    assert.equal(server.seen.length, 1);
    const [request] = server.seen;
    assert.equal(request.method, 'POST');
    assert.equal(request.url, '/print/raw');
    assert.equal(request.headers['content-type'], 'application/octet-stream');
    assert.equal(request.headers['x-printer'], 'LQ1310_RAW');
    assert.equal(request.headers['x-doc-name'], 'Invoice-1-to-2');
    assert.equal(request.headers['x-print-token'], TOKEN);
    assert.equal(request.headers.authorization, undefined, 'the caller\'s Authorization is never forwarded');
    assert.deepEqual(Object.keys(request.headers).filter(name => /authorization|cookie|apikey/i.test(name)), []);
    assert.deepEqual(request.body, Buffer.from(ALL_BYTES), 'all 256 byte values arrive unchanged');
    assert.equal(request.headers['content-length'], '256');
  } finally { await server.close(); }
});

test('bridge: the printer-control bytes ESC C 0 6 LF FF CR 0x88 0xFF arrive exactly', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    assert.equal((await submitRawJob(job(TRICKY), deps(environment(server.url)))).ok, true);
    assert.equal(server.seen[0].body.toString('hex'), '1b4300060a0c0d88ff');
  } finally { await server.close(); }
});

test('bridge: a bridge success is sent, not confirmed: the job is recorded unknown, never completed', async () => {
  const server = await bridge(reply(200, { success: true, printer: 'LQ1310_RAW' }));
  try {
    const result = await submitRawJob(job(), deps(environment(server.url)));
    const outcome = jobOutcome(result);
    assert.equal(outcome.kind, 'sent');
    assert.equal(outcome.row.status, 'unknown');
    assert.equal(outcome.row.cups_job_id, null);
    assert.match(outcome.row.error_message, /does not report when the job ends/);
  } finally { await server.close(); }
});

test('bridge: the token is required; an empty or blank token is refused before any request is made', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    for (const token of ['', '   ', undefined]) {
      const result = await submitRawJob(job(), deps(environment(server.url, { PRINTBRIDGE_TOKEN: token })));
      assert.deepEqual(result, { ok: false, transport: 'bridge', jobId: null, confirmed: false, error: 'PRINTBRIDGE_TOKEN is not set' }, JSON.stringify(token));
    }
    assert.equal(server.seen.length, 0, 'nothing reached the bridge');
  } finally { await server.close(); }
});

test('bridge: the token is trimmed, and appears in no result', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    await submitRawJob(job(), deps(environment(server.url, { PRINTBRIDGE_TOKEN: `  ${TOKEN}\n` })));
    assert.equal(server.seen[0].headers['x-print-token'], TOKEN);
  } finally { await server.close(); }
  for (const status of [401, 500]) {
    const refusing = await bridge(reply(status, { success: false, error: 'detail' }));
    try {
      assert.doesNotMatch(JSON.stringify(await submitRawJob(job(), deps(environment(refusing.url)))), new RegExp(TOKEN));
    } finally { await refusing.close(); }
  }
});

test('bridge: the address must be an http(s) address without a path; a trailing slash is dropped', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    assert.equal((await submitRawJob(job(), deps(environment(`${server.url}/`)))).ok, true);
    assert.equal(server.seen[0].url, '/print/raw', 'no double slash');
    for (const url of ['', undefined, 'not a url', 'ftp://192.0.2.1:6632', `${server.url}/print`, `${server.url}?x=1`, `${server.url}#frag`]) {
      const result = await submitRawJob(job(), deps(environment(url)));
      assert.equal(result.ok, false, String(url));
      assert.equal(result.error, 'PRINTBRIDGE_URL is not set to an http address', String(url));
    }
    assert.equal(server.seen.length, 1, 'only the valid address was called');
  } finally { await server.close(); }
});

test('bridge: a printer name that cannot travel in a header is refused before any request', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    for (const name of ['LQ1310\r\nX-Evil: 1', '../x', 'a'.repeat(200), '-leading-dash', 'café']) {
      const result = await submitRawJob(job(), deps(environment(server.url, { PRINTER_NAME: name })));
      assert.equal(result.error, 'PRINTER_NAME is not a valid printer name', JSON.stringify(name));
    }
    // A Windows printer name with spaces and brackets is fine, and travels as given.
    assert.equal((await submitRawJob(job(), deps(environment(server.url, { PRINTER_NAME: 'EPSON LQ-1310 (Copy 1)' })))).ok, true);
    assert.equal(server.seen.length, 1);
    assert.equal(server.seen[0].headers['x-printer'], 'EPSON LQ-1310 (Copy 1)');
  } finally { await server.close(); }
});

test('bridge: the document name is printable ASCII, at most 100 characters, with a fallback', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    await submitRawJob(job(TRICKY, 'Dispatch ગુજ\r\nX-Evil: 1'), deps(environment(server.url)));
    await submitRawJob(job(TRICKY, 'x'.repeat(300)), deps(environment(server.url)));
    await submitRawJob(job(TRICKY, '   '), deps(environment(server.url)));
    const names = server.seen.map(request => request.headers['x-doc-name']);
    assert.match(names[0], /^Dispatch \?+X-Evil: 1$/, 'non-ASCII and line breaks become ?');
    assert.equal(names[1].length, 100);
    assert.equal(names[2], 'Print Job');
    assert.ok(server.seen.every(request => request.headers['x-evil'] === undefined), 'no header was injected');
  } finally { await server.close(); }
});

test('bridge: 401 and 403 say the token was refused (not unconfirmed); the job did not print', async () => {
  for (const status of [401, 403]) {
    const server = await bridge(reply(status, { success: false, error: 'bad token' }));
    try {
      const result = await submitRawJob(job(), deps(environment(server.url)));
      assert.deepEqual(result, { ok: false, transport: 'bridge', jobId: null, confirmed: false, error: 'The print bridge refused the token' });
      assert.equal(jobOutcome(result).kind, 'failed');
    } finally { await server.close(); }
  }
});

test('bridge: a 4xx/5xx answer is a failure that is not unconfirmed ("could not print")', async () => {
  for (const [status, body] of [[400, { success: false }], [404, { success: false }], [500, { success: false, error: 'spooler' }], [503, 'not json'], [500, { success: true }]]) {
    const server = await bridge(reply(status, body));
    try {
      const result = await submitRawJob(job(), deps(environment(server.url)));
      assert.deepEqual(result, { ok: false, transport: 'bridge', jobId: null, confirmed: false, error: 'The print bridge could not print the job' }, `${status} ${JSON.stringify(body)}`);
    } finally { await server.close(); }
  }
});

test('bridge: a 2xx that does not say success, or is not JSON, may have printed: unconfirmed, recorded unknown', async () => {
  for (const body of [{ success: false }, {}, { success: 'true' }, 'OK', '', 'null', '[]']) {
    const server = await bridge(reply(200, body));
    try {
      const result = await submitRawJob(job(), deps(environment(server.url)));
      assert.deepEqual(result, { ok: false, transport: 'bridge', jobId: null, confirmed: false, error: 'The print bridge did not confirm the job', unconfirmed: true }, JSON.stringify(body));
      const outcome = jobOutcome(result);
      assert.equal(outcome.kind, 'unconfirmed');
      assert.deepEqual(outcome.row, { cups_job_id: null, status: 'unknown', error_message: UNCONFIRMED_NOTE });
    } finally { await server.close(); }
  }
});

test('bridge: no answer within the timeout is unconfirmed (the job may be on paper)', async () => {
  const server = await bridge(() => { /* never answers */ });
  try {
    const result = await submitRawJob(job(), deps(environment(server.url), { timeoutMs: 150 }));
    assert.deepEqual(result, { ok: false, transport: 'bridge', jobId: null, confirmed: false, error: 'The print bridge did not confirm the job', unconfirmed: true });
    assert.equal(server.seen.length, 1, 'the bytes were sent once and not resent');
  } finally { await server.close(); }
});

test('bridge: a refused connection is a plain failure, not unconfirmed (nothing was sent)', async () => {
  const server = await bridge(reply(200, { success: true }));
  const url = server.url;
  await server.close();
  const result = await submitRawJob(job(), deps(environment(url)));
  assert.deepEqual(result, { ok: false, transport: 'bridge', jobId: null, confirmed: false, error: 'The print bridge could not be reached' });
});

test('bridge: a redirect is not followed (the token never goes to another address)', async () => {
  const other = await bridge(reply(200, { success: true }));
  const server = await bridge((_request, response) => { response.writeHead(307, { Location: `${other.url}/print/raw` }); response.end(); });
  try {
    const result = await submitRawJob(job(), deps(environment(server.url)));
    assert.equal(result.ok, false);
    assert.equal(other.seen.length, 0, 'the redirect target was not called');
  } finally { await server.close(); await other.close(); }
});

test('nothing to print: no request, no job', async () => {
  const server = await bridge(reply(200, { success: true }));
  try {
    for (const bytes of [new Uint8Array(0), 'text', null, undefined, [1, 2, 3]]) {
      const result = await submitRawJob({ bytes, docName: 'x', jobType: 'Raw' }, deps(environment(server.url)));
      assert.deepEqual(result, { ok: false, transport: 'bridge', jobId: null, confirmed: false, error: 'Nothing to print' });
    }
    assert.equal(server.seen.length, 0);
  } finally { await server.close(); }
});

test('PRINT_TRANSPORT other than cups or bridge is a configuration error, never guessed', async () => {
  for (const value of ['usb', 'CUPSS', 'http']) {
    const result = await submitRawJob(job(), deps(environment('http://127.0.0.1:1', { PRINT_TRANSPORT: value })));
    assert.equal(result.ok, false);
    assert.equal(result.error, 'PRINT_TRANSPORT must be cups or bridge');
  }
});

// ---- the CUPS side ----
const cupsEnvironment = (extra = {}) => {
  const values = { PRINT_TRANSPORT: 'cups', PRINTER_NAME: 'LQ1310_RAW', ...extra };
  return name => values[name];
};
const accepted = { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 41, 'job-uri': 'ipp://cups:631/jobs/41' } };

test('cups: Print-Job to the configured queue as vnd.cups-raw with the bytes unchanged; a job id makes it confirmed and tracked', async () => {
  const calls = [];
  const result = await submitRawJob(job(ALL_BYTES, 'Dispatch-5-to-6'), deps(cupsEnvironment(), {
    ippPrintJob: async (queueUrl, message) => { calls.push({ queueUrl, message }); return accepted; },
  }));
  assert.deepEqual(result, { ok: true, transport: 'cups', jobId: 41, confirmed: true, jobUri: 'ipp://cups:631/jobs/41' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].queueUrl, 'http://cups:631/printers/LQ1310_RAW');
  const attributes = calls[0].message['operation-attributes-tag'];
  assert.equal(attributes['document-format'], 'application/vnd.cups-raw', 'raw: CUPS runs no filter over the bytes');
  assert.equal(attributes['job-name'], 'Dispatch-5-to-6');
  assert.equal(attributes['requesting-user-name'], 'warehouse-invoice');
  assert.deepEqual(Buffer.from(calls[0].message.data), Buffer.from(ALL_BYTES));
  assert.deepEqual(jobOutcome(result), { kind: 'tracked', row: { cups_job_id: 41, status: 'printing' } });
});

test('cups: the queue name comes from PRINTER_NAME and an invalid one is refused before any call', async () => {
  const calls = [];
  const send = async (queueUrl) => { calls.push(queueUrl); return accepted; };
  assert.equal((await submitRawJob(job(), deps(cupsEnvironment({ PRINTER_NAME: 'Office_2' }), { ippPrintJob: send }))).ok, true);
  assert.deepEqual(calls, ['http://cups:631/printers/Office_2']);
  for (const name of ['a/b', 'a b', '../x', 'q?x=1', 'a'.repeat(128)]) {
    const result = await submitRawJob(job(), deps(cupsEnvironment({ PRINTER_NAME: name }), { ippPrintJob: send }));
    assert.equal(result.error, 'PRINTER_NAME is not a valid CUPS queue name', name);
  }
  assert.equal(calls.length, 1);
  // Unset or empty transport means cups.
  assert.equal((await submitRawJob(job(), deps(name => ({ PRINTER_NAME: 'LQ1310_RAW' })[name], { ippPrintJob: send }))).transport, 'cups');
});

test('cups: a reply without a positive integer job id is unconfirmed (never a stand-in id)', async () => {
  for (const replyValue of [{ statusCode: 'successful-ok' }, { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 0 } },
    { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 'unknown' } }, { statusCode: 'client-error-not-possible', 'job-attributes-tag': { 'job-id': 5 } }, {}, 'ok']) {
    const result = await submitRawJob(job(), deps(cupsEnvironment(), { ippPrintJob: async () => replyValue }));
    assert.deepEqual(result, { ok: false, transport: 'cups', jobId: null, confirmed: false, error: 'The printer did not confirm the job', unconfirmed: true }, JSON.stringify(replyValue));
  }
});

test('cups: an IPP error is a plain failure with no library text; no answer in time is unconfirmed', async () => {
  const failed = await submitRawJob(job(), deps(cupsEnvironment(), { ippPrintJob: async () => { throw new Error('connect ECONNREFUSED 172.20.0.9:631'); } }));
  assert.deepEqual(failed, { ok: false, transport: 'cups', jobId: null, confirmed: false, error: 'The print service could not be reached' });
  const silent = await submitRawJob(job(), deps(cupsEnvironment(), { timeoutMs: 100, ippPrintJob: () => new Promise(() => {}) }));
  assert.deepEqual(silent, { ok: false, transport: 'cups', jobId: null, confirmed: false, error: 'The printer did not confirm the job', unconfirmed: true });
});

// ---- the outcome and the answers ----
test('jobOutcome: tracked, sent, unconfirmed, failed', () => {
  assert.equal(jobOutcome({ ok: true, transport: 'cups', jobId: 3, confirmed: true }).kind, 'tracked');
  assert.equal(jobOutcome({ ok: true, transport: 'bridge', jobId: null, confirmed: false }).kind, 'sent');
  // ok with a job id that is not confirmed is not followed by the monitor.
  assert.equal(jobOutcome({ ok: true, transport: 'cups', jobId: 3, confirmed: false }).kind, 'sent');
  assert.equal(jobOutcome({ ok: false, transport: 'cups', jobId: null, confirmed: false, unconfirmed: true }).kind, 'unconfirmed');
  assert.deepEqual(jobOutcome({ ok: false, transport: 'cups', jobId: null, confirmed: false, error: 'x' }), { kind: 'failed', error: 'x' });
  assert.equal(jobOutcome({ ok: false, transport: 'cups', jobId: null, confirmed: false }).error, 'The printer could not print the job');
});

test('printFailureBody: unconfirmed says so, with the row id or null; a failure carries PRINTER_FAILED and no unconfirmed flag', () => {
  const unconfirmed = printFailureBody({ kind: 'unconfirmed', row: { cups_job_id: null, status: 'unknown', error_message: UNCONFIRMED_NOTE } }, null);
  assert.equal(unconfirmed.success, false);
  assert.equal(unconfirmed.code, 'PRINT_UNCONFIRMED');
  assert.equal(unconfirmed.unconfirmed, true);
  assert.equal(unconfirmed.print_job_id, null);
  assert.equal(unconfirmed.error, 'The printer did not confirm the job');
  assert.match(unconfirmed.timestamp, /^\d{4}-\d\d-\d\dT/);
  assert.equal(printFailureBody({ kind: 'unconfirmed', row: { cups_job_id: null, status: 'unknown', error_message: UNCONFIRMED_NOTE } }, 'row-1').print_job_id, 'row-1');
  const failed = printFailureBody({ kind: 'failed', error: 'The print bridge refused the token' }, null);
  assert.deepEqual([failed.success, failed.code, failed.error, 'unconfirmed' in failed], [false, 'PRINTER_FAILED', 'The print bridge refused the token', false]);
});

test('configuredPrinterName: the setting, or the default when it is invalid (the send refuses it anyway)', () => {
  const previous = globalThis.Deno;
  const withEnv = values => { globalThis.Deno = { env: { get: name => values[name] } }; };
  try {
    withEnv({});
    assert.equal(configuredPrinterName(), 'LQ1310_RAW');
    withEnv({ PRINTER_NAME: 'Office_2' });
    assert.equal(configuredPrinterName(), 'Office_2');
    withEnv({ PRINT_TRANSPORT: 'bridge', PRINTER_NAME: 'EPSON LQ-1310' });
    assert.equal(configuredPrinterName(), 'EPSON LQ-1310');
    withEnv({ PRINTER_NAME: 'bad name/../' });
    assert.equal(configuredPrinterName(), 'LQ1310_RAW');
  } finally {
    if (previous === undefined) delete globalThis.Deno; else globalThis.Deno = previous;
  }
});
