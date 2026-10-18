import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { startService, render, rawRequest, formBody, fakePdf, sleep, waitFor } from './support.mjs';
import { isValidPdf, countPages } from '../src/render.mjs';

async function withService(options, fn) {
  const service = await startService(options);
  try { await fn(service); } finally { await service.stop(); }
}

test('a render returns the PDF with the right headers', () => withService({
  behavior: { render: async () => ({ pdf: fakePdf(3), pages: 3 }) },
}, async (s) => {
  const r = await render(s, { html: '<p>x</p>' });
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'application/pdf');
  assert.equal(Number(r.headers.get('content-length')), r.body.length);
  assert.ok(isValidPdf(r.body));
  const job = s.jobLogs()[0];
  assert.equal(job.outcome, 'ok');
  assert.equal(job.pages, 3);
  assert.equal(job.code, 200);
}));

test('defaults match the clients, and a footer raises the bottom margin to 1.0', () => withService({
  behavior: { render: async (job) => { seen.push(job); return { pdf: fakePdf(1), pages: 1 }; } },
}, async (s) => {
  await render(s, {});
  await render(s, { footer: '<p>f</p>' });
  await render(s, { footer: '<p>f</p>', fields: { marginBottom: 0.3 } });
  assert.deepEqual(seen[0].params, {
    paperWidth: 8.27, paperHeight: 11.69, marginTop: 0.39, marginRight: 0.55, marginBottom: 0.55, marginLeft: 0.55,
    landscape: false, printBackground: true, scale: 1, emulatedMediaType: 'print', preferCssPageSize: true,
  });
  assert.equal(seen[0].header, undefined);
  assert.equal(seen[0].footer, undefined);
  assert.equal(seen[1].params.marginBottom, 1.0);
  assert.equal(seen[1].footer, '<p>f</p>');
  assert.equal(seen[2].params.marginBottom, 0.3);
}));
const seen = [];
const ok = () => ({ pdf: fakePdf(1), pages: 1 });

test('fields are parsed: booleans, numbers, media type, waitDelay 0', () => withService({
  behavior: { render: async (job) => { seen.length = 0; seen.push(job); return { pdf: fakePdf(1), pages: 1 }; } },
}, async (s) => {
  const r = await render(s, { fields: { landscape: 'true', printBackground: 'false', scale: '0.5', emulatedMediaType: 'screen', preferCssPageSize: 'false', paperWidth: '5', paperHeight: '7', waitDelay: '0' } });
  assert.equal(r.status, 200);
  const p = seen[0].params;
  assert.equal(p.landscape, true);
  assert.equal(p.printBackground, false);
  assert.equal(p.scale, 0.5);
  assert.equal(p.emulatedMediaType, 'screen');
  assert.equal(p.preferCssPageSize, false);
  assert.equal(p.paperWidth, 5);
}));

const BAD = [
  ['no index.html', { files: [['footer.html', '<p/>']] }],
  ['duplicate index.html', { files: [['index.html', 'a'], ['index.html', 'b']] }],
  ['duplicate footer.html', { files: [['index.html', 'a'], ['footer.html', 'b'], ['footer.html', 'c']] }],
  ['other file name', { files: [['index.html', 'a'], ['evil.html', 'b']] }],
  ['unknown field', { fields: { pdfa: 'PDF/A-1b' } }],
  ['waitDelay 5s', { fields: { waitDelay: '5s' } }],
  ['scale too big', { fields: { scale: 3 } }],
  ['scale too small', { fields: { scale: 0.05 } }],
  ['scale not a number', { fields: { scale: 'big' } }],
  ['negative margin', { fields: { marginLeft: -0.1 } }],
  ['zero paper width', { fields: { paperWidth: 0 } }],
  ['negative paper height', { fields: { paperHeight: -1 } }],
  ['margins leave no room', { fields: { marginLeft: 5, marginRight: 4 } }],
  ['bad boolean', { fields: { landscape: 'yes' } }],
  ['bad media type', { fields: { emulatedMediaType: 'tv' } }],
];
for (const [name, options] of BAD) {
  test(`400: ${name}`, () => withService({}, async (s) => {
    const r = await render(s, options);
    assert.equal(r.status, 400, r.body.toString());
    const json = r.json();
    assert.equal(json.code, 400);
    assert.equal(typeof json.error, 'string');
    assert.equal(s.behavior.started.length, 0);
  }));
}

test('400: duplicate field and non-multipart body', () => withService({}, async (s) => {
  const form = formBody({});
  form.append('scale', '1');
  form.append('scale', '1');
  const dup = await fetch(`${s.url}/render`, { method: 'POST', body: form });
  assert.equal(dup.status, 400);
  const json = await fetch(`${s.url}/render`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  assert.equal(json.status, 400);
  const garbage = await rawRequest(s, { headers: { 'content-type': 'multipart/form-data; boundary=zzz' }, body: 'this is not multipart' });
  assert.equal(garbage.status, 400);
}));

test('unknown paths and methods', () => withService({}, async (s) => {
  assert.equal((await fetch(`${s.url}/nope`)).status, 404);
  assert.equal((await fetch(`${s.url}/render`)).status, 405);
}));

test('413 by Content-Length, before the body is read', () => withService({ config: { maxBodyBytes: 1024 * 1024 } }, async (s) => {
  const r = await rawRequest(s, {
    headers: { 'content-type': 'multipart/form-data; boundary=b', 'content-length': String(5 * 1024 * 1024) },
    body: 'only a few bytes',
  });
  assert.equal(r.status, 413);
  assert.equal(JSON.parse(r.body).code, 413);
  assert.equal(s.behavior.started.length, 0);
  assert.equal(s.supervisor.inflightBytes, 0);
}));

test('413 by streamed bytes when Content-Length is missing', () => withService({ config: { maxBodyBytes: 256 * 1024 } }, async (s) => {
  const chunk = Buffer.alloc(64 * 1024, 97);
  const r = await rawRequest(s, {
    headers: { 'content-type': 'multipart/form-data; boundary=b', 'transfer-encoding': 'chunked' },
    chunks: Array.from({ length: 12 }, () => chunk),
  });
  assert.equal(r.status, 413);
  await waitFor(() => s.supervisor.inflightBytes === 0, 2000, 'bytes released');
}));

test('a body that stops short of its Content-Length frees its bytes and renders nothing', () => withService({}, async (s) => {
  const net = await import('node:net');
  const socket = net.connect(Number(new URL(s.url).port), '127.0.0.1');
  await new Promise((resolve) => socket.once('connect', resolve));
  socket.write('POST /render HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: 100000\r\n\r\n--b\r\npartial');
  await waitFor(() => s.supervisor.inflightBytes === 100000, 2000, 'admitted with the declared bytes');
  socket.destroy();
  await waitFor(() => s.supervisor.inflightBytes === 0, 2000, 'bytes released');
  assert.equal(s.behavior.started.length, 0);
  assert.ok(s.jobLogs().some((j) => j.outcome === 'dropped'));
}));

test('an early refusal is delivered even while the client is still sending a large upload', () => withService({ config: { maxBodyBytes: 1024 * 1024 } }, async (s) => {
  const size = 20 * 1024 * 1024;
  const chunk = Buffer.alloc(64 * 1024, 97);
  const result = await new Promise((resolve, reject) => {
    const req = http.request(`${s.url}/render`, { method: 'POST', headers: { 'content-type': 'multipart/form-data; boundary=b', 'content-length': String(size) } }, (res) => {
      res.resume();
      res.on('end', () => resolve({ status: res.statusCode }));
    });
    req.on('error', reject); // an EPIPE / reset here is the failure this test guards against
    let sent = 0;
    const pump = () => {
      while (sent < size) {
        sent += chunk.length;
        if (!req.write(chunk)) { req.once('drain', pump); return; }
      }
      req.end();
    };
    pump();
  });
  assert.equal(result.status, 413);
  const refusal = s.jobLogs().find((j) => j.code === 413);
  assert.ok(refusal, 'the refusal has a job log line');
  assert.equal(refusal.outcome, 'refused');
}));

test('refusals are logged as job lines: wrong content type, queue full', () => withService({
  config: { concurrency: 1, maxQueue: 1 },
  behavior: { render: () => sleep(300).then(ok) },
}, async (s) => {
  await fetch(`${s.url}/render`, { method: 'POST', headers: { 'content-type': 'text/plain' }, body: 'x' });
  const all = await Promise.all([render(s, {}), render(s, {}), render(s, {}), render(s, {})]);
  assert.ok(all.some((r) => r.status === 503));
  const refused = s.jobLogs().filter((j) => j.outcome === 'refused');
  assert.ok(refused.some((j) => j.code === 400));
  assert.ok(refused.some((j) => j.code === 503));
}));

test('Expect: 100-continue is refused before the client is told to send the body', () => withService({ config: { maxBodyBytes: 1024 * 1024 } }, async (s) => {
  const net = await import('node:net');
  const socket = net.connect(Number(new URL(s.url).port), '127.0.0.1');
  await new Promise((resolve) => socket.once('connect', resolve));
  let received = '';
  socket.on('data', (d) => { received += d.toString('latin1'); });
  socket.write('POST /render HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: 5000000\r\n\r\n');
  await waitFor(() => received.includes('HTTP/1.1'), 2000, 'a response');
  socket.destroy();
  assert.ok(received.startsWith('HTTP/1.1 413'), received.slice(0, 40));
  assert.ok(!received.includes('100 Continue'));
}));

test('Expect: 100-continue is answered only when the request is granted a slot', () => withService({
  config: { concurrency: 1 },
  behavior: { render: () => sleep(300).then(ok) },
}, async (s) => {
  const net = await import('node:net');
  const first = render(s, { html: '<p>1</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'first running');
  const socket = net.connect(Number(new URL(s.url).port), '127.0.0.1');
  await new Promise((resolve) => socket.once('connect', resolve));
  let received = '';
  socket.on('data', (d) => { received += d.toString('latin1'); });
  socket.write('POST /render HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: 2000\r\n\r\n');
  await waitFor(() => s.supervisor.queue.length === 1, 1000, 'queued');
  assert.equal(received, '', 'no 100 Continue while the request waits');
  await waitFor(() => received.includes('100 Continue'), 3000, '100 Continue after the slot was granted');
  socket.destroy();
  await first;
}));

test('a waiting request is not read: its body stays on the socket until a slot is free', () => withService({
  config: { concurrency: 1, maxBodyBytes: 100 * 1024 * 1024, maxQueueBytes: 200 * 1024 * 1024 },
  behavior: { render: (job) => (job.html.length < 1000 ? new Promise((resolve) => { release = () => resolve(ok()); }) : Promise.resolve(ok())) },
}, async (s) => {
  const first = render(s, { html: '<p>hold the slot</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'first running');
  const html = 'x'.repeat(40 * 1024 * 1024);
  const form = formBody({ html });
  const asResponse = new Response(form);
  const type = asResponse.headers.get('content-type');
  const bodyBuf = Buffer.from(await asResponse.arrayBuffer());
  const req = http.request(`${s.url}/render`, { method: 'POST', headers: { 'content-type': type, 'content-length': String(bodyBuf.length) } });
  const done = new Promise((resolve, reject) => { req.on('response', (res) => { res.resume(); res.on('end', () => resolve(res.statusCode)); }); req.on('error', reject); });
  req.write(bodyBuf);
  req.end();
  await waitFor(() => s.supervisor.queue.length === 1, 2000, 'second queued');
  await sleep(400);
  // Kernel buffers hold a few MB at most; the rest cannot have been accepted while nothing reads.
  // bytesWritten counts what was handed to the socket; writableLength is what the kernel has NOT accepted yet.
  assert.ok(req.socket.writableLength > 20 * 1024 * 1024, `only ${req.socket.writableLength} bytes were still waiting to be sent: the server read the body of a request that was not granted a slot`);
  assert.equal(s.supervisor.queue.length, 1);
  release();
  assert.equal((await first).status, 200);
  assert.equal(await done, 200);
  assert.equal(s.behavior.started.length, 2);
}));
let release;

test('a chunked body of unknown length counts as a large one and runs alone', () => withService({
  config: { concurrency: 2 },
  behavior: { render: () => sleep(150).then(ok) },
}, async (s) => {
  const form = formBody({ html: '<p>chunked</p>' });
  const response = new Response(form);
  const type = response.headers.get('content-type');
  const bytes = Buffer.from(await response.arrayBuffer());
  const chunked = rawRequest(s, { headers: { 'content-type': type, 'transfer-encoding': 'chunked' }, chunks: [bytes] });
  const normal = render(s, { html: '<p>normal</p>' });
  const [c, n] = await Promise.all([chunked, normal]);
  assert.equal(c.status, 200);
  assert.equal(n.status, 200);
  assert.equal(s.behavior.maxActive, 1, 'the chunked body ran alone');
}));

test('deadline during a stalled upload answers 504 once and the server stays healthy', () => withService({ config: { deadlineMs: 150 } }, async (s) => {
  const net = await import('node:net');
  const socket = net.connect(Number(new URL(s.url).port), '127.0.0.1');
  await new Promise((resolve) => socket.once('connect', resolve));
  let received = '';
  socket.on('data', (d) => { received += d.toString('latin1'); });
  socket.write('POST /render HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: 5000\r\n\r\n--b\r\n');
  await waitFor(() => received.includes('HTTP/1.1 504'), 2000, '504');
  socket.write('garbage that does not parse');
  await sleep(100);
  socket.destroy();
  assert.equal((received.match(/HTTP\/1\.1 /g) || []).length, 1, 'answered exactly once');
  assert.ok(!s.events().some((e) => e.event === 'request_error'));
  assert.equal(s.supervisor.health().body.status, 'up');
  assert.equal(s.supervisor.inflightBytes, 0);
}));

test('503 when the queue is full', () => withService({
  config: { concurrency: 1, maxQueue: 2 },
  behavior: { render: () => sleep(400).then(() => ({ pdf: fakePdf(1), pages: 1 })) },
}, async (s) => {
  const all = Array.from({ length: 5 }, (_, i) => render(s, { html: `<p>${i}</p>` }));
  const results = await Promise.all(all);
  const statuses = results.map((r) => r.status).sort();
  assert.deepEqual(statuses, [200, 200, 200, 503, 503]);
  const refused = results.find((r) => r.status === 503);
  assert.equal(refused.json().code, 503);
}));

test('503 when queued and in-flight bytes pass the limit', () => withService({
  config: { concurrency: 1, maxQueueBytes: 1024 * 1024, maxBodyBytes: 1024 * 1024, soloBodyBytes: 100 * 1024 * 1024 },
  behavior: { render: () => sleep(300).then(() => ({ pdf: fakePdf(1), pages: 1 })) },
}, async (s) => {
  const big = 'x'.repeat(700 * 1024);
  const first = render(s, { html: big });
  await waitFor(() => s.supervisor.inflightBytes > 0, 1000, 'first admitted');
  const second = await render(s, { html: big });
  assert.equal(second.status, 503);
  assert.equal((await first).status, 200);
  const third = await render(s, { html: big });
  assert.equal(third.status, 200);
  assert.equal(s.supervisor.inflightBytes, 0);
}));

test('PDF validation: a result that is not a PDF becomes 500', () => withService({
  behavior: { render: async () => ({ pdf: Buffer.from('<html>not a pdf, but long enough to pass the length check</html>'), pages: 0 }) },
}, async (s) => {
  const r = await render(s, {});
  assert.equal(r.status, 500);
  assert.equal(r.json().code, 500);
}));

test('PDF validation: a truncated PDF (no %%EOF) becomes 500', () => withService({
  behavior: { render: async () => ({ pdf: fakePdf(1).subarray(0, 60), pages: 1 }) },
}, async (s) => {
  assert.equal((await render(s, {})).status, 500);
}));

test('isValidPdf and countPages', () => {
  assert.equal(isValidPdf(fakePdf(2)), true);
  assert.equal(isValidPdf(Buffer.from('%PDF-1.7 short')), false);
  assert.equal(isValidPdf(Buffer.concat([fakePdf(1), Buffer.from('\r\n')])), true);
  assert.equal(countPages(fakePdf(4)), 4);
});

test('an engine error that is not a crash becomes 500', () => withService({
  behavior: { render: async () => { throw new Error('printToPDF failed'); } },
}, async (s) => {
  const r = await render(s, {});
  assert.equal(r.status, 500);
  assert.equal(s.supervisor.health().body.status, 'up');
}));

test('logs hold ids and counters but never HTML', () => withService({
  behavior: { render: async (job) => { if (job.html.includes('FAIL')) throw new Error('boom'); return { pdf: fakePdf(1), pages: 1 }; } },
}, async (s) => {
  const secret = 'SECRET-DOCUMENT-TEXT-12345';
  await render(s, { html: `<p>${secret}</p>`, header: `<p>${secret}</p>`, footer: `<p>${secret}</p>` });
  await render(s, { html: `<p>${secret} FAIL</p>` });
  await render(s, { html: '<p>x</p>', fields: { [secret]: '1' } });
  const text = s.lines.join('\n');
  assert.ok(!text.includes(secret.slice(0, 20)), 'log must not contain document text');
  assert.ok(!text.includes('<p>'), 'log must not contain HTML');
  const job = s.jobLogs()[0];
  for (const key of ['id', 'bytes', 'pages', 'queueMs', 'renderMs', 'outcome', 'code']) assert.ok(key in job, `job log has ${key}`);
}));

test('health answers from cached state', () => withService({}, async (s) => {
  const res = await fetch(`${s.url}/health`);
  assert.equal(res.status, 200);
  const json = await res.json();
  assert.equal(json.status, 'up');
  assert.equal(json.chromium.version, 'FakeChrome/1.0');
  for (const key of ['jobs', 'restarts', 'queue', 'inflightBytes', 'memoryMB']) assert.equal(typeof json.chromium[key], 'number');
}));

test('server timeouts are set as specified', () => withService({}, async (s) => {
  assert.equal(s.server.keepAliveTimeout, 65000);
  assert.equal(s.server.headersTimeout, 66000);
}));
