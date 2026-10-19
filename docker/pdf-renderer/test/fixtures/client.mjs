// Runs inside a node:24 container on the test network: a plain `fetch` client (undici, no Expect: 100-continue) as the
// edge functions are. Fills the queue of a renderer started with CONCURRENCY=1 MAX_QUEUE=1 and checks that every refusal
// is READ as a status and a JSON body, not seen as a network error.
//   node client.mjs <base-url> <big.html>
import fs from 'node:fs';

const [base, bigPath] = process.argv.slice(2);
const MiB = 1024 * 1024;
let fails = 0;
const check = (name, ok, detail = '') => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : ` (${detail})`}`); if (!ok) fails += 1; };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const big = fs.readFileSync(bigPath);
const form = (html) => { const f = new FormData(); f.append('files', new Blob([html]), 'index.html'); return f; };
const post = (init) => fetch(`${base}/render`, { method: 'POST', ...init });
const read = async (res) => { const text = Buffer.from(await res.arrayBuffer()); return { status: res.status, type: res.headers.get('content-type'), text }; };

const running = post({ body: form(big) }).then(read);
const queued = post({ body: form(big) }).then(read);
for (let i = 0; i < 100; i += 1) {
  const h = await (await fetch(`${base}/health`)).json();
  if (h.chromium.queue === 1) break;
  await sleep(50);
}

// 1. queue full: six overflow uploads of 5 MiB each
const pad = Buffer.concat([Buffer.from('<p>overflow</p>'), Buffer.alloc(5 * MiB, 32)]);
const overflow = await Promise.allSettled(Array.from({ length: 6 }, () => post({ body: form(pad) }).then(read)));
const errors = overflow.filter((r) => r.status === 'rejected');
check('queue overflow: no network errors', errors.length === 0, errors.map((e) => `${e.reason && e.reason.message}/${e.reason && e.reason.cause && e.reason.cause.code}`).join(', '));
const ok503 = overflow.filter((r) => r.status === 'fulfilled' && r.value.status === 503);
check('queue overflow: every request got status 503', ok503.length === 6, overflow.map((r) => (r.status === 'fulfilled' ? r.value.status : 'ERR')).join(','));
check('queue overflow: the 503 has the JSON error body', ok503.every((r) => { try { const j = JSON.parse(r.value.text.toString()); return j.code === 503 && typeof j.error === 'string'; } catch { return false; } }));

// 2. the admitted ones still finish
const [a, b] = await Promise.all([running, queued]);
check('the running and the queued job both returned a PDF', a.status === 200 && b.status === 200 && a.text.subarray(0, 5).toString() === '%PDF-' && b.text.subarray(0, 5).toString() === '%PDF-', `${a.status}/${b.status}`);

// 3. 413 by header: 48 MiB + 1 byte, not read
const tooBig = await post({ headers: { 'content-type': 'multipart/form-data; boundary=x' }, body: Buffer.alloc(48 * MiB + 1, 97) }).then(read).catch((e) => ({ status: `ERR ${e.message}` }));
check('48 MiB + 1 byte: status 413 (not a network error)', tooBig.status === 413, tooBig.status);
if (tooBig.text) { let j = {}; try { j = JSON.parse(tooBig.text.toString()); } catch { /* not JSON */ } check('413 has the JSON error body', j.code === 413 && typeof j.error === 'string'); }

// 4. exactly 48 MiB is accepted for reading (it is not valid multipart, so 400, never 413)
const exact = await post({ headers: { 'content-type': 'multipart/form-data; boundary=x' }, body: Buffer.alloc(48 * MiB, 97) }).then(read).catch((e) => ({ status: `ERR ${e.message}` }));
check('exactly 48 MiB is not refused for size (invalid multipart gives 400)', exact.status === 400, exact.status);

// 5. wrong content type with a 5 MiB body
const wrongType = await post({ headers: { 'content-type': 'text/plain' }, body: Buffer.alloc(5 * MiB, 97) }).then(read).catch((e) => ({ status: `ERR ${e.message}` }));
check('wrong content type with a 5 MiB body: status 400 (not a network error)', wrongType.status === 400, wrongType.status);

process.exit(fails ? 1 : 0);
