import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { headerColumns, invoiceHeaderColumns } from '../functions/_shared/document-columns.ts';

// Migration 48 grants `invoice` to the app role column by column and leaves these six out.
// tests/invoice_column_grants.sql runs the same header query as a customer session.
const internal = ['discount_reason', 'discount_set_by', 'discount_set_at', 'zero_charge_reason', 'zero_charge_set_by', 'zero_charge_set_at'];
const source = readFileSync(new URL('../functions/_shared/document-pdf.ts', import.meta.url), 'utf8');

test('the invoice document reads its header by column, without the internal ones', () => {
  const columns = headerColumns('invoice').split(',');
  assert.equal(headerColumns('invoice'), invoiceHeaderColumns);
  assert.equal(invoiceHeaderColumns, 'id,customer_name,inv_date,inv_fin_year,labour,tax_amount,discount,total');
  assert.ok(!columns.includes('*'), 'select(*) on invoice is refused for the app role');
  for (const column of internal) assert.ok(!columns.includes(column), `${column} is internal`);
  assert.equal(new Set(columns).size, columns.length);
  for (const column of columns) assert.match(column, /^[a-z_]+$/);
});

test('every header field the PDF function uses for an invoice is in that list', () => {
  // header.date and header.disp_date belong to the receipt and the dispatch.
  const used = new Set([...source.matchAll(/\bheader\.([a-z_]+)/g)].map(match => match[1]));
  for (const other of ['date', 'disp_date']) assert.ok(used.delete(other), `document-pdf.ts no longer reads header.${other}`);
  assert.deepEqual([...used].sort(), headerColumns('invoice').split(',').sort());
});

test('the PDF function takes its header columns from the list and never selects * itself', () => {
  assert.match(source, /reader\.from\(table\)\.select\(headerColumns\(kind\)\)/);
  assert.doesNotMatch(source, /\.select\(\s*['"`]\*['"`]/);
  assert.equal(headerColumns('grn'), '*');
  assert.equal(headerColumns('dispatch'), '*');
});
