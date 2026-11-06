import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { baseEnvironment, fakeCups, json, loadFunction, profileAnswer, signToken, withFetch } from './print-harness.mjs';

// WH-109 part 1: get-printer-status on the Windows print bridge asks GET <PRINTBRIDGE_URL>/health (X-Print-Token, X-Printer) and maps
// the answer; on CUPS it asks the configured queue. The real handler runs; the bridge is a real HTTP server on 127.0.0.1 and CUPS a
// fake IPP server, and the profile lookup is answered by the fetch stand-in.
const TOKEN = 'unit-test-bridge-token-0123456789abcdef';
const realFetch = globalThis.fetch;

async function bridge(answer) {
  const seen = [];
  const sockets = new Set();
  const server = createServer((request, response) => { seen.push({ method: request.method, url: request.url, headers: request.headers }); answer(request, response); });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { seen, url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise(resolve => { for (const socket of sockets) socket.destroy(); server.close(resolve); }) };
}
const reply = (status, body) => (_request, response) => { response.writeHead(status, { 'Content-Type': 'application/json' }); response.end(typeof body === 'string' ? body : JSON.stringify(body)); };

async function status({ environment, role = 'staff', request = {} }) {
  const handler = await loadFunction('get-printer-status', environment);
  return await withFetch(async ({ url, method, headers, body }) => {
    if (url.includes('/user_profiles?')) return profileAnswer(role);
    if (url.startsWith('http://127.0.0.1:')) return realFetch(url, { method, headers, signal: AbortSignal.timeout(8000), redirect: 'error' });
    throw new Error(`unexpected request ${url}`);
  }, async () => {
    const response = await handler(new Request('http://edge.test/get-printer-status', {
      method: 'POST', headers: { Authorization: `Bearer ${await signToken()}`, 'Content-Type': 'application/json' }, body: JSON.stringify(request),
    }));
    return { response, answer: await response.json() };
  });
}
const bridgeEnv = (url, extra = {}) => baseEnvironment({ PRINT_TRANSPORT: 'bridge', PRINTER_NAME: 'LQ1310_RAW', PRINTBRIDGE_URL: url, PRINTBRIDGE_TOKEN: TOKEN, ...extra });

test('bridge online: GET /health with the token and the printer; the caller\'s Authorization is not forwarded', async () => {
  const server = await bridge(reply(200, { success: true, printer: 'LQ1310_RAW', printer_found: true, status: 'Normal' }));
  try {
    const { response, answer } = await status({ environment: bridgeEnv(server.url), request: { printer_name: 'SomethingElse' } });
    assert.equal(response.status, 200);
    assert.deepEqual([answer.success, answer.status, answer.transport, answer.message, answer.printer_name, answer.printer_status],
      [true, 'online', 'bridge', 'Print bridge reachable', 'LQ1310_RAW', 'Normal']);
    assert.equal(server.seen.length, 1);
    assert.equal(server.seen[0].method, 'GET');
    assert.equal(server.seen[0].url, '/health');
    assert.equal(server.seen[0].headers['x-print-token'], TOKEN);
    assert.equal(server.seen[0].headers['x-printer'], 'LQ1310_RAW', 'a printer_name in the request is ignored');
    assert.equal(server.seen[0].headers.authorization, undefined);
    assert.ok(!JSON.stringify(answer).includes(TOKEN));
  } finally { await server.close(); }
});

test('bridge: spooler states that mean trouble are status error with the state in the message; ordinary ones are online', async () => {
  const problems = ['Offline', 'Paused', 'Error', 'Paper Jam', 'Jammed', 'Paper Out', 'Toner Low', 'No Toner', 'Door Open', 'User Intervention Required', 'Not Available', 'Pending Deletion'];
  const fine = ['Normal', 'Idle', 'Printing', 'Warming Up', 'Busy', 'Initializing'];
  for (const [spooler, expected] of [...problems.map(s => [s, 'error']), ...fine.map(s => [s, 'online'])]) {
    const server = await bridge(reply(200, { success: true, printer_found: true, status: spooler }));
    try {
      const { response, answer } = await status({ environment: bridgeEnv(server.url) });
      assert.equal(response.status, 200, spooler);
      assert.equal(answer.status, expected, spooler);
      assert.equal(answer.success, true);
      if (expected === 'error') assert.equal(answer.message, `Print bridge reachable, the printer reports: ${spooler}`);
    } finally { await server.close(); }
  }
});

test('bridge: a missing spooler state is online; a long one is cut at 60 characters; a non-text one is dropped', async () => {
  for (const [value, expected] of [[undefined, undefined], [5, undefined], ['x'.repeat(200), 'x'.repeat(60)]]) {
    const server = await bridge(reply(200, { success: true, printer_found: true, status: value }));
    try {
      const { answer } = await status({ environment: bridgeEnv(server.url) });
      assert.equal(answer.status, 'online');
      assert.equal(answer.printer_status, expected);
    } finally { await server.close(); }
  }
});

test('bridge: the Windows printer is not installed (printer_found false, the bridge answers 503): reachable, status error, 200', async () => {
  const server = await bridge(reply(503, { success: false, printer: 'LQ1310_RAW', printer_found: false, error: 'Printer not found' }));
  try {
    const { response, answer } = await status({ environment: bridgeEnv(server.url) });
    assert.equal(response.status, 200);
    assert.deepEqual([answer.success, answer.status, answer.message], [true, 'error', 'Print bridge reachable, but the Windows printer is not installed']);
  } finally { await server.close(); }
});

test('bridge: 401 and 403 mean the token was refused: 502 status error', async () => {
  for (const code of [401, 403]) {
    const server = await bridge(reply(code, { success: false }));
    try {
      const { response, answer } = await status({ environment: bridgeEnv(server.url) });
      assert.equal(response.status, 502, String(code));
      assert.deepEqual([answer.success, answer.status, answer.error], [false, 'error', 'The print bridge refused the token']);
    } finally { await server.close(); }
  }
});

test('bridge: no answer, a server error, a body that is not JSON or does not say found: 503 offline "did not answer"', async () => {
  const cases = [reply(500, { success: false }), reply(200, 'OK'), reply(200, { success: false, printer_found: true }), reply(200, { success: true }),
    reply(200, { success: true, printer_found: 'yes' }), reply(404, { success: true, printer_found: true })];
  for (const answerFn of cases) {
    const server = await bridge(answerFn);
    try {
      const { response, answer } = await status({ environment: bridgeEnv(server.url) });
      assert.equal(response.status, 503);
      assert.deepEqual([answer.success, answer.status, answer.error], [false, 'offline', 'The print bridge did not answer']);
    } finally { await server.close(); }
  }
  const closed = await bridge(reply(200, {}));
  const url = closed.url;
  await closed.close();
  const { response, answer } = await status({ environment: bridgeEnv(url) });
  assert.equal(response.status, 503);
  assert.equal(answer.status, 'offline');
});

test('bridge: without the token or a valid address the bridge is not called: 503 "not configured"', async () => {
  const server = await bridge(reply(200, { success: true, printer_found: true }));
  try {
    for (const extra of [{ PRINTBRIDGE_TOKEN: '' }, { PRINTBRIDGE_TOKEN: '  ' }, { PRINTBRIDGE_URL: '' }, { PRINTBRIDGE_URL: 'ftp://127.0.0.1:1' }, { PRINTBRIDGE_URL: `${server.url}/health` }]) {
      const { response, answer } = await status({ environment: bridgeEnv(server.url, extra) });
      assert.equal(response.status, 503, JSON.stringify(extra));
      assert.deepEqual([answer.success, answer.status, answer.transport, answer.error], [false, 'error', 'bridge', 'The print bridge is not configured']);
    }
    assert.equal(server.seen.length, 0);
  } finally { await server.close(); }
});

test('a customer is refused (403 PRINT_FORBIDDEN) before any printer is asked; PRINT_TRANSPORT other than cups or bridge is 503', async () => {
  const server = await bridge(reply(200, { success: true, printer_found: true }));
  try {
    const refused = await status({ environment: bridgeEnv(server.url), role: 'customer' });
    assert.deepEqual([refused.response.status, refused.answer.code], [403, 'PRINT_FORBIDDEN']);
    const unknown = await status({ environment: bridgeEnv(server.url, { PRINT_TRANSPORT: 'usb' }) });
    assert.equal(unknown.response.status, 503);
    assert.equal(server.seen.length, 0);
  } finally { await server.close(); }
});

test('cups: Get-Printer-Attributes on the configured queue; an idle printer that accepts jobs is online', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok', 'printer-attributes-tag': {
    'printer-state': 'idle', 'printer-state-reasons': 'none', 'printer-is-accepting-jobs': true, 'queued-job-count': 0,
  } }));
  try {
    const { response, answer } = await status({ environment: baseEnvironment({ PRINT_TRANSPORT: 'cups', PRINTER_NAME: 'LQ1310_RAW' }), request: { printer_name: 'Other' } });
    assert.equal(response.status, 200, JSON.stringify(answer));
    assert.deepEqual([answer.success, answer.status, answer.transport, answer.printer_name], [true, 'online', 'cups', 'LQ1310_RAW']);
    assert.equal(cups.requests[0].operation, 'Get-Printer-Attributes');
    assert.equal(cups.requests[0].path, '/printers/LQ1310_RAW', 'the request cannot choose another queue');
  } finally { await cups.close(); }
});

test('cups: a reply without the printer attributes is 502 status error, never "ready"', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok' }));
  try {
    const { response, answer } = await status({ environment: baseEnvironment({ PRINT_TRANSPORT: 'cups' }) });
    assert.equal(response.status, 502);
    assert.deepEqual([answer.success, answer.status], [false, 'error']);
  } finally { await cups.close(); }
});
