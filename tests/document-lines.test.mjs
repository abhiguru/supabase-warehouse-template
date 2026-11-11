import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { restClient } from '../functions/_shared/supabase-rest.ts';
import { MAX_PDF_ROWS, PDF_CHANGED, PDF_PAGE_ROWS, PDF_TOO_LONG, documentLineOrder, readDocumentLines, uuidTimeKey } from '../functions/_shared/document-lines.ts';
import { MAX_PDF_PAGES, SOLO_PDF_PAGES, estimatePages } from '../functions/_shared/document-pages.ts';
import { documentHtml } from '../functions/_shared/document-html.ts';

const rowId = i => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;

// A fake PostgREST holding rows with ids in order. It answers a keyset read like PostgREST: `id=gt.<id>` drops rows up to that id, `limit` caps the
// page, and with Prefer: count=exact the Content-Range carries "from-to/<count>". `count` is what it reports (default: the rows it holds),
// `noCount` sends no Content-Range, `rows` replaces the held rows, `duplicate` repeats the last row of the page before at the start of the next.
function fakeRest(total, { rows, count, noCount = false, duplicate = false } = {}) {
  const held = rows ?? Array.from({ length: total }, (_, i) => ({ id: rowId(i), n: i }));
  const calls = [];
  const original = globalThis.fetch;
  let previousLast = null;
  globalThis.fetch = async (url, init) => {
    const params = new URL(String(url)).searchParams;
    calls.push({ url: String(url), headers: init.headers, params });
    const after = params.get('id')?.replace(/^gt\./, '');
    let page = held.filter(row => after === undefined || row.id > after).slice(0, Number(params.get('limit')));
    if (duplicate && after !== undefined && previousLast) page = [previousLast, ...page];
    previousLast = page[page.length - 1] ?? previousLast;
    const headers = init.headers.Prefer === 'count=exact' && !noCount ? { 'content-range': `${page.length ? `0-${page.length - 1}` : '*'}/${count ?? held.length}` } : {};
    return new Response(JSON.stringify(page), { status: 200, headers });
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}
const read = async (kind = 'grn') => (await readDocumentLines(restClient('http://gateway:8000', 'k'), kind, 'invoice_trl', 'n', query => query.eq('invoice_id', 'inv1'))).data;

test('3,055 lines come in four keyset pages, ordered by id, and none is lost or repeated', async () => {
  const fake = fakeRest(3055);
  try {
    const lines = await read();
    assert.deepEqual(lines.map(line => line.n), Array.from({ length: 3055 }, (_, i) => i));
    assert.equal(fake.calls.length, 4);
    for (const call of fake.calls) {
      assert.equal(call.params.get('select'), 'id,n');
      assert.equal(call.params.get('invoice_id'), 'eq.inv1');
      assert.equal(call.params.get('order'), 'id.asc');
      assert.equal(call.params.get('limit'), String(PDF_PAGE_ROWS));
      assert.equal(call.headers.Range, undefined, 'no Range header: a keyset page is a filter');
    }
    assert.deepEqual(fake.calls.map(call => call.params.get('id')), [null, `gt.${rowId(999)}`, `gt.${rowId(1999)}`, `gt.${rowId(2999)}`]);
    assert.deepEqual(fake.calls.map(call => call.headers.Prefer), ['count=exact', undefined, undefined, undefined], 'only the first page asks for the count');
  } finally { fake.restore(); }
});

test('exactly the limit passes; one line more is refused with the limit message after the first page only', async () => {
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

test('without a count, more lines than the limit are still refused (400) once they are read', async () => {
  const fake = fakeRest(MAX_PDF_ROWS + 100, { noCount: true });
  try {
    await assert.rejects(read(), { status: 400, message: PDF_TOO_LONG });
    assert.equal(fake.calls.length, 4, 'read until the lines pass the limit');
  } finally { fake.restore(); }
  const within = fakeRest(1500, { noCount: true });
  try { assert.equal((await read()).length, 1500); } finally { within.restore(); }
});

test('a page that is full at exactly the count stops without asking for an empty page', async () => {
  const fake = fakeRest(2000);
  try {
    assert.equal((await read()).length, 2000);
    assert.equal(fake.calls.length, 2);
  } finally { fake.restore(); }
});

test('a short page with lines still missing from the count is the 503 "changed while printing"; so is a count that was passed', async () => {
  const missing = fakeRest(1500, { count: 3055 });
  try {
    await assert.rejects(read(), { status: 503, message: PDF_CHANGED });
    assert.equal(missing.calls.length, 2, 'it stops at the short page');
  } finally { missing.restore(); }
  assert.equal(PDF_CHANGED, 'The document changed while printing. Try again.');
  const grown = fakeRest(1250, { count: 1200 });
  try { await assert.rejects(read(), { status: 503, message: PDF_CHANGED }); } finally { grown.restore(); }
});

test('a line repeated across a page boundary is printed once', async () => {
  const fake = fakeRest(1500, { duplicate: true });
  try {
    const lines = await read();
    assert.equal(lines.length, 1500);
    assert.equal(new Set(lines.map(line => line.id)).size, 1500);
  } finally { fake.restore(); }
});

test('a server that ignores the id filter cannot make the reading repeat for ever: it ends in the 503', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url, init) => {
    calls++;
    const rows = Array.from({ length: PDF_PAGE_ROWS }, (_, i) => ({ id: rowId(i), n: i }));
    return new Response(JSON.stringify(rows), { status: 200, headers: init.headers.Prefer === 'count=exact' ? { 'content-range': '0-999/3000' } : {} });
  };
  try {
    await assert.rejects(read(), { status: 503, message: PDF_CHANGED });
    assert.equal(calls, 2);
  } finally { globalThis.fetch = original; }
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

// uuid v1 id of a moment: the time sits in the first groups in a different order, so the id order is not the time order.
const v1 = (micros, tail) => {
  const ticks = BigInt(micros) * 10n + 0x01B21DD213814000n;
  const hex = ticks.toString(16).padStart(15, '0');
  return `${hex.slice(7, 15)}-${hex.slice(3, 7)}-1${hex.slice(0, 3)}-8000-${String(tail).padStart(12, '0')}`;
};

test('uuidTimeKey is the microsecond uuid_extract_timestamp gives, and null for an id without a time', () => {
  assert.equal(uuidTimeKey('c232ab00-9414-11ec-b3c8-9f6bdeced846'), BigInt(Date.UTC(2022, 1, 22, 19, 22, 22)) * 1000n);
  assert.equal(uuidTimeKey(v1(1700000000123456, 1)), 1700000000123456n);
  assert.equal(uuidTimeKey('017f22e2-79b0-7cc3-98c4-dc0c0c07398f'), 1645557742000n * 1000n);
  assert.equal(uuidTimeKey(rowId(1)), null);
  assert.equal(uuidTimeKey(null), null);
});

test('each kind lists its lines in its screen order: a GRN and the stock by id, a dispatch and an invoice by the time in the id, then the id', async () => {
  // The server order is by id, which is not the order of the times here.
  const early = v1(1700000000000000, 9); const late = v1(1700000500000000, 1); const tieA = v1(1700000900000000, 2); const tieB = v1(1700000900000000, 3);
  const none = rowId(5);
  const held = [early, late, tieA, tieB, none].map((id, n) => ({ id, n })).sort((a, b) => (a.id < b.id ? -1 : 1));
  assert.notDeepEqual(held.map(line => line.id), [early, late, tieA, tieB, none], 'the ids by id are not in time order');
  const byId = held.map(line => line.id);
  const expected = { grn: byId, stock: byId, dispatch: [early, late, tieA, tieB, none], invoice: [early, late, tieA, tieB, none] };
  for (const kind of Object.keys(expected)) {
    const fake = fakeRest(0, { rows: held });
    try { assert.deepEqual((await read(kind)).map(line => line.id), expected[kind], kind); } finally { fake.restore(); }
  }
  assert.deepEqual(Object.keys(documentLineOrder).sort(), ['dispatch', 'grn', 'invoice', 'stock']);
});

test('the four documents read their lines through readDocumentLines with their kind, and the renderer is asked to run a long one alone', () => {
  const source = readFileSync(new URL('../functions/_shared/document-pdf.ts', import.meta.url), 'utf8');
  assert.equal(source.match(/readDocumentLines\(reader,kind,'/g).length, 5); // the invoice is read twice: the GST layouts read their lines with the tax columns (WH-151)
  assert.doesNotMatch(source, /limit\(1001\)|starter limit/);
  assert.match(source, /renderDocumentPdf\(html,\{ solo: pages > SOLO_PDF_PAGES, requestId: requestId\(req\) \}\)/);
  assert.match(source, /if \(pages > MAX_PDF_PAGES\) throw \{ status: 400/);
});

test('the document table keeps a row on one page (the header repeats by the browser default, pinned by the invoice-long golden)', () => {
  const html = documentHtml('INVOICE', 'Co', {}, ['Item'], [['a']]);
  assert.match(html, /tr\{break-inside:avoid\}/);
  assert.doesNotMatch(html, /thead\{display:none/);
});

const invoiceRow = (name, i = 0) => [name, 1, '6 months', 30, '2.5', 100, 10 + i];
const rowsOf = (n, name) => Array.from({ length: n }, (_, i) => invoiceRow(name(i), i));

test('estimatePages matches what the real renderer printed: 3,055 short rows 99 pages, 3,500 113, 5,000 162, 3,055 rows of 80-character names 146', () => {
  const mixed = i => ['Potato', 'Mustard Seed', 'Garlic Large Grade A Export Quality - Lot', 'Wheat'][i % 4] + ' ' + (i + 1);
  assert.equal(estimatePages(rowsOf(3055, mixed)), 99);
  assert.equal(estimatePages(rowsOf(3500, mixed)), 113);
  assert.equal(estimatePages(rowsOf(5000, mixed)), 162);
  const long = i => `Dried Red Chilli Stalkless Premium Selected Bold Export Quality Grade A Lot ${i}`.padEnd(80, 'x').slice(0, 80);
  assert.ok(Math.abs(estimatePages(rowsOf(3055, long)) - 146) <= 2);
  assert.equal(estimatePages([]), 0);
});

test('estimatePages counts a wrapped cell in any column, and Gujarati rows a little taller', () => {
  const plain = estimatePages(rowsOf(310, () => 'Potato'));
  assert.equal(plain, 10);
  assert.ok(estimatePages(rowsOf(310, () => 'x'.repeat(56))) > plain, 'a name over one line');
  assert.ok(estimatePages(Array.from({ length: 310 }, () => ['Potato', 'm'.repeat(60)])) > plain, 'a long mark in a narrow column');
  assert.ok(estimatePages(rowsOf(310, () => 'બટાટા')) > plain, 'Gujarati');
  assert.ok(MAX_PDF_PAGES > estimatePages(rowsOf(MAX_PDF_ROWS, () => 'Potato')), 'a full document of short rows is within the page limit');
  assert.ok(SOLO_PDF_PAGES < MAX_PDF_PAGES);
});
