import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { lineStorageAmount, cumulativeStorageAmount, indiaFinancialYear, resolveInvoiceFinYear } from '../functions/_shared/invoice-print-amounts.ts';

// PRINT2 and PRINT5 (review 2026-10-13). The invoice print computed every line's
// storage amount as duration * quantity * rate, a ONE_TIME receipt included, and
// took the current calendar year when no financial year was given. The line
// amounts now come from get_invoice_range_for_print (migration 72), and the
// default year is India's financial year (1 April to 31 March, Asia/Kolkata).
const source = readFileSync(new URL('../functions/print-invoice-preprinted/index.ts', import.meta.url), 'utf8');

test('a line prints the storage amount the database computed', () => {
  // The ONE_TIME line of tests/print_invoice_range.sql: 2 bags at 10 for 3 periods is 20, not 60.
  assert.equal(lineStorageAmount({ storage_amount: 20, duration: 3, dispatches_items_disp_qty: 2, charge: 10, pricing_mode: 'ONE_TIME' }), 20);
  assert.equal(lineStorageAmount({ storage_amount: 60, duration: 3, dispatches_items_disp_qty: 2, charge: 10, pricing_mode: 'MONTHLY' }), 60);
  assert.equal(lineStorageAmount({ storage_amount: '178.50' }), 178.5);
  assert.equal(lineStorageAmount({ storage_amount: 0 }), 0);
});

test('a line without a server amount stops the print instead of computing one', () => {
  for (const line of [{ duration: 3, dispatches_items_disp_qty: 2, charge: 10 }, { storage_amount: null }, { storage_amount: '' },
    { storage_amount: 'abc' }, { storage_amount: Number.NaN }, { storage_amount: Infinity }, { storage_amount: -1 }, null]) {
    assert.throws(() => lineStorageAmount(line), /storage amount/, JSON.stringify(line));
  }
});

test('the cumulative storage amount is summed in paise', () => {
  assert.equal(cumulativeStorageAmount([{ storage_amount: 20 }, { storage_amount: 60 }]), 80);
  assert.equal(cumulativeStorageAmount([{ storage_amount: 0.1 }, { storage_amount: 0.2 }]), 0.3);
  assert.equal(cumulativeStorageAmount(Array.from({ length: 10 }, () => ({ storage_amount: 0.1 }))), 1);
  assert.equal(cumulativeStorageAmount([]), 0);
  assert.throws(() => cumulativeStorageAmount([{ storage_amount: 20 }, {}]), /storage amount/);
});

test("the default financial year is India's", () => {
  assert.equal(indiaFinancialYear(new Date('2027-02-15T06:00:00Z')), 2026);
  assert.equal(indiaFinancialYear(new Date('2026-03-31T18:00:00Z')), 2025, '23:30 on 31 March in India');
  assert.equal(indiaFinancialYear(new Date('2026-03-31T19:00:00Z')), 2026, '00:30 on 1 April in India');
  assert.equal(indiaFinancialYear(new Date('2026-04-01T00:00:00Z')), 2026);
  assert.equal(indiaFinancialYear(new Date('2026-12-31T19:00:00Z')), 2026, '1 January in India is still the year that began in April');
});

test('a given financial year is an integer from 2000 to 9999, as generate-invoice-pdf takes it', () => {
  const now = new Date('2027-02-15T06:00:00Z');
  for (const missing of [undefined, null, '']) assert.equal(resolveInvoiceFinYear(missing, now), 2026, String(missing));
  assert.equal(resolveInvoiceFinYear(2025, now), 2025);
  assert.equal(resolveInvoiceFinYear('2024', now), 2024);
  for (const bad of [1999, 10000, 2026.5, 'abc', '20x6', true, {}, [2026], 0]) {
    assert.throws(() => resolveInvoiceFinYear(bad, now), error => error.status === 400 && error.message === 'Invalid financial year', JSON.stringify(bad));
  }
});

test('the invoice print uses the server amounts and resolves the year once', () => {
  assert.ok(!source.includes('duration * dispatchQty * rate'), 'no amount is computed from duration, quantity and rate');
  assert.equal(source.match(/lineStorageAmount\(/g)?.length, 1, 'the line amount');
  assert.equal(source.match(/cumulativeStorageAmount\(/g)?.length, 1, 'the cumulative amount');
  assert.match(source, /import \{[^}]*\bresolveInvoiceFinYear\b[^}]*\} from '\.\.\/_shared\/invoice-print-amounts\.ts'/);
  assert.equal(source.match(/resolveInvoiceFinYear\(/g)?.length, 1, 'resolved once');
  assert.match(source, /inv_fin_year: finYear,/, 'the RPC gets the resolved year');
  assert.equal(source.match(/fin_year: finYear,/g)?.length, 3, 'the RPC and both answers use the resolved year');
  for (const line of source.split('\n').filter(text => /fin_year/.test(text))) {
    assert.doesNotMatch(line, /getFullYear\(\)/, `calendar year near the financial year: ${line.trim()}`);
  }
  assert.doesNotMatch(source, /inv_fin_year \|\|/);
});
