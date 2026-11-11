import test from 'node:test';
import assert from 'node:assert/strict';
import { IGST_PLAIN_PAPER, PrintFitError, fitted, headerFit, keepEnd, preprintedRefusal, preprintedState, preprintedTaxFields } from '../functions/_shared/invoice-print-fit.ts';
import { printedMonths } from '../functions/_shared/invoice-print-amounts.ts';

// The pre-printed invoice form (WH-151, WH-137, WH-139): what it prints with and without the facility's GST details, and what it refuses instead of cutting.
// An invoice saved before the GST details (document type 'invoice', no stored CGST or SGST) must print exactly as the form always did.
const money = n => n.toFixed(2);

test('an invoice without GST details prints SGST and CGST as half the tax each and the tax total, as the form always did', () => {
  assert.deepEqual(preprintedTaxFields({ tax_amount: 11 }, money, 10), { sgst: '5.50', cgst: '5.50', taxTotal: '11.00' });
  assert.deepEqual(preprintedTaxFields({ doc_type: 'invoice', tax_amount: 48 }, money, 10), { sgst: '24.00', cgst: '24.00', taxTotal: '48.00' });
  // No tax at all prints zeros, not blanks (an invoice).
  assert.deepEqual(preprintedTaxFields({ doc_type: 'invoice', tax_amount: 0 }, money, 10), { sgst: '0.00', cgst: '0.00', taxTotal: '0.00' });
  assert.deepEqual(preprintedTaxFields({}, money, 10), { sgst: '0.00', cgst: '0.00', taxTotal: '0.00' });
  // Stored CGST and SGST are ignored for this document type: the half is what the form printed before.
  assert.deepEqual(preprintedTaxFields({ doc_type: 'invoice', tax_amount: 10, cgst_amount: 1, sgst_amount: 9 }, money, 10), { sgst: '5.00', cgst: '5.00', taxTotal: '10.00' });
});

test('a tax invoice and an invoice-cum-bill of supply print the stored CGST and SGST; a bill and a bill of supply leave the tax fields blank', () => {
  for (const doc_type of ['tax_invoice', 'invoice_cum_bos']) {
    assert.deepEqual(preprintedTaxFields({ doc_type, tax_amount: 11, cgst_amount: '6.00', sgst_amount: 5 }, money, 10), { sgst: '5.00', cgst: '6.00', taxTotal: '11.00' }, doc_type);
    // A missing or non-numeric stored amount prints 0.00, never NaN.
    assert.deepEqual(preprintedTaxFields({ doc_type, tax_amount: 0, cgst_amount: null, sgst_amount: 'x' }, money, 10), { sgst: '0.00', cgst: '0.00', taxTotal: '0.00' }, doc_type);
  }
  for (const doc_type of ['bill', 'bill_of_supply']) {
    assert.deepEqual(preprintedTaxFields({ doc_type, tax_amount: 11, cgst_amount: 6, sgst_amount: 5 }, money, 10), { sgst: '', cgst: '', taxTotal: '' }, doc_type);
  }
});

test('a tax figure that does not fit its field refuses the invoice and names the field; nothing is cut', () => {
  assert.throws(() => preprintedTaxFields({ doc_type: 'tax_invoice', tax_amount: 5, cgst_amount: 123456789.5, sgst_amount: 1 }, money, 10), error => error instanceof PrintFitError && error.field === 'CGST' && error.width === 10);
  assert.throws(() => preprintedTaxFields({ tax_amount: 123456789.5 }, money, 10), error => error instanceof PrintFitError && error.field === 'SGST');
  assert.equal(fitted('1234567890', 10, 'x'), '1234567890');
  assert.throws(() => fitted('12345678901', 10, 'Amount'), /The Amount \(12345678901\) does not fit its 10-character field on the form/);
});

test('only an IGST invoice is not printed on the form', () => {
  assert.equal(preprintedRefusal({ gst_tax_head: 'igst' }), 'igst');
  for (const gst_tax_head of [undefined, null, '', 'cgst_sgst', 'none']) assert.equal(preprintedRefusal({ gst_tax_head }), null, String(gst_tax_head));
  assert.equal(IGST_PLAIN_PAPER, 'IGST invoices print on plain paper.');
});

test('the state on the first line is GUJARAT unless a GST document names the facility\'s state', () => {
  assert.equal(preprintedState({}), 'GUJARAT');
  assert.equal(preprintedState({ doc_type: 'invoice', supplier_state_name: 'Maharashtra' }), 'GUJARAT', 'an invoice made without GST details prints as before');
  assert.equal(preprintedState({ doc_type: 'tax_invoice', supplier_state_name: ' Maharashtra ' }), 'MAHARASHTRA');
  assert.equal(preprintedState({ doc_type: 'tax_invoice', supplier_state_name: '' }), 'GUJARAT');
  assert.equal(preprintedState({ doc_type: 'bill_of_supply' }), 'GUJARAT');
});

test('the first line: the full number is never cut, the GSTIN moves right after a long one and is refused when it would run into the state', () => {
  const layout = { INVOICE_NO_OFFSET: 10, GSTIN_OFFSET: 30, STATE_OFFSET: 60 };
  assert.doesNotThrow(() => headerFit({ inv_no: 12 }, layout, 15));
  assert.doesNotThrow(() => headerFit({ invoice_label: 'SRT/12', gstin: '24ABCDE1234F1Z5' }, layout, 15));
  // A number that reaches the GSTIN's place moves the GSTIN right by the extra, after one space: 10 + 25 = 35, the GSTIN starts at 36 and ends at 51.
  assert.doesNotThrow(() => headerFit({ invoice_label: 'A'.repeat(25), gstin: '24ABCDE1234F1Z5' }, layout, 15));
  assert.throws(() => headerFit({ invoice_label: 'A'.repeat(40), gstin: '24ABCDE1234F1Z5' }, layout, 15), error => error instanceof PrintFitError && error.field === 'GSTIN');
  assert.throws(() => headerFit({ inv_no: 1, gstin: '24ABCDE1234F1Z5X' }, layout, 15), error => error instanceof PrintFitError && error.field === 'GSTIN' && error.width === 15);
});

test('a long reference keeps its end behind "..."', () => {
  assert.equal(keepEnd('GRN-2026-0001', 20), 'GRN-2026-0001');
  assert.equal(keepEnd('ABCDEFGHIJKLMNOP', 10), '...JKLMNOP');
  assert.equal(keepEnd('ABCDEFGHIJ', 10), 'ABCDEFGHIJ');
});

test('the months column prints whole and half months with one decimal as before, and two decimals when they fit', () => {
  for (const [months, width, printed] of [[1, 4, '1.0'], [1.5, 4, '1.5'], [2, 4, '2.0'], [12, 4, '12.0'], [0.5, 4, '0.5'], [1.33, 4, '1.33'], [0.67, 4, '0.67'], [10.33, 4, '10.3'], [10.33, 5, '10.33']]) {
    assert.equal(printedMonths(months, width), printed, `${months} in ${width}`);
  }
  assert.equal(printedMonths(Number.NaN, 4), '');
});
