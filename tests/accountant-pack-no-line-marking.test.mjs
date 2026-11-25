// WH-338 (Product, option b): the accountant pack carries no invoice-line marking or rack. Its document rows are grouped by tax rate and kind,
// so the pack files print none; the only Mark in the pack is stock-statement.csv's, which is the lot's present value (the stock rows' `mark`).
// Guard: even if a document row came with marking fields, no file built from documents (or the Tally file) prints them; and the stock Mark
// column is the stock row's own mark. Pure builds, no database. Fictional names only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { accountantPackFiles } from '../functions/_shared/accountant-pack-files.ts';

const C1 = '00000000-0000-4000-8000-0000000000c1';
const LEDGERS = { storage_taxable: 'L Rent', storage_exempt: 'L Rent Exempt', labour: 'L Labour', cgst: 'L CGST', sgst: 'L SGST', igst: 'L IGST', discount: 'L Discount',
  round_off: 'L Round', receipt_cash: 'L Cash', receipt_upi: 'L UPI', receipt_bank_transfer: 'L Bank Transfer', receipt_cheque: 'L Cheque', receipt_other: 'L Other' };
// A row as the RPC gives it, plus marking fields it does not give today: the pack must not print them.
const row = { kind: 'storage', exempt: false, rate: 5, taxable_value: 100, exempt_value: 0, cgst: 2.5, sgst: 2.5, igst: null, tax: 5,
  mark: 'AB-12', package_mark: 'AB-12', rack: 'R1', issued_package_mark: 'AB-12', issued_rack: 'R1' };
const document = { id: '10000000-0000-4000-8000-000000000001', doc_type: 'tax_invoice', number: 'SRT/40', date: '2026-10-15', customer_id: C1,
  customer_name: 'Demo Traders', customer_gstin: '24BBBBB1111B1Z3', customer_state: 'Gujarat (24)', place_of_supply: 'Gujarat (24)',
  sac_storage: '996721', sac_labour: '996719', tax_head: 'cgst_sgst', gr_no: 'G1', linked_number: null, status: 'live', cancelled_on: null,
  imported: false, before_gst: false, discount: 0, round_off: 0, total: 105, rows: [row], mark: 'AB-12', rack: 'R1' };
// The lot was marked AB-12 when billed and is AB-15 now; the stock statement shows the lot as it is now.
const stock = [{ customer_name: 'Demo Traders', gr_no: 'G1', grn_date: '2026-10-01', item_name: 'Potato', packaging: 'Bag', mark: 'AB-15',
  kg_per_bag: 50, start_bags: 0, received_bags: 20, sent_bags: 20, end_bags: 0, imported: false }];
const data = {
  made_at: '2026-11-01T05:30:00+00:00', made_by: 'Demo Administrator',
  facility: { name: 'Demo Cold Storage', legal_name: 'Demo Cold Storage', gstin: '24AAAAA0000A1Z5', state_code: '24', state_name: 'Gujarat', registered: true, gst_saved: true },
  period: { from_date: '2026-10-01', to_date: '2026-10-31', fin_year: 2026, whole_month: true }, record_payments: true, ledgers: LEDGERS,
  documents: [document], cancellations: [], changed_earlier: [], payments: [], stock, issued: [], missing_numbers: [],
  customers: [{ id: C1, name: 'Demo Traders', gstin: '24BBBBB1111B1Z3', state_name: 'Gujarat (24)' }], renamed_customers: [] };
const files = accountantPackFiles(data);

test('[WH-338] no file built from the documents, and not the Tally file, prints a line marking or rack', () => {
  const others = files.filter(f => f.name !== 'stock-statement.csv');
  assert.ok(others.length >= 4, 'the document files are there');
  assert.ok(others.some(f => f.name === 'sales-register.csv') && others.some(f => f.name === 'tally-vouchers.xml'), 'sales register and Tally vouchers are checked');
  for (const f of others) {
    assert.ok(!f.text.includes('AB-12'), `${f.name} prints no marking`);
    assert.ok(!f.text.includes('AB-15'), `${f.name} prints no lot marking`);
    assert.ok(!/\bR1\b/.test(f.text), `${f.name} prints no rack`);
  }
});

test('[WH-338] stock-statement.csv Mark is the stock row\'s own mark (the lot\'s present value), not a document row\'s', () => {
  const csv = files.find(f => f.name === 'stock-statement.csv').text.split('\r\n');
  const head = csv[0].replace('﻿', '').split(',');
  const line = csv[1].split(',');
  assert.equal(line[head.indexOf('Mark')], 'AB-15');
  assert.ok(!csv.join('\n').includes('AB-12'), 'the issued marking AB-12 is not in the stock statement');
  assert.ok(!/\bR1\b/.test(csv.join('\n')), 'no rack in the stock statement');
});
