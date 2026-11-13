// WH-158: the accountant pack's files (contract product/tech/accountant-pack.md, sections 5 and 6, criteria 1-9 and 14).
// Written BEFORE the build: it fails today because functions/_shared/accountant-pack-files.ts and functions/_shared/tally-xml.ts do not exist.
// `data` is the `data` object get_accountant_pack answers (section 3); accountantPackFiles(data) answers [{ name, text }] in the order of section 5.
// Fictional names and numbers only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { accountantPackFiles, packFileName } from '../functions/_shared/accountant-pack-files.ts';
import { TALLY } from '../functions/_shared/tally-xml.ts';

// ---------- the fixture ----------
const C1 = '00000000-0000-4000-8000-0000000000c1';
const C2 = '00000000-0000-4000-8000-0000000000c2';
const C3 = '00000000-0000-4000-8000-0000000000c3';
const GSTIN1 = '24BBBBB1111B1Z3';
const GSTIN2 = '27CCCCC2222C1Z1';
const NAME1 = 'Demo Traders';
const NAME2 = 'ગુરુ ટ્રેડર્સ';
const NAME3 = 'Ram & Sons <Traders> "Q"';
const id = n => `10000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const row = (kind, rate, taxable, cgst, sgst, igst, tax, extra = {}) =>
  ({ kind, exempt: false, rate, taxable_value: taxable, exempt_value: 0, cgst, sgst, igst, tax, ...extra });
const doc = (n, number, date, type, customer, rows, extra = {}) => ({
  id: id(n), doc_type: type, number, date, customer_id: customer.id, customer_name: customer.name,
  customer_gstin: customer.gstin ?? null, customer_state: customer.state ?? null, place_of_supply: customer.state ?? null,
  sac_storage: '996721', sac_labour: '996719', tax_head: 'cgst_sgst', gr_no: 'G100' + n, linked_number: null,
  status: 'live', cancelled_on: null, imported: false, before_gst: false, discount: 0, round_off: 0, total: 0, rows, ...extra });
const cust1 = { id: C1, name: NAME1, gstin: GSTIN1, state: 'Gujarat (24)' };
const cust2 = { id: C2, name: NAME2, gstin: GSTIN2, state: 'Maharashtra (27)' };
const cust3 = { id: C3, name: NAME3, gstin: null, state: null };

function makeData() {
  const d1 = doc(1, 'SRT/12', '2026-10-15', 'tax_invoice', cust1,
    [row('storage', 5, 187.5, 4.74, 4.74, null, 9.48), row('labour', 5, 30, 0.76, 0.76, null, 1.52)], { total: 229, round_off: 0.5, gr_no: 'G1001' });
  const d2 = doc(2, 'SRT/13', '2026-10-20', 'tax_invoice', cust2,
    [row('storage', 18, 460, null, null, 82.8, 82.8), row('labour', 18, 40, null, null, 7.2, 7.2)], { total: 590, tax_head: 'igst', gr_no: 'G1002' });
  const d3 = doc(3, 'SRT/14', '2026-10-22', 'tax_invoice', cust1,
    [row('storage', 5, 290, 7.25, 7.25, null, 14.5), row('labour', 5, 10, 0.25, 0.25, null, 0.5)], { total: 310, discount: 5, linked_number: 'SRT/15', gr_no: 'G1003' });
  const d3b = doc(4, 'SRT/15', '2026-10-22', 'bill_of_supply', cust1,
    [{ kind: 'storage', exempt: true, rate: 0, taxable_value: 0, exempt_value: 200, cgst: 0, sgst: 0, igst: 0, tax: 0 }],
    { total: 200, tax_head: null, linked_number: 'SRT/14', gr_no: 'G1003' });
  const d4 = doc(5, 'SRT/18', '2026-10-25', 'invoice', cust3, [row('storage', 5, 100, null, null, null, 5)],
    { total: 104.6, round_off: -0.4, before_gst: true, tax_head: null, sac_storage: null, sac_labour: null, place_of_supply: null, gr_no: 'G1004' });
  const d6 = doc(6, 'GC/125', '2026-10-12', 'tax_invoice', cust1,
    [row('storage', 5, 400, 10, 10, null, 20), row('labour', 5, 50, 1.25, 1.25, null, 2.5)], { total: 472.5, imported: true, gr_no: 'G1001' });
  const d7 = doc(7, 'SRT/16', '2026-10-12', 'tax_invoice', cust1, [row('storage', 5, 100, 2.5, 2.5, null, 5)],
    { total: 105, status: 'cancelled', cancelled_on: '2026-10-14', gr_no: 'G1005' });
  const pay = (n, no, paid_on, mode, amount, extra = {}) => ({
    id: `20000000-0000-4000-8000-${String(n).padStart(12, '0')}`, payment_no: no, paid_on, customer_id: C1, customer_name: NAME1,
    invoice_id: id(1), invoice_number: 'SRT/12', amount, mode, bank: null, reference: null, note: null, cash_large: false, imported: false, ...extra });
  return {
    made_at: '2026-11-01T05:30:00+00:00', made_by: 'Demo Administrator',
    facility: { name: 'Demo Cold Storage', legal_name: 'Demo Cold Storage', gstin: '24AAAAA0000A1Z5', state_code: '24', state_name: 'Gujarat', registered: true, gst_saved: true },
    period: { from_date: '2026-10-01', to_date: '2026-10-31', fin_year: 2026, whole_month: true },
    record_payments: true,
    ledgers: { storage_taxable: 'L Rent', storage_exempt: 'L Rent Exempt', labour: 'L Labour', cgst: 'L CGST', sgst: 'L SGST', igst: 'L IGST', discount: 'L Discount',
      round_off: 'L Round', receipt_cash: 'L Cash', receipt_upi: 'L UPI', receipt_bank_transfer: 'L Bank Transfer', receipt_cheque: 'L Cheque', receipt_other: 'L Other' },
    documents: [d6, d7, d1, d2, d3, d3b, d4],
    cancellations: [
      { id: d7.id, doc_type: 'tax_invoice', number: 'SRT/16', date: '2026-10-12', cancelled_on: '2026-10-14', customer_id: C1, customer_name: NAME1, reason: 'in_period' },
      { id: id(9), doc_type: 'tax_invoice', number: 'SRT/9', date: '2026-09-20', cancelled_on: '2026-10-18', customer_id: C1, customer_name: NAME1, reason: 'exported' },
    ],
    changed_earlier: [{ number: 'SRT/5', date: '2026-09-30', changed_on: '2026-10-03' }],
    payments: [
      pay(1, 'APP-41', '2026-10-20', 'upi', 229),
      pay(2, 'APP-42', '2026-10-21', 'cash', 200000, { cash_large: true }),
      pay(3, 'APP-43', '2026-10-21', 'cash', 199999),
      pay(4, 'OLD-7', '2026-10-22', 'cheque', 500, { bank: 'Demo Bank', reference: 'CHQ123', note: 'Cheque, part' }),
      pay(5, 'APP-44', '2026-10-24', 'bank_transfer', 40, { invoice_id: null, invoice_number: null }),
      pay(6, 'APP-45', '2026-10-24', 'wallet', 60),
      pay(7, 'IMP-R1', '2026-10-26', 'cash', 100, { imported: true }),
      pay(8, 'APP-46', '2026-10-25', 'cash', 15, { customer_id: null, customer_name: 'Walk-in Payer', invoice_id: null, invoice_number: null }),
    ],
    stock: [
      { customer_name: NAME1, gr_no: 'G1001', grn_date: '2026-09-02', item_name: 'Jeera', packaging: '50 kg bag', mark: 'DT-7', kg_per_bag: 50,
        start_bags: 120, received_bags: 0, sent_bags: 20, end_bags: 100, imported: false },
      { customer_name: NAME2, gr_no: 'G1002', grn_date: '2026-10-05', item_name: 'Garlic', packaging: 'Bag', mark: null, kg_per_bag: 25,
        start_bags: 0, received_bags: 40, sent_bags: 10, end_bags: 30, imported: true },
    ],
    issued: [
      { doc_type: 'tax_invoice', first_number: 'SRT/12', last_number: 'SRT/16', count: 5, cancelled: 1 },
      { doc_type: 'bill_of_supply', first_number: 'SRT/15', last_number: 'SRT/15', count: 1, cancelled: 0 },
      { doc_type: 'invoice', first_number: 'SRT/18', last_number: 'SRT/18', count: 1, cancelled: 0 },
    ],
    missing_numbers: ['SRT/17'],
    customers: [{ id: C1, name: NAME1, gstin: GSTIN1, state_name: 'Gujarat' }, { id: C2, name: NAME2, gstin: GSTIN2, state_name: 'Maharashtra' },
      { id: C3, name: NAME3, gstin: null, state_name: null }],
    renamed_customers: [{ old_name: 'Old Traders', new_name: NAME1, changed_on: '2026-10-10' }],
  };
}

// ---------- readers ----------
const crlf = text => text.split('\r\n');
function parseCsv(text) {
  assert.ok(text.startsWith('﻿'), 'a CSV file starts with a byte-order mark');
  const src = text.slice(1);
  const rows = []; let cell = ''; let fields = []; let quoted = false; let i = 0;
  while (i < src.length) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"') { if (src[i + 1] === '"') { cell += '"'; i += 2; continue; } quoted = false; i++; continue; }
      cell += ch; i++; continue;
    }
    if (ch === '"') { quoted = true; i++; continue; }
    if (ch === ',') { fields.push(cell); cell = ''; i++; continue; }
    if (ch === '\r' && src[i + 1] === '\n') { fields.push(cell); rows.push(fields); fields = []; cell = ''; i += 2; continue; }
    assert.notEqual(ch, '\n', 'a bare LF outside quotes: every line ends CRLF');
    cell += ch; i++;
  }
  if (cell !== '' || fields.length) { fields.push(cell); rows.push(fields); }
  return rows;
}
function parseXml(text) {
  const src = text.replace(/^<\?xml[^>]*\?>/, '');
  const decode = s => s.replace(/&(#x?[0-9a-fA-F]+|amp|lt|gt|quot|apos);/g, (m, e) => {
    if (e === 'amp') return '&'; if (e === 'lt') return '<'; if (e === 'gt') return '>'; if (e === 'quot') return '"'; if (e === 'apos') return "'";
    return String.fromCodePoint(e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
  });
  const root = { name: '#root', attrs: {}, children: [], text: '' };
  const stack = [root]; let i = 0;
  while (i < src.length) {
    if (src[i] === '<') {
      if (src.startsWith('<!--', i)) { i = src.indexOf('-->', i) + 3; continue; }
      const end = src.indexOf('>', i);
      let tag = src.slice(i + 1, end);
      if (tag[0] === '/') { assert.equal(stack.pop().name, tag.slice(1).trim(), 'XML is well formed'); i = end + 1; continue; }
      const selfClose = tag.endsWith('/'); if (selfClose) tag = tag.slice(0, -1);
      const m = /^([^\s]+)((?:\s+[^\s=]+="[^"]*")*)\s*$/.exec(tag);
      assert.ok(m, `well-formed tag: <${tag}>`);
      const attrs = {};
      for (const a of m[2].matchAll(/([^\s=]+)="([^"]*)"/g)) attrs[a[1]] = decode(a[2]);
      const node = { name: m[1], attrs, children: [], text: '' };
      stack[stack.length - 1].children.push(node);
      if (!selfClose) stack.push(node);
      i = end + 1;
    } else {
      const next = src.indexOf('<', i);
      stack[stack.length - 1].text += decode(src.slice(i, next === -1 ? src.length : next));
      i = next === -1 ? src.length : next;
    }
  }
  assert.equal(stack.length, 1, 'XML is well formed: every element is closed');
  return root.children[0];
}
const all = (node, name, out = []) => { for (const c of node.children) { if (c.name === name) out.push(c); all(c, name, out); } return out; };
const kid = (node, name) => node.children.find(c => c.name === name);
const kidText = (node, name) => kid(node, name)?.text.trim();
const file = (files, name) => files.find(f => f.name === name);

const files = accountantPackFiles(makeData());
const sales = parseCsv(file(files, 'sales-register.csv').text);
const receipts = parseCsv(file(files, 'receipts-register.csv').text);

// ---------- the file set (section 5) ----------
test('the pack holds README, four CSV files and two Tally files, in this order; the receipts register only when Record payments is on', () => {
  assert.deepEqual(files.map(f => f.name), ['README.txt', 'sales-register.csv', 'receipts-register.csv', 'gstr1-working.csv', 'stock-statement.csv', 'tally-masters.xml', 'tally-vouchers.xml']);
  for (const f of files) assert.equal(typeof f.text, 'string');
  const off = makeData(); off.record_payments = false; off.payments = null;
  assert.deepEqual(accountantPackFiles(off).map(f => f.name), ['README.txt', 'sales-register.csv', 'gstr1-working.csv', 'stock-statement.csv', 'tally-masters.xml', 'tally-vouchers.xml']);
});

test('CSV files start with a byte-order mark, end every line with CRLF, README and XML have no byte-order mark', () => {
  for (const f of files.filter(x => x.name.endsWith('.csv'))) {
    assert.ok(f.text.startsWith('﻿'), f.name);
    assert.ok(f.text.endsWith('\r\n'), `${f.name} ends with CRLF`);
    assert.ok(!/(?<!\r)\n/.test(f.text), `${f.name}: no bare LF`);
  }
  assert.ok(!file(files, 'README.txt').text.startsWith('﻿'));
  assert.ok(file(files, 'tally-masters.xml').text.startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
  assert.ok(file(files, 'tally-vouchers.xml').text.startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
});

// ---------- [crit 1] the sales register ----------
test('[crit 1] sales-register.csv: the header, exactly', () => {
  assert.equal(file(files, 'sales-register.csv').text.slice(1).split('\r\n')[0],
    'Document type,Number,Date,Customer,Customer GSTIN,Customer state,Place of supply,SAC,Storage or labour,Taxable value,Exempt value,Tax rate,CGST,SGST,IGST,Tax,Discount,Round-off,Document total,Status,Cancelled on,Linked document,GRN,Imported');
});

test('[crit 1] sales-register.csv: the contract example line, a labour row, the pair, the exempt row, an imported row', () => {
  const lines = file(files, 'sales-register.csv').text.slice(1).split('\r\n');
  assert.ok(lines.includes('Tax invoice,SRT/12,15/10/2026,Demo Traders,24BBBBB1111B1Z3,Gujarat (24),Gujarat (24),996721,Storage,187.50,0.00,5.00,4.74,4.74,,9.48,0.00,0.50,229.00,Live,,,G1001,'));
  assert.ok(lines.includes('Tax invoice,SRT/12,15/10/2026,Demo Traders,24BBBBB1111B1Z3,Gujarat (24),Gujarat (24),996719,Labour,30.00,0.00,5.00,0.76,0.76,,1.52,,,,Live,,,G1001,'),
    'discount, round-off and document total on a document\'s first row only');
  const byNumber = n => sales.filter(r => r[1] === n);
  assert.equal(byNumber('SRT/14').length, 2);
  assert.equal(byNumber('SRT/14')[0][21], 'SRT/15');
  assert.equal(byNumber('SRT/15')[0][21], 'SRT/14');
  assert.equal(byNumber('SRT/14')[0][0], 'Tax invoice');
  assert.equal(byNumber('SRT/15')[0][0], 'Bill of supply');
  assert.equal(byNumber('SRT/15')[0][9], '0.00');
  assert.equal(byNumber('SRT/15')[0][10], '200.00');
  assert.equal(byNumber('SRT/14')[0][16], '5.00');
  assert.equal(byNumber('GC/125')[0][23], 'Yes');
  assert.equal(byNumber('SRT/12')[0][23], '');
  assert.equal(byNumber('SRT/18')[0][0], 'Invoice (before GST details)');
});

test('[crit 1] the document types read Tax invoice, Bill of supply, Invoice-cum-bill of supply, Bill, Invoice (before GST details)', () => {
  const data = makeData();
  data.documents[0].doc_type = 'invoice_cum_bos'; // GC/125
  data.documents[2].doc_type = 'bill';            // SRT/12
  const rows = parseCsv(file(accountantPackFiles(data), 'sales-register.csv').text);
  assert.equal(rows.find(r => r[1] === 'GC/125')[0], 'Invoice-cum-bill of supply');
  assert.equal(rows.find(r => r[1] === 'SRT/12')[0], 'Bill');
});

test('[crit 1] documents are listed in the order given, one line per row; the last line is the total of live documents', () => {
  assert.deepEqual(sales.slice(1, -1).map(r => `${r[1]}|${r[8]}`),
    ['GC/125|Storage', 'GC/125|Labour', 'SRT/16|Storage', 'SRT/12|Storage', 'SRT/12|Labour', 'SRT/13|Storage', 'SRT/13|Labour', 'SRT/14|Storage', 'SRT/14|Labour', 'SRT/15|Storage', 'SRT/18|Storage']);
  const total = sales.at(-1);
  assert.equal(total[0], 'Total (live documents)');
  assert.equal(total[9], '1567.50');   // taxable
  assert.equal(total[10], '200.00');   // exempt
  assert.equal(total[12], '24.25');    // CGST
  assert.equal(total[13], '24.25');    // SGST
  assert.equal(total[14], '90.00');    // IGST
  assert.equal(total[15], '143.50');   // tax (the before-GST document's 5.00 included)
  assert.equal(total[16], '5.00');     // discount
  assert.equal(total[17], '0.10');     // round-off 0.50 - 0.40
  assert.equal(total[18], '1906.10');  // document total of the six live documents
});

// ---------- [crit 2] a cancelled document ----------
test('[crit 2] a cancelled document is listed with its figures, status Cancelled and its date, and is in no total', () => {
  const r = sales.find(x => x[1] === 'SRT/16');
  assert.equal(r.join(','), 'Tax invoice,SRT/16,12/10/2026,Demo Traders,24BBBBB1111B1Z3,Gujarat (24),Gujarat (24),996721,Storage,100.00,0.00,5.00,2.50,2.50,,5.00,0.00,0.00,105.00,Cancelled,14/10/2026,,G1005,');
  const live = sales.slice(1, -1).filter(x => x[19] === 'Live');
  const sum = i => live.reduce((s, x) => s + Math.round(Number(x[i] || 0) * 100), 0);
  assert.equal(sum(9), 156750);
  assert.equal(sum(18), 190610);
});

test('[crit 2] a cancelled document has no Sales voucher; its cancellation voucher has its identity and ISCANCELLED Yes', () => {
  const root = parseXml(file(files, 'tally-vouchers.xml').text);
  const vouchers = all(root, 'VOUCHER');
  const d7 = makeData().documents.find(d => d.number === 'SRT/16');
  const mine = vouchers.filter(v => v.attrs.REMOTEID === `wh-inv-${d7.id}`);
  assert.equal(mine.length, 1, 'exactly one voucher carries the cancelled document\'s identity');
  const v = mine[0];
  assert.equal(kidText(v, 'ISCANCELLED'), 'Yes');
  assert.equal(kidText(v, 'GUID'), `wh-inv-${d7.id}`);
  assert.equal(kidText(v, 'VOUCHERNUMBER'), 'SRT/16');
  assert.equal(kidText(v, 'DATE'), '20261012');
  assert.equal(kidText(v, 'NARRATION'), 'Cancelled on 14/10/2026');
  assert.equal(all(v, 'ALLLEDGERENTRIES.LIST').length, 0, 'a cancellation has no entries');
  assert.equal(vouchers.filter(x => kidText(x, 'ISCANCELLED') === 'Yes').length, 2, 'one cancellation voucher per cancellations[] entry');
  const e1 = vouchers.find(x => x.attrs.REMOTEID === `wh-inv-${id(9)}`);
  assert.equal(kidText(e1, 'VOUCHERNUMBER'), 'SRT/9');
  assert.equal(kidText(e1, 'DATE'), '20260920');
  assert.equal(kidText(e1, 'NARRATION'), 'Cancelled on 18/10/2026');
});

// ---------- [crit 3] the GSTR-1 working ----------
const gst = parseCsv(file(files, 'gstr1-working.csv').text);
function block(title) {
  const start = gst.findIndex(r => r.length === 1 && r[0] === title);
  assert.ok(start >= 0, `block "${title}" exists`);
  const out = []; let i = start + 2;
  while (i < gst.length && !(gst[i].length === 1 && gst[i][0] === '')) { out.push(gst[i]); i++; }
  return { header: gst[start + 1], rows: out };
}
const cents = v => Math.round(Number(v || 0) * 100);

test('[crit 3] gstr1-working.csv: line 1 exactly, then the five blocks with their titles and headers', () => {
  const lines = file(files, 'gstr1-working.csv').text.slice(1).split('\r\n');
  assert.equal(lines[0], 'A working for your accountant to check. It is not a return.');
  assert.equal(lines[1], 'B2B: registered customers');
  assert.equal(lines[2], 'Number,Date,Customer,Customer GSTIN,Place of supply,Document type,Tax rate,Taxable value,CGST,SGST,IGST,Tax');
  assert.deepEqual(block('B2C: unregistered customers').header, ['Place of supply', 'Tax rate', 'Taxable value', 'CGST', 'SGST', 'IGST', 'Tax']);
  assert.deepEqual(block('Nil-rated and exempt').header, ['Supply', 'Customer', 'Value']);
  assert.deepEqual(block('SAC summary').header, ['SAC', 'Storage or labour', 'Tax rate', 'Taxable value', 'Exempt value', 'CGST', 'SGST', 'IGST', 'Tax']);
  assert.deepEqual(block('Documents issued').header, ['Document type', 'First number', 'Last number', 'How many', 'Cancelled']);
  assert.ok(lines.includes(''), 'blocks are separated by an empty line');
});

test('[crit 3] B2B has one line per registered document and rate; B2C is summed by place of supply and rate', () => {
  const b2b = block('B2B: registered customers').rows.filter(r => r[0] !== 'Total').map(r => r.join(','));
  assert.deepEqual(b2b.sort(), [
    'GC/125,12/10/2026,Demo Traders,24BBBBB1111B1Z3,Gujarat (24),Tax invoice,5.00,450.00,11.25,11.25,,22.50',
    'SRT/12,15/10/2026,Demo Traders,24BBBBB1111B1Z3,Gujarat (24),Tax invoice,5.00,217.50,5.50,5.50,,11.00',
    `SRT/13,20/10/2026,${NAME2},27CCCCC2222C1Z1,Maharashtra (27),Tax invoice,18.00,500.00,,,90.00,90.00`,
    'SRT/14,22/10/2026,Demo Traders,24BBBBB1111B1Z3,Gujarat (24),Tax invoice,5.00,300.00,7.50,7.50,,15.00',
  ].sort());
  const b2c = block('B2C: unregistered customers').rows.filter(r => r[0] !== 'Total');
  assert.equal(b2c.length, 1);
  assert.deepEqual([b2c[0][0], b2c[0][1], b2c[0][2], b2c[0][6]], ['Not given', '5.00', '100.00', '5.00']);
});

test('[crit 3] nil-rated and exempt: four lines (within or outside the state, registered or not); a rate-0 row goes here', () => {
  const rows = block('Nil-rated and exempt').rows.filter(r => r[0] !== 'Total');
  assert.equal(rows.length, 4);
  const key = r => `${r[0]}|${r[1]}`;
  assert.deepEqual(rows.map(key).sort(), ['Outside the state|Registered', 'Outside the state|Unregistered', 'Within the state|Registered', 'Within the state|Unregistered']);
  assert.equal(rows.find(r => key(r) === 'Within the state|Registered')[2], '200.00');
  for (const r of rows.filter(x => key(x) !== 'Within the state|Registered')) assert.equal(r[2], '0.00');
});

test('[crit 3] the working\'s blocks add up to the register\'s live totals (taxable + exempt, each tax head, tax); SAC summary too', () => {
  const total = sales.at(-1);
  const registerValue = cents(total[9]) + cents(total[10]);
  const totalRow = b => block(b).rows.find(r => r[0] === 'Total');
  const b1 = totalRow('B2B: registered customers'); const b2 = totalRow('B2C: unregistered customers');
  const b3 = totalRow('Nil-rated and exempt'); const b4 = totalRow('SAC summary');
  assert.ok(b1 && b2 && b3 && b4, 'blocks 1 to 4 end with a Total row');
  assert.equal(cents(b1[7]) + cents(b2[2]) + cents(b3[2]), registerValue);
  assert.equal(cents(b4[3]) + cents(b4[4]), registerValue);
  for (const [reg, i1, i2, i4] of [[12, 8, 3, 5], [13, 9, 4, 6], [14, 10, 5, 7]]) {
    assert.equal(cents(b1[i1]) + cents(b2[i2]), cents(total[reg]));
    assert.equal(cents(b4[i4]), cents(total[reg]));
  }
  assert.equal(cents(b1[11]) + cents(b2[6]), cents(total[15]));
  assert.equal(cents(b4[8]), cents(total[15]));
  const sac = block('SAC summary').rows.filter(r => r[0] !== 'Total').map(r => r.join(','));
  assert.ok(sac.some(r => r.startsWith('996719,Labour,5.00,90.00,0.00,2.26,2.26,')), `SAC row for labour at 5 %: ${sac.join(' / ')}`);
  assert.ok(sac.some(r => r.startsWith('996721,Storage,18.00,460.00,0.00,')), 'SAC row for storage at 18 %');
  assert.ok(sac.some(r => r.startsWith('996721,Storage,0.00,0.00,200.00,')), 'SAC row for the exempt storage');
});

test('[crit 3][crit 4] documents issued per type, and the missing numbers line (a list, or None)', () => {
  const issued = block('Documents issued').rows.map(r => r.join(','));
  assert.ok(issued.includes('Tax invoice,SRT/12,SRT/16,5,1'));
  assert.ok(issued.includes('Bill of supply,SRT/15,SRT/15,1,0'));
  assert.ok(issued.includes('Invoice (before GST details),SRT/18,SRT/18,1,0'));
  assert.ok(issued.includes('Missing numbers,SRT/17'), `the Missing numbers line names the gap: ${issued.join(' / ')}`);
  const none = makeData(); none.missing_numbers = [];
  const rows = parseCsv(file(accountantPackFiles(none), 'gstr1-working.csv').text);
  assert.ok(rows.some(r => r[0] === 'Missing numbers' && r[1] === 'None'));
  const many = makeData(); many.missing_numbers = ['SRT/17', 'SRT/19', 'SRT/21'];
  const rows3 = parseCsv(file(accountantPackFiles(many), 'gstr1-working.csv').text);
  assert.deepEqual(rows3.find(r => r[0] === 'Missing numbers'), ['Missing numbers', 'SRT/17 SRT/19 SRT/21'], 'space separated');
});

// ---------- [crit 5] the receipts register ----------
test('[crit 5] receipts-register.csv: the header, the example line, the Cash flag, quoting, modes, the Total row', () => {
  const lines = file(files, 'receipts-register.csv').text.slice(1).split('\r\n');
  assert.equal(lines[0], 'Date paid,Receipt number,Customer,Invoice number,Amount,Mode,Bank,Cheque or reference number,Note,"Cash of ₹2,00,000 or more",Imported');
  assert.ok(lines.includes('20/10/2026,APP-41,Demo Traders,SRT/12,229.00,UPI,,,,,'));
  assert.ok(lines.includes('21/10/2026,APP-42,Demo Traders,SRT/12,200000.00,Cash,,,,Yes,'), 'cash of 2,00,000 is flagged Yes');
  assert.ok(lines.includes('21/10/2026,APP-43,Demo Traders,SRT/12,199999.00,Cash,,,,,'), '1,99,999 is not');
  assert.ok(lines.includes('22/10/2026,OLD-7,Demo Traders,SRT/12,500.00,Cheque,Demo Bank,CHQ123,"Cheque, part",,'));
  assert.ok(lines.includes('24/10/2026,APP-44,Demo Traders,,40.00,Bank transfer,,,,,'), 'a payment that names no invoice has an empty invoice number');
  assert.ok(lines.includes('24/10/2026,APP-45,Demo Traders,SRT/12,60.00,wallet,,,,,'), 'an unknown mode is written as stored');
  assert.ok(lines.includes('26/10/2026,IMP-R1,Demo Traders,SRT/12,100.00,Cash,,,,,Yes'));
  assert.ok(lines.includes('25/10/2026,APP-46,Walk-in Payer,,15.00,Cash,,,,,'));
  const total = receipts.at(-1);
  assert.equal(total[0], 'Total');
  assert.equal(total[4], '400943.00');
  assert.equal(receipts.length, 1 + 8 + 1);
});

// ---------- the stock statement ----------
test('[crit 6] stock-statement.csv: the header, the example line, kg = bags x kg per bag, the Total row', () => {
  const text = file(files, 'stock-statement.csv').text; const lines = text.slice(1).split('\r\n'); const rows = parseCsv(text);
  assert.equal(lines[0], 'Customer,GRN,GRN date,Item,Packaging,Mark,Kg per bag,Bags at start,Kg at start,Bags received,Kg received,Bags sent,Kg sent,Bags at end,Kg at end,Imported');
  assert.ok(lines.includes('Demo Traders,G1001,02/09/2026,Jeera,50 kg bag,DT-7,50,120,6000,0,0,20,1000,100,5000,'));
  assert.ok(lines.includes(`${NAME2},G1002,05/10/2026,Garlic,Bag,,25,0,0,40,1000,10,250,30,750,Yes`));
  const total = rows.at(-1);
  assert.equal(total[0], 'Total');
  assert.deepEqual(total.slice(7, 15), ['120', '6000', '40', '1000', '30', '1250', '130', '5750']);
});

// ---------- [crit 7] the Sales vouchers balance, with the mapped ledger names ----------
const entriesOf = v => all(v, 'ALLLEDGERENTRIES.LIST').map(e => [kidText(e, 'LEDGERNAME'), kidText(e, 'ISDEEMEDPOSITIVE'), kidText(e, 'AMOUNT'), kidText(e, 'ISPARTYLEDGER')]);
const vouchersXml = () => parseXml(file(files, 'tally-vouchers.xml').text);
const salesVoucher = n => all(vouchersXml(), 'VOUCHER').find(v => kidText(v, 'VOUCHERNUMBER') === n && v.attrs.VCHTYPE === 'Sales' && kidText(v, 'ISCANCELLED') !== 'Yes');

test('[crit 7] each Sales voucher: AMOUNTs sum to 0.00, debit = Yes and negative, credit = No and positive, ledger names from the ledgers passed in', () => {
  const expected = {
    'SRT/12': [[NAME1, 'Yes', '-229.00'], ['L Rent', 'No', '187.50'], ['L Labour', 'No', '30.00'], ['L CGST', 'No', '5.50'], ['L SGST', 'No', '5.50'], ['L Round', 'No', '0.50']],
    'SRT/13': [[NAME2, 'Yes', '-590.00'], ['L Rent', 'No', '460.00'], ['L Labour', 'No', '40.00'], ['L IGST', 'No', '90.00']],
    'SRT/14': [[NAME1, 'Yes', '-310.00'], ['L Rent', 'No', '290.00'], ['L Labour', 'No', '10.00'], ['L CGST', 'No', '7.50'], ['L SGST', 'No', '7.50'], ['L Discount', 'Yes', '-5.00']],
    'SRT/15': [[NAME1, 'Yes', '-200.00'], ['L Rent Exempt', 'No', '200.00']],
    'SRT/18': [[NAME3, 'Yes', '-104.60'], ['L Rent', 'No', '100.00'], ['L CGST', 'No', '2.50'], ['L SGST', 'No', '2.50'], ['L Round', 'Yes', '-0.40']],
  };
  for (const [number, want] of Object.entries(expected)) {
    const v = salesVoucher(number);
    assert.ok(v, `a Sales voucher for ${number}`);
    const got = entriesOf(v);
    assert.deepEqual(got.map(e => e.slice(0, 3)), want, number);
    assert.equal(got.reduce((s, e) => s + Math.round(Number(e[2]) * 100), 0), 0, `${number} balances to 0.00`);
    assert.equal(got[0][3], 'Yes', 'the party entry is the party ledger');
    assert.ok(got.slice(1).every(e => e[3] !== 'Yes'));
  }
});

test('[crit 7] the voucher: type, identity, date, number, party, narration (a pair names the other document); zero entries are left out', () => {
  const v = salesVoucher('SRT/12');
  const d1 = makeData().documents.find(d => d.number === 'SRT/12');
  assert.deepEqual([v.attrs.REMOTEID, v.attrs.VCHTYPE, v.attrs.ACTION, v.attrs.OBJVIEW], [`wh-inv-${d1.id}`, 'Sales', 'Create', 'Accounting Voucher View']);
  assert.equal(kidText(v, 'GUID'), `wh-inv-${d1.id}`);
  assert.equal(kidText(v, 'VOUCHERTYPENAME'), 'Sales');
  assert.equal(kidText(v, 'DATE'), '20261015');
  assert.equal(kidText(v, 'PARTYLEDGERNAME'), NAME1);
  assert.equal(kidText(v, 'NARRATION'), 'GRN G1001');
  assert.equal(kidText(salesVoucher('SRT/14'), 'NARRATION'), 'GRN G1003; with SRT/15');
  assert.equal(kidText(salesVoucher('SRT/15'), 'NARRATION'), 'GRN G1003; with SRT/14');
  assert.ok(entriesOf(salesVoucher('SRT/12')).every(e => e[2] !== '0.00'));
});

test('[crit 7][crit 9] the vouchers: Sales for live app documents only (not imported, not cancelled), Receipt for app payments with a customer', () => {
  const vouchers = all(vouchersXml(), 'VOUCHER');
  assert.equal(vouchers.filter(v => v.attrs.VCHTYPE === 'Sales' && kidText(v, 'ISCANCELLED') !== 'Yes').length, 5);
  assert.equal(vouchers.filter(v => v.attrs.VCHTYPE === 'Receipt').length, 6);
  assert.equal(vouchers.length, 13);
  assert.ok(!vouchers.some(v => kidText(v, 'VOUCHERNUMBER') === 'GC/125'), '[crit 9] the imported document is not in the Tally file');
  assert.ok(!vouchers.some(v => (kidText(v, 'NARRATION') ?? '').includes('IMP-R1')), 'the imported payment is not in the Tally file');
  assert.ok(!vouchers.some(v => (kidText(v, 'NARRATION') ?? '').includes('APP-46')), 'a payment with no customer id has no voucher');
  const byNarration = n => vouchers.find(v => kidText(v, 'NARRATION') === n);
  const upi = byNarration('Receipt APP-41 for SRT/12');
  assert.ok(upi);
  assert.deepEqual([upi.attrs.REMOTEID, upi.attrs.VCHTYPE, upi.attrs.ACTION], [`wh-rcp-20000000-0000-4000-8000-000000000001`, 'Receipt', 'Create']);
  assert.equal(kidText(upi, 'DATE'), '20261020');
  assert.deepEqual(entriesOf(upi).map(e => e.slice(0, 3)), [[NAME1, 'No', '229.00'], ['L UPI', 'Yes', '-229.00']]);
  assert.equal(entriesOf(upi)[0][3], 'Yes');
  assert.deepEqual(entriesOf(byNarration('Receipt APP-42 for SRT/12')).map(e => e[0]), [NAME1, 'L Cash']);
  assert.deepEqual(entriesOf(byNarration('Receipt OLD-7 for SRT/12')).map(e => e[0]), [NAME1, 'L Cheque']);
  assert.deepEqual(entriesOf(byNarration('Receipt APP-44')).map(e => e[0]), [NAME1, 'L Bank Transfer'], 'a payment with no invoice: narration without "for"');
  assert.deepEqual(entriesOf(byNarration('Receipt APP-45 for SRT/12')).map(e => e[0]), [NAME1, 'L Other'], 'an unknown mode goes to receipt_other');
});

test('[crit 7] the before-GST document posts its stored tax half to CGST, the rest to SGST', () => {
  const entries = entriesOf(salesVoucher('SRT/18'));
  assert.deepEqual(entries.filter(e => ['L CGST', 'L SGST'].includes(e[0])).map(e => e.slice(0, 3)), [['L CGST', 'No', '2.50'], ['L SGST', 'No', '2.50']]);
});

// ---------- masters ----------
test('[crit 7] tally-masters.xml: envelope, one Sundry Debtors ledger per customer, none for the store\'s own ledgers', () => {
  const root = parseXml(file(files, 'tally-masters.xml').text);
  assert.equal(root.name, 'ENVELOPE');
  assert.equal(kidText(kid(root, 'HEADER'), 'TALLYREQUEST'), 'Import Data');
  const desc = kid(kid(kid(root, 'BODY'), 'IMPORTDATA'), 'REQUESTDESC');
  assert.equal(kidText(desc, 'REPORTNAME'), 'All Masters');
  const message = all(root, 'TALLYMESSAGE')[0];
  assert.equal(message.attrs['xmlns:UDF'], 'TallyUDF');
  assert.equal(all(root, 'SVCURRENTCOMPANY').length, 0);
  const ledgers = all(root, 'LEDGER');
  assert.deepEqual(ledgers.map(l => l.attrs.NAME).sort(), [NAME1, NAME2, NAME3].sort());
  for (const l of ledgers) { assert.equal(l.attrs.ACTION, 'Create'); assert.equal(kidText(l, 'PARENT'), 'Sundry Debtors'); assert.equal(kidText(l, 'NAME'), l.attrs.NAME); }
  const l1 = ledgers.find(l => l.attrs.NAME === NAME1);
  assert.equal(kidText(kid(l1, 'LEDGSTREGDETAILS.LIST'), 'GSTREGISTRATIONTYPE'), 'Regular');
  assert.equal(kidText(kid(l1, 'LEDGSTREGDETAILS.LIST'), 'GSTIN'), GSTIN1);
  assert.equal(kidText(kid(l1, 'LEDGSTREGDETAILS.LIST'), 'PLACEOFSUPPLY'), 'Gujarat');
  assert.equal(kidText(kid(l1, 'LEDMAILINGDETAILS.LIST'), 'STATE'), 'Gujarat');
  assert.equal(kidText(kid(l1, 'LEDMAILINGDETAILS.LIST'), 'COUNTRY'), 'India');
  const l3 = ledgers.find(l => l.attrs.NAME === NAME3);
  assert.equal(kidText(kid(l3, 'LEDGSTREGDETAILS.LIST'), 'GSTREGISTRATIONTYPE'), 'Unregistered/Consumer');
});

test('tally-vouchers.xml: envelope with REPORTNAME Vouchers and no SVCURRENTCOMPANY; text is escaped; characters XML 1.0 forbids are removed', () => {
  const root = vouchersXml();
  assert.equal(kidText(kid(root, 'HEADER'), 'TALLYREQUEST'), 'Import Data');
  assert.equal(kidText(kid(kid(kid(root, 'BODY'), 'IMPORTDATA'), 'REQUESTDESC'), 'REPORTNAME'), 'Vouchers');
  assert.equal(all(root, 'TALLYMESSAGE')[0].attrs['xmlns:UDF'], 'TallyUDF');
  assert.equal(all(root, 'SVCURRENTCOMPANY').length, 0);
  assert.equal(kidText(salesVoucher('SRT/18'), 'PARTYLEDGERNAME'), NAME3, 'a name with & < > and quotes round-trips');
  assert.ok(!file(files, 'tally-vouchers.xml').text.includes(NAME3), 'and is escaped in the text');
  const dirty = makeData();
  for (const c of dirty.customers) if (c.id === C3) c.name = 'Ram\u0001 & Sons\u000b <Traders> "Q"';
  for (const d of dirty.documents) if (d.customer_id === C3) d.customer_name = 'Ram\u0001 & Sons\u000b <Traders> "Q"';
  const out = accountantPackFiles(dirty);
  for (const name of ['tally-masters.xml', 'tally-vouchers.xml']) {
    assert.ok(!/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(file(out, name).text), `${name} holds no character XML 1.0 forbids`);
    parseXml(file(out, name).text);
  }
  assert.equal(all(parseXml(file(out, 'tally-masters.xml').text), 'LEDGER').filter(l => l.attrs.NAME === NAME3).length, 1);
});

// ---------- [crit 8] the same identities every time ----------
test('[crit 8] two builds give the same REMOTEID and GUID for every voucher, whatever the time of the pack', () => {
  const a = accountantPackFiles(makeData());
  const later = makeData(); later.made_at = '2026-12-05T09:00:00+00:00'; later.made_by = 'Someone Else';
  const b = accountantPackFiles(later);
  const ids = f => all(parseXml(file(f, 'tally-vouchers.xml').text), 'VOUCHER').map(v => `${v.attrs.REMOTEID}|${kidText(v, 'GUID')}`);
  assert.deepEqual(ids(a), ids(b));
  assert.equal(new Set(ids(a)).size, ids(a).length, 'no two vouchers share an identity');
  assert.equal(file(a, 'tally-vouchers.xml').text, file(b, 'tally-vouchers.xml').text, 'the vouchers file does not depend on the time of the pack');
  assert.equal(file(a, 'tally-masters.xml').text, file(b, 'tally-masters.xml').text);
});

test('[crit 8] the identity function and the frozen TALLY object (section 6)', () => {
  assert.ok(Object.isFrozen(TALLY));
  assert.equal(TALLY.guid('sales', 'abc'), 'wh-inv-abc');
  assert.equal(TALLY.guid('receipt', 'abc'), 'wh-rcp-abc');
});

// ---------- the README (criteria 4, 9, 14) ----------
const readme = crlf(file(files, 'README.txt').text);
const BEFORE = "Before importing: in Tally, turn on 'Overwrite voucher when a voucher with same GUID exists'. If it is off, importing a pack a second time adds every bill again.";

test('README.txt: the header lines, the file list with counts', () => {
  assert.deepEqual(readme.slice(0, 6), ['Accountant pack', 'Facility: Demo Cold Storage. GSTIN: 24AAAAA0000A1Z5', 'Period: 01/10/2026 to 31/10/2026',
    'Made on 01/11/2026 11:00 (India time) by Demo Administrator', '', 'Files']);
  assert.match(readme[6], /^sales-register\.csv: \d+ documents, 1 cancelled$/);
  assert.deepEqual(readme.slice(7, 12), ['receipts-register.csv: 8 payments', 'gstr1-working.csv: a working to check, not a return', 'stock-statement.csv: 2 lines',
    'tally-masters.xml: 3 customer ledgers', 'tally-vouchers.xml: 5 sales vouchers, 6 receipt vouchers, 2 cancellations']);
  assert.deepEqual(readme.slice(12, 14), ['', 'Notes']);
});

test('README.txt: a facility without GST details reads "Not registered"; Record payments off replaces the receipts line', () => {
  const data = makeData(); data.facility.gstin = null; data.facility.registered = false; data.record_payments = false; data.payments = null;
  const lines = crlf(file(accountantPackFiles(data), 'README.txt').text);
  assert.equal(lines[1], 'Facility: Demo Cold Storage. GSTIN: Not registered');
  assert.equal(lines[7], 'Record payments is off: no receipts register and no receipt vouchers.');
  assert.ok(!lines.some(l => l.startsWith('receipts-register.csv')));
  assert.ok(lines.includes('tally-vouchers.xml: 5 sales vouchers, 0 receipt vouchers, 2 cancellations'));
});

test('[crit 9] README.txt notes: before-GST documents counted and numbered, with the split-equally line; imported counts; payments naming no invoice', () => {
  const i = readme.findIndex(l => l.startsWith('Documents made before GST details were saved: 1: SRT/18'));
  assert.ok(i > 13, 'the before-GST line names the count and the number');
  assert.ok(readme[i].includes('Their tax is shown as stored in the Tax column; their GST columns are empty.'));
  assert.equal(readme[i + 1], 'Tax on these was split equally between CGST and SGST. Check them.');
  assert.equal(readme[i + 2], 'Imported from the previous system: 1 documents, 1 payments. They are in the registers and not in the Tally files.');
  assert.ok(readme.some(l => l === 'Payments that name no invoice: 2'));
});

test('[crit 4] README.txt names the missing document numbers', () => {
  const line = readme.find(l => l.startsWith('Missing document numbers: '));
  assert.ok(line && line.includes('SRT/17'), line);
});

test('[crit 14] README.txt: "Cancelled in Tally by this pack" names every cancellation of the pack, with both dates', () => {
  assert.ok(readme.includes('Cancelled in Tally by this pack: SRT/16 (dated 12/10/2026, cancelled 14/10/2026), SRT/9 (dated 20/09/2026, cancelled 18/10/2026)'));
  const a = makeData(); a.cancellations = [a.cancellations[0]];
  assert.ok(crlf(file(accountantPackFiles(a), 'README.txt').text).includes('Cancelled in Tally by this pack: SRT/16 (dated 12/10/2026, cancelled 14/10/2026)'));
  const b = makeData(); b.cancellations = [b.cancellations[1]];
  assert.ok(crlf(file(accountantPackFiles(b), 'README.txt').text).includes('Cancelled in Tally by this pack: SRT/9 (dated 20/09/2026, cancelled 18/10/2026)'));
  const none = makeData(); none.cancellations = [];
  assert.ok(crlf(file(accountantPackFiles(none), 'README.txt').text).includes('Cancelled in Tally by this pack: None'));
});

test('README.txt: earlier documents changed, renamed customers', () => {
  assert.ok(readme.includes('Documents of earlier months changed in this period: SRT/5'));
  assert.ok(readme.includes('Customers whose name changed since 01/10/2026: Old Traders is now Demo Traders'));
});

test('[crit 9][crit 13] README.txt Tally section: "Before importing" is the first line under Tally, the "on trial" line next, then the order of import and the ledgers used', () => {
  const t = readme.indexOf('Tally');
  assert.ok(t > 0);
  assert.equal(readme[t - 1], '');
  assert.equal(readme[t + 1], BEFORE);
  assert.equal(readme[t + 2], 'The two Tally files are on trial. Import them into a copy of your company first.');
  assert.equal(readme[t + 3], 'Import tally-masters.xml first, then tally-vouchers.xml.');
  assert.ok(readme[t + 4].startsWith('Ledgers used: '));
  const entries = readme[t + 4].slice('Ledgers used: '.length).split('; ');
  assert.equal(entries.length, 13);
  const names = entries.map(e => e.slice(e.lastIndexOf(': ') + 2));
  assert.deepEqual(names, Object.values(makeData().ledgers));
});

// ---------- CSV rules (section 5) ----------
test('CSV: a field with a comma, quote, CR or LF is quoted with quotes doubled; a text cell starting = + - @ tab or CR gets a leading apostrophe; number cells never', () => {
  assert.ok(file(files, 'sales-register.csv').text.includes(',"Ram & Sons <Traders> ""Q""",'), 'quotes doubled');
  const d4 = sales.find(r => r[1] === 'SRT/18');
  assert.equal(d4[17], '-0.40', 'a negative number is not guarded');
  assert.equal(d4[3], NAME3);
  for (const bad of ['=HYPERLINK("x")', '+1', '-x', '@SUM(A1)', '\tTab']) {
    const data = makeData(); data.documents[2].customer_name = bad;
    const rows = parseCsv(file(accountantPackFiles(data), 'sales-register.csv').text);
    assert.equal(rows.find(r => r[1] === 'SRT/12')[3], `'${bad}`, bad);
  }
  const data = makeData(); data.documents[2].customer_name = 'Line\r\nBreak, "Co"';
  const rows = parseCsv(file(accountantPackFiles(data), 'sales-register.csv').text);
  assert.equal(rows.find(r => r[1] === 'SRT/12')[3], 'Line\r\nBreak, "Co"');
});

// ---------- the file name ----------
test('packFileName: whole month and part of a month, the facility slug', () => {
  const data = makeData();
  assert.equal(packFileName(data), 'demo-cold-storage-accountant-pack-2026-10.zip');
  data.period = { from_date: '2026-10-05', to_date: '2026-10-20', fin_year: 2026, whole_month: false };
  assert.equal(packFileName(data), 'demo-cold-storage-accountant-pack-2026-10-05-to-2026-10-20.zip');
  data.facility.name = 'Ram & Sons!!  Cold  Store ';
  assert.equal(packFileName(data), 'ram-sons-cold-store-accountant-pack-2026-10-05-to-2026-10-20.zip');
  data.facility.name = 'ગુરુ કોલ્ડ સ્ટોરેજ';
  assert.equal(packFileName(data), 'facility-accountant-pack-2026-10-05-to-2026-10-20.zip');
  data.facility.name = 'a'.repeat(50);
  assert.equal(packFileName(data), `${'a'.repeat(40)}-accountant-pack-2026-10-05-to-2026-10-20.zip`);
  const named = makeData(); named.facility.name = 'Shown Name'; named.facility.legal_name = 'Legal Name Ltd';
  assert.equal(packFileName(named), 'shown-name-accountant-pack-2026-10.zip', 'the slug is the facility name, not the legal name');
});
