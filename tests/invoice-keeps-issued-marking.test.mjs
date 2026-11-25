// WH-308: an issued invoice keeps the package marking and rack it was issued with (owner, 2026-11-25: "As issued, AB-12").
// The data side (invoice details, printable invoice data, preprinted slip, lot unchanged) is tests/invoice_keeps_issued_marking.sql.
// This file guards the PDF code, which needs no database: the invoice PDF and the preprinted invoice slip must never read a line's rack or
// marking from the live lot (goodsreceived_trl). Today the server's invoice PDF prints neither; the slip takes the marking from the RPC row.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { invoiceGstLineColumns, invoiceImportedLineColumns } from '../functions/_shared/document-columns.ts';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const pdfSource = read('functions/_shared/document-pdf.ts');
const slipSource = read('functions/print-invoice-preprinted/index.ts');

// agree with Development: the names of the invoice line's own copies once the fix lands (cancelled lines use kept_rack and kept_package_mark).
// A column of invoice_trl itself is never a live lookup, so any name is allowed there; only a join into the lot is refused.
const liveLotJoin = /goodsreceived_trl(?:!inner)?\(([^()]*(?:\([^()]*\))*[^()]*)\)/g;
const liveLotFields = select => [...select.matchAll(liveLotJoin)].map(m => m[1]).filter(inner => /\b(rack|package_mark)\b/.test(inner));

// The select lists the invoice PDF reads its lines with: the literals on the readDocumentLines calls for 'invoice_trl', and the shared lists.
const invoiceSelects = [
  ...[...pdfSource.matchAll(/readDocumentLines\(reader,kind,'invoice_trl',\s*(?:'([^']*)'|(\w+))/g)]
    .map(m => m[1] ?? ({ invoiceGstLineColumns, invoiceImportedLineColumns })[m[2]]),
];

test('the invoice PDF reads its lines from three places and every select list is found', () => {
  assert.equal(invoiceSelects.length, 3);
  for (const select of invoiceSelects) assert.equal(typeof select, 'string', 'a select list was not resolved');
  assert.match(invoiceSelects[0], /^duration,/);
});

test('the invoice PDF never reads a line rack or marking from the live lot', () => {
  for (const select of invoiceSelects) assert.deepEqual(liveLotFields(select), [], `invoice line select reads the live lot: ${select}`);
});

test('the live-lot check can fail: a join into the lot that names rack or package_mark is caught', () => {
  assert.deepEqual(liveLotFields('charge,dispatch_trl(disp_qty,goodsreceived_trl(item_name,package_mark))'), ['item_name,package_mark']);
  assert.deepEqual(liveLotFields('dispatch_trl(goodsreceived_trl!inner(rack))'), ['rack']);
  assert.deepEqual(liveLotFields('charge,kept_rack,kept_package_mark,dispatch_trl(disp_qty,goodsreceived_trl(item_name))'), []);
});

test('the preprinted invoice slip takes the marking only from the RPC row, never from a table read', () => {
  assert.match(slipSource, /\.rpc\('get_invoice_range_for_print'/);
  assert.match(slipSource, /item\.grn_items_package_mark/);
  assert.doesNotMatch(slipSource, /\.from\(\s*['"](?:goodsreceived_trl|goodsreceived|invoice_trl)['"]/);
  assert.doesNotMatch(slipSource, /\brack\b/i, 'the slip prints no rack; rack comes only through the RPC if it ever does');
});
