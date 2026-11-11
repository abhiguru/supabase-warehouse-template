import test from 'node:test';
import assert from 'node:assert/strict';
import { IGST_PLAIN_PAPER, PrintFitError, fitted, headerFit, keepEnd, preprintedRefusal, preprintedState, preprintedTaxFields } from '../functions/_shared/invoice-print-fit.ts';
import { printedMonths } from '../functions/_shared/invoice-print-amounts.ts';
import { register } from 'node:module';
import { createHash } from 'node:crypto';

// Where the print function is, and the SHA-256 of the bytes it prints for the fixture below. NOLABEL (no invoice_label) was checked byte for
// byte against the function as of 125bf5b^ (before WH-151); the other differs from it only by printing SRT/1 for 1 (WH-139).
const PRINT_FUNCTION = process.env.PP_TEST_FUNCTION || '../functions/print-invoice-preprinted/index.ts';
const PRE_WH151_SHA = '9456312d6e011ee8c8bc62c3bf21c28f03dbffd51b41b83ffa438b43f254a702';
const PRE_WH151_NOLABEL_SHA = 'f6bf28e7bf2dc160099d4a51c0446192db5e0a81af5e6eaf19d5e92541b04442';

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
  assert.throws(() => preprintedTaxFields({ doc_type: 'tax_invoice', tax_amount: 123456789.5, sgst_amount: 123456789.5 }, money, 10), error => error instanceof PrintFitError && error.field === 'SGST');
  // WH-172: an invoice made without GST details (document type 'invoice' or none) is cut to the field as before WH-151, never refused.
  for (const doc_type of ['invoice', undefined]) {
    assert.deepEqual(preprintedTaxFields({ doc_type, tax_amount: 123456789.5 }, money, 10), { sgst: '61728394.7', cgst: '61728394.7', taxTotal: '123456789.' }, String(doc_type));
  }
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

// ---- The whole print function, run in node (WH-172) --------------------------------------------------------------------------------
// index.ts is loaded with Deno.serve captured and the modules that reach the database, the printer and the network replaced by stubs
// (a module resolve hook); the rest (layout, fit, amounts, printer text) is the real code. The bytes the stub printer receives are what
// the function sent.
const stub = body => 'data:text/javascript,' + encodeURIComponent(body);
const STUBS = {
  '/supabase-rest.ts': stub('export const restClient = () => ({ rpc: async () => ({ data: globalThis.__pp.rpc, error: null }) });'),
  '/print-status-monitor.ts': stub('export const monitorPrintJobStatus = async () => {};'),
  '/print-request.ts': stub(`export const readRequestId = () => ({ ok: true, requestId: null });
    export const startPrintJob = async () => ({ kind: 'new' }); export const finishPrintJob = async () => 1;
    export const duplicateResponse = () => new Response('duplicate');`),
  '/print-transport.ts': stub(`export const submitRawJob = async ({ bytes }) => { globalThis.__pp.sent.push(Buffer.from(bytes)); return { transport: 'stub', jobId: 1 }; };
    export const jobOutcome = () => ({ kind: 'sent' }); export const printFailureBody = () => ({});
    export const configuredPrinterName = () => 'stub';`),
  '/auth-helpers.ts': stub(`export const validatePrintAccess = async () => ({ name: 'Test Admin', role: 'admin', auth_user_id: 'u1' });
    export const createAuthErrorResponse = () => new Response('auth', { status: 401 });`),
};
globalThis.__pp = { rpc: null, sent: [] };
let serveHandler;
globalThis.Deno = { serve: handler => { serveHandler = handler; }, env: { get: () => '' } };
register('data:text/javascript,' + encodeURIComponent(`export async function resolve(specifier, context, next) {
  const stubs = ${JSON.stringify(STUBS)};
  if (context.parentURL?.endsWith('/index.ts') && context.parentURL.includes('/print-invoice-preprinted')) {
    for (const [suffix, url] of Object.entries(stubs)) if (specifier.endsWith(suffix)) return { url, shortCircuit: true };
  }
  return next(specifier, context);
}`));
await import(PRINT_FUNCTION);

const LONG_WORDS = 'Rupees One Hundred Twenty Three Crore Forty Five Lakh Sixty Seven Thousand Eight Hundred Ninety and Fifty Paise Only Extra';
const invoiceFixture = (id, doc_type, extra = {}) => ({
  id: `00000000-0000-0000-0000-00000000000${id}`, inv_no: id, invoice_label: `SRT/${id}`, inv_fin_year: 2026, inv_date: '2026-11-01T00:00:00Z',
  customer_name: 'Test Customer', address: 'A'.repeat(120), city: 'Surat', mobile: '9000000001', gstin: '24ABCDE1234F1Z5',
  tax_amount: 123456789.5, cgst_amount: 61728394.75, sgst_amount: 61728394.75, total: 1234567890.5, labour: 10, inwords: LONG_WORDS,
  ...(doc_type ? { doc_type } : {}),
  trl: [{ id: `l${id}`, grn_items_id: 'g1', grn_items_item_name: 'Potato', grn_items_packaging: 'Bag', grn_items_quantity: 10, grns_date: '2026-10-01T00:00:00Z',
    grns_gr_no: 'AB12345678', dispatches_items_disp_qty: 10, dispatches_date: '2026-11-01T00:00:00Z', duration: '1', grn_items_weight: '50', charge: 5, storage_amount: 50 }],
  ...extra,
});
async function printRange(invoices) {
  globalThis.__pp.rpc = { data: invoices, success: true, message: null };
  globalThis.__pp.sent = [];
  const response = await serveHandler(new Request('http://x/print', { method: 'POST', body: JSON.stringify({ start_inv_no_str: '1', end_inv_no_str: '9' }) }));
  return { status: response.status, body: await response.json(), bytes: globalThis.__pp.sent[0]?.toString('latin1') };
}
const sha = text => createHash('sha256').update(text, 'latin1').digest('hex');

test('an invoice without GST details (document type invoice or none) is cut, never refused, and prints exactly as before WH-151', async () => {
  for (const doc_type of ['invoice', undefined]) {
    const { status, body, bytes } = await printRange([invoiceFixture(1, doc_type)]);
    assert.equal(status, 200, String(doc_type));
    assert.deepEqual(body.skipped, [], String(doc_type));
    assert.equal(body.range.count, 1);
    assert.equal(bytes.length, 851, `${doc_type}: the 851-byte rendering of before WH-151`);
    assert.ok(bytes.includes('AB12345678') && !bytes.includes('AB12345678/'), 'the GRN reference prints cut at the end, as AB12345678');
    assert.ok(!bytes.includes('...'), 'no "..." keeping the end');
    assert.equal(sha(bytes), PRE_WH151_SHA, `${doc_type}: bytes equal the pre-WH-151 rendering`);
  }
  // Without an invoice_label the plain number prints; cut or not, never refused.
  const noLabel = await printRange([invoiceFixture(1, 'invoice', { invoice_label: undefined })]);
  assert.equal(noLabel.status, 200);
  assert.deepEqual(noLabel.body.skipped, []);
  assert.equal(sha(noLabel.bytes), PRE_WH151_NOLABEL_SHA);
});

test('the same values as a tax invoice are refused as does_not_fit, and the GRN reference keeps its end behind "..."', async () => {
  const refused = await printRange([invoiceFixture(1, 'tax_invoice')]);
  assert.equal(refused.status, 422);
  assert.equal(refused.body.code, 'ALL_SKIPPED');
  assert.equal(refused.body.skipped[0].reason, 'does_not_fit');
  assert.equal(refused.body.skipped[0].invoice_label, 'SRT/1');
  // With the other values made to fit, the reference alone is cut at its front.
  const fits = invoiceFixture(1, 'tax_invoice', { address: 'Short', tax_amount: 11, cgst_amount: 5.5, sgst_amount: 5.5, total: 100, inwords: 'Rupees One Hundred Only' });
  fits.trl[0].grn_items_quantity = 100;
  const printed = await printRange([fits]);
  assert.equal(printed.status, 200);
  assert.deepEqual(printed.body.skipped, []);
  assert.ok(printed.bytes.includes('...678/100'), 'the end of AB12345678/100 is kept');
  assert.ok(!printed.bytes.includes('AB12345678'), 'the front is cut');
});

test('a range of invoices without GST details that are all too long still prints; only a range nothing of which can be printed answers ALL_SKIPPED', async () => {
  const noGst = await printRange([invoiceFixture(1, 'invoice'), invoiceFixture(2, undefined)]);
  assert.equal(noGst.status, 200);
  assert.equal(noGst.body.code, undefined);
  assert.equal(noGst.body.range.count, 2);
  assert.deepEqual(noGst.body.skipped, []);
  // A mixed range prints the cut invoice and skips the refused one.
  const mixed = await printRange([invoiceFixture(1, 'invoice'), invoiceFixture(2, 'tax_invoice')]);
  assert.equal(mixed.status, 200);
  assert.equal(mixed.body.range.count, 1);
  assert.deepEqual(mixed.body.skipped.map(item => [item.invoice_label, item.reason]), [['SRT/2', 'does_not_fit']]);
});
