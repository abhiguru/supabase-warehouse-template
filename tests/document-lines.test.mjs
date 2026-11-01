import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { restClient } from '../functions/_shared/supabase-rest.ts';
import { MAX_PDF_ROWS, PDF_PAGE_ROWS, PDF_TOO_LONG, readDocumentLines } from '../functions/_shared/document-lines.ts';
import { documentHtml } from '../functions/_shared/document-html.ts';

// A fake PostgREST holding `total` lines: it honours the Range header like PostgREST (a page of at most the asked size, Content-Range
// "from-to/total" when the count is asked) and records every request. Pages of the real server are capped, so a request for more
// than 1000 rows is answered with 1000 here too, as the stack's PGRST_DB_MAX_ROWS does.
function fakeRest(total, { shortAfter } = {}) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const range = init.headers.Range;
    calls.push({ url: String(url), headers: init.headers });
    if (!range) return new Response(JSON.stringify([]), { status: 200 });
    const [from, to] = range.split('-').map(Number);
    const last = Math.min(to, from + 999, total - 1, shortAfter ?? Infinity);
    const rows = [];
    for (let i = from; i <= last; i++) rows.push({ id: `id-${String(i).padStart(5, '0')}`, n: i });
    const headers = init.headers.Prefer === 'count=exact' ? { 'content-range': `${rows.length ? `${from}-${last}` : '*'}/${total}` } : {};
    return new Response(JSON.stringify(rows), { status: 206, headers });
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}
const read = async () => (await readDocumentLines(restClient('http://gateway:8000', 'k'), 'invoice_trl', 'id,n', query => query.eq('invoice_id', 'inv1'))).data;

test('3,055 lines come in four ordered pages with the right Range headers, and none is lost or repeated', async () => {
  const fake = fakeRest(3055);
  try {
    const lines = await read();
    assert.equal(lines.length, 3055);
    assert.deepEqual(lines.map(line => line.n), Array.from({ length: 3055 }, (_, i) => i));
    assert.deepEqual(fake.calls.map(call => call.headers.Range), ['0-999', '1000-1999', '2000-2999', '3000-3999']);
    for (const call of fake.calls) {
      assert.equal(call.headers['Range-Unit'], 'items');
      assert.match(call.url, /\?select=id%2Cn&invoice_id=eq\.inv1&order=id\.asc$/, 'every page has the same filter and the id order');
    }
    assert.deepEqual(fake.calls.map(call => call.headers.Prefer), ['count=exact', undefined, undefined, undefined], 'only the first page asks for the count');
  } finally { fake.restore(); }
});

test('exactly the limit passes; one line more is refused with the new message after the first page only', async () => {
  const atLimit = fakeRest(MAX_PDF_ROWS);
  try {
    assert.equal((await read()).length, MAX_PDF_ROWS);
    assert.equal(atLimit.calls.length, Math.ceil(MAX_PDF_ROWS / PDF_PAGE_ROWS));
  } finally { atLimit.restore(); }
  const over = fakeRest(MAX_PDF_ROWS + 1);
  try {
    await assert.rejects(read(), { status: 400, message: PDF_TOO_LONG });
    assert.equal(over.calls.length, 1, 'no further page is fetched');
    assert.equal(PDF_TOO_LONG, `Document exceeds the limit of ${MAX_PDF_ROWS.toLocaleString('en-US')} lines`);
  } finally { over.restore(); }
});

test('a page that is full at exactly the count stops without asking for an empty page', async () => {
  const fake = fakeRest(2000);
  try {
    assert.equal((await read()).length, 2000);
    assert.equal(fake.calls.length, 2);
  } finally { fake.restore(); }
});

test('a short page stops the reading even when the count promised more', async () => {
  const fake = fakeRest(3055, { shortAfter: 1499 });
  try {
    assert.equal((await read()).length, 1500);
    assert.equal(fake.calls.length, 2);
  } finally { fake.restore(); }
});

test('a document without lines is empty and takes one request', async () => {
  const fake = fakeRest(0);
  try {
    assert.deepEqual(await read(), []);
    assert.equal(fake.calls.length, 1);
  } finally { fake.restore(); }
});

test('a failed page is 503 and an unreadable answer is 503', async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async () => new Response(JSON.stringify({ message: 'boom' }), { status: 500 });
    await assert.rejects(read(), { status: 503, message: 'Document items unavailable' });
    globalThis.fetch = async () => new Response('{}', { status: 200 });
    await assert.rejects(read(), { status: 503, message: 'Document items unavailable' });
  } finally { globalThis.fetch = original; }
});

test('the four documents read their lines through readDocumentLines and no read carries limit(1001) any more', () => {
  const source = readFileSync(new URL('../functions/_shared/document-pdf.ts', import.meta.url), 'utf8');
  assert.equal(source.match(/readDocumentLines\(reader,'/g).length, 4);
  assert.doesNotMatch(source, /limit\(1001\)|starter limit/);
});

test('the document table keeps a row on one page (the header repeats by the browser default, pinned by the invoice-long golden)', () => {
  const html = documentHtml('INVOICE', 'Co', {}, ['Item'], [['a']]);
  // The browser's default for a thead is to repeat on every page; tests/golden-pdf/golden/invoice-long pins it (99 pages).
  assert.match(html, /tr\{break-inside:avoid\}/);
  assert.doesNotMatch(html, /thead\{display:none/);
});
