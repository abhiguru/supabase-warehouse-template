// WH-158: the readings Development chose where the contract is silent (card WH-158, "Readings chosen"); each is pinned as built.
// If Product changes a reading, the matching test here changes with it. The SQL halves (first and last issued numbers, the audit row of the
// first ledger save) are in tests/accountant_pack.sql. Fictional names and numbers only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { accountantPackFiles } from '../functions/_shared/accountant-pack-files.ts';

const C1 = '00000000-0000-4000-8000-0000000000c1';
const id = n => `10000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const LEDGERS = { storage_taxable: 'L Rent', storage_exempt: 'L Rent Exempt', labour: 'L Labour', cgst: 'L CGST', sgst: 'L SGST', igst: 'L IGST', discount: 'L Discount',
  round_off: 'L Round', receipt_cash: 'L Cash', receipt_upi: 'L UPI', receipt_bank_transfer: 'L Bank Transfer', receipt_cheque: 'L Cheque', receipt_other: 'L Other' };
const doc = (n, number, type, rows, extra = {}) => ({
  id: id(n), doc_type: type, number, date: '2026-10-15', customer_id: C1, customer_name: 'Demo Traders', customer_gstin: '24BBBBB1111B1Z3',
  customer_state: 'Gujarat (24)', place_of_supply: 'Gujarat (24)', sac_storage: '996721', sac_labour: '996719', tax_head: 'cgst_sgst', gr_no: 'G1',
  linked_number: null, status: 'live', cancelled_on: null, imported: false, before_gst: false, discount: 0, round_off: 0, total: 0, rows, ...extra });
const data = (documents, payments = [], customers = [{ id: C1, name: 'Demo Traders', gstin: '24BBBBB1111B1Z3', state_name: 'Gujarat (24)' }]) => ({
  made_at: '2026-11-01T05:30:00+00:00', made_by: 'Demo Administrator',
  facility: { name: 'Demo Cold Storage', legal_name: 'Demo Cold Storage', gstin: '24AAAAA0000A1Z5', state_code: '24', state_name: 'Gujarat', registered: true, gst_saved: true },
  period: { from_date: '2026-10-01', to_date: '2026-10-31', fin_year: 2026, whole_month: true }, record_payments: true, ledgers: LEDGERS,
  documents, cancellations: [], changed_earlier: [], payments, stock: [], issued: [], missing_numbers: [], customers, renamed_customers: [] });
const lines = (files, name) => files.find(f => f.name === name).text.split('\r\n');

test('[reading] a document with no rows still gets one register line, with its total, and is counted in the README', () => {
  const files = accountantPackFiles(data([doc(1, 'SRT/30', 'tax_invoice', [], { total: 118, discount: 2, round_off: 0.25 })]));
  const sales = lines(files, 'sales-register.csv').filter(l => l.includes('SRT/30'));
  assert.equal(sales.length, 1, 'one line');
  assert.equal(sales[0], 'Tax invoice,SRT/30,15/10/2026,Demo Traders,24BBBBB1111B1Z3,Gujarat (24),Gujarat (24),,,,,,,,,,2.00,0.25,118.00,Live,,,G1,');
  assert.ok(files.find(f => f.name === 'README.txt').text.includes('sales-register.csv: 1 documents, 0 cancelled'));
});

test('[reading] an exempt row goes to Nil-rated and exempt whatever its rate, and is in no B2B or B2C line', () => {
  const exempt = { kind: 'storage', exempt: true, rate: 5, taxable_value: 0, exempt_value: 200, cgst: 0, sgst: 0, igst: 0, tax: 0 };
  const files = accountantPackFiles(data([doc(1, 'SRT/31', 'bill_of_supply', [exempt], { total: 200, tax_head: null })]));
  const g = lines(files, 'gstr1-working.csv');
  assert.ok(g.includes('Within the state,Registered,200.00'), 'the exempt value is in the Nil-rated line within the state, registered');
  assert.ok(!g.some(l => l.startsWith('SRT/31,')), 'no B2B line for it');
  assert.ok(!g.some(l => /^Gujarat \(24\),5\.00,/.test(l)), 'no B2C line for it');
});

test('[reading] a receipt voucher carries VOUCHERNUMBER = the payment number', () => {
  const pay = { id: '20000000-0000-4000-8000-000000000001', payment_no: 'APP-77', paid_on: '2026-10-20', customer_id: C1, customer_name: 'Demo Traders',
    invoice_id: null, invoice_number: null, amount: 50, mode: 'cash', bank: null, reference: null, note: null, cash_large: false, imported: false };
  const files = accountantPackFiles(data([doc(1, 'SRT/32', 'tax_invoice', [{ kind: 'storage', exempt: false, rate: 5, taxable_value: 100, exempt_value: 0, cgst: 2.5, sgst: 2.5, igst: null, tax: 5 }], { total: 105 })], [pay]));
  const xml = files.find(f => f.name === 'tally-vouchers.xml').text;
  assert.match(xml, /<VOUCHERTYPENAME>Receipt<\/VOUCHERTYPENAME>\s*<VOUCHERNUMBER>APP-77<\/VOUCHERNUMBER>/);
});

test('[reading] "Gujarat (24)" is cut to "Gujarat" for the Tally ledger (state and place of supply); a plain name is kept', () => {
  const files = accountantPackFiles(data([], [], [{ id: C1, name: 'Demo Traders', gstin: '24BBBBB1111B1Z3', state_name: 'Gujarat (24)' },
    { id: '00000000-0000-4000-8000-0000000000c2', name: 'Plain Co', gstin: null, state_name: 'Kerala' }]));
  const xml = files.find(f => f.name === 'tally-masters.xml').text;
  assert.match(xml, /<PLACEOFSUPPLY>Gujarat<\/PLACEOFSUPPLY>/);
  assert.match(xml, /<STATE>Gujarat<\/STATE>/);
  assert.match(xml, /<STATE>Kerala<\/STATE>/);
  assert.ok(!xml.includes('(24)'));
});
