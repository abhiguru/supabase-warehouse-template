// The files of the accountant pack (WH-158; contract product/tech/accountant-pack.md sections 5 and 6). `data` is the inner `data`
// object get_accountant_pack answers: every row is already split and every amount is as stored (D2), so nothing here works out a
// rate, a tax or a charge again. Amounts are read into whole paise and only added up as integers; they are written with two
// decimals. Output depends only on `data`: the same read gives the same files.
import { tallyMastersXml, tallyVouchersXml } from './tally-xml.ts';
import type { TallyEntry, TallyLedger, TallyVoucher } from './tally-xml.ts';

type Amount = number | string | null | undefined;

export const LEDGER_KEYS = ['storage_taxable', 'storage_exempt', 'labour', 'cgst', 'sgst', 'igst', 'discount', 'round_off',
  'receipt_cash', 'receipt_upi', 'receipt_bank_transfer', 'receipt_cheque', 'receipt_other'] as const;
export type LedgerKey = typeof LEDGER_KEYS[number];

/** The English field labels of the Accountant export screen (contract section 7), for the README's "Ledgers used" line. */
const LEDGER_LABELS: Record<LedgerKey, string> = {
  storage_taxable: 'Storage rent (taxable)', storage_exempt: 'Storage rent (exempt)', labour: 'Labour', cgst: 'CGST', sgst: 'SGST',
  igst: 'IGST', discount: 'Discount', round_off: 'Round-off', receipt_cash: 'Cash', receipt_upi: 'UPI',
  receipt_bank_transfer: 'Bank transfer', receipt_cheque: 'Cheque', receipt_other: 'Other receipts',
};

export interface PackRow {
  kind: 'storage' | 'labour'; exempt: boolean; rate: Amount; taxable_value: Amount; exempt_value: Amount;
  cgst: Amount; sgst: Amount; igst: Amount; tax: Amount;
}
export interface PackDocument {
  id: string; doc_type: string; number: string; date: string; customer_id: string | null; customer_name: string | null;
  customer_gstin: string | null; customer_state: string | null; place_of_supply: string | null; sac_storage: string | null;
  sac_labour: string | null; tax_head: string | null; gr_no: string | null; linked_number: string | null; status: 'live' | 'cancelled';
  cancelled_on: string | null; imported: boolean; before_gst: boolean; discount: Amount; round_off: Amount; total: Amount; rows: PackRow[];
}
export interface PackCancellation {
  id: string; doc_type: string; number: string; date: string; cancelled_on: string; customer_id: string | null;
  customer_name: string | null; reason: 'in_period' | 'cancelled_in_period' | 'exported';
}
export interface PackPayment {
  id: string; payment_no: string; paid_on: string; customer_id: string | null; customer_name: string | null; invoice_id: string | null;
  invoice_number: string | null; amount: Amount; mode: string | null; bank: string | null; reference: string | null; note: string | null;
  cash_large: boolean; imported: boolean;
}
export interface PackStock {
  customer_name: string | null; gr_no: string | null; grn_date: string | null; item_name: string | null; packaging: string | null;
  mark: string | null; kg_per_bag: number | null; start_bags: number; received_bags: number; sent_bags: number; end_bags: number; imported: boolean;
}
export interface AccountantPackData {
  made_at: string; made_by: string | null;
  facility: { name: string | null; legal_name: string | null; gstin: string | null; state_code: string | null; state_name: string | null;
    registered: boolean; gst_saved: boolean };
  period: { from_date: string; to_date: string; fin_year: number; whole_month: boolean };
  record_payments: boolean;
  ledgers: Record<LedgerKey, string>;
  documents: PackDocument[];
  cancellations: PackCancellation[];
  changed_earlier: { number: string; date: string; changed_on: string }[];
  payments: PackPayment[] | null;
  stock: PackStock[];
  issued: { doc_type: string; first_number: string; last_number: string; count: number; cancelled: number }[];
  missing_numbers: string[];
  customers: { id: string; name: string; gstin: string | null; state_name: string | null }[];
  renamed_customers: { old_name: string; new_name: string; changed_on: string }[];
}
export interface PackFile { name: string; text: string }

// ---------- amounts, in paise ----------

/** An amount as whole paise. A stored amount has two decimals; a longer one is rounded half away from zero. Empty is 0. */
export function toPaise(value: Amount): number {
  if (value === null || value === undefined || value === '') return 0;
  let text: string;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error(`accountant pack: ${value} is not an amount`);
    text = String(value);
    if (/e/i.test(text)) { // a tiny or huge number: never a stored amount
      const p = Math.sign(value) * Math.round(Math.abs(value) * 100);
      if (!Number.isSafeInteger(p)) throw new Error(`accountant pack: ${text} is out of range`);
      return p === 0 ? 0 : p;
    }
  } else if (typeof value === 'string') {
    text = value.trim();
  } else {
    throw new Error('accountant pack: an amount is not a number');
  }
  const m = /^([+-])?(\d+)(?:\.(\d*))?$/.exec(text);
  if (!m) throw new Error(`accountant pack: ${JSON.stringify(text)} is not an amount`);
  const fraction = (m[3] ?? '').padEnd(3, '0');
  let p = Number(m[2]) * 100 + Number(fraction.slice(0, 2));
  if (fraction.charCodeAt(2) >= 53 /* '5' */) p += 1;
  if (!Number.isSafeInteger(p)) throw new Error(`accountant pack: ${text} is out of range`);
  return m[1] === '-' && p !== 0 ? -p : p;
}

/** Paise written as rupees with two decimals: 123450 -> 1234.50, -1200 -> -12.00. */
export function formatPaise(paise: number): string {
  const sign = paise < 0 ? '-' : '';
  const a = Math.abs(paise);
  return `${sign}${Math.floor(a / 100)}.${String(a % 100).padStart(2, '0')}`;
}

const money = (value: Amount): string => formatPaise(toPaise(value));
const nullableMoney = (value: Amount): string => (value === null || value === undefined ? '' : money(value));
const isNull = (value: Amount): boolean => value === null || value === undefined;

function whole(value: number | null | undefined): number {
  const n = Number(value ?? 0);
  if (!Number.isFinite(n)) throw new Error('accountant pack: a count is not a number');
  return Math.round(n);
}

/** A nullable sum: null until a non-null value is added (an empty tax-head cell). */
type Head = number | null;
const addHead = (sum: Head, value: Amount): Head => (isNull(value) ? sum : (sum ?? 0) + toPaise(value));
const headCell = (sum: Head): string => (sum === null ? '' : formatPaise(sum));

// ---------- dates ----------

function dateParts(value: string | null | undefined): [string, string, string] | null {
  if (value === null || value === undefined || value === '') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(value));
  if (!m) throw new Error(`accountant pack: ${JSON.stringify(value)} is not a date`);
  return [m[1], m[2], m[3]];
}
/** YYYY-MM-DD -> DD/MM/YYYY (empty stays empty). */
const dmy = (value: string | null | undefined): string => { const p = dateParts(value); return p ? `${p[2]}/${p[1]}/${p[0]}` : ''; };
/** YYYY-MM-DD -> YYYYMMDD, Tally's form. */
const ymd = (value: string): string => { const p = dateParts(value); if (!p) throw new Error('accountant pack: a voucher has no date'); return p.join(''); };

const INDIA_OFFSET_MS = 330 * 60 * 1000;
/** An ISO time on India's clock: DD/MM/YYYY HH:MM. */
function indiaDateTime(iso: string): string {
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) throw new Error('accountant pack: made_at is not a time');
  const d = new Date(ms + INDIA_OFFSET_MS);
  const two = (n: number) => String(n).padStart(2, '0');
  return `${two(d.getUTCDate())}/${two(d.getUTCMonth() + 1)}/${d.getUTCFullYear()} ${two(d.getUTCHours())}:${two(d.getUTCMinutes())}`;
}

// ---------- CSV ----------

/** A text cell: one starting with = + - @ tab or CR gets a leading apostrophe, so a spreadsheet does not read it as a formula. */
function text(value: unknown): string {
  const s = value === null || value === undefined ? '' : String(value);
  return /^[=+\-@\t\r]/.test(s) ? `'${s}` : s;
}
const field = (s: string): string => (/[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
/** UTF-8 text with a byte-order mark, CRLF after every line, comma separated. */
const csv = (rows: string[][]): string => '﻿' + rows.map(r => `${r.map(field).join(',')}\r\n`).join('');

const DOC_TYPES: Record<string, string> = {
  tax_invoice: 'Tax invoice', bill_of_supply: 'Bill of supply', invoice_cum_bos: 'Invoice-cum-bill of supply', bill: 'Bill',
  invoice: 'Invoice (before GST details)',
};
const docType = (type: string): string => DOC_TYPES[type] ?? text(type);
const KINDS: Record<string, string> = { storage: 'Storage', labour: 'Labour' };
const kindText = (kind: string): string => KINDS[kind] ?? text(kind);
const MODES: Record<string, string> = { cash: 'Cash', upi: 'UPI', bank_transfer: 'Bank transfer', cheque: 'Cheque', other: 'Other' };
const modeText = (mode: string | null): string => (mode !== null && mode in MODES ? MODES[mode] : text(mode));
const yes = (flag: boolean): string => (flag ? 'Yes' : '');
const isLive = (doc: PackDocument): boolean => doc.status !== 'cancelled';
const rowsOf = (doc: PackDocument): PackRow[] => (Array.isArray(doc.rows) ? doc.rows : []);
const sacOf = (doc: PackDocument, row: PackRow): string | null => (row.kind === 'labour' ? doc.sac_labour : doc.sac_storage);
/** A row's tax: as stored, else the sum of its heads. */
const rowTax = (row: PackRow): number =>
  isNull(row.tax) ? toPaise(row.cgst) + toPaise(row.sgst) + toPaise(row.igst) : toPaise(row.tax);
/** A row's value: taxable + exempt. */
const rowValue = (row: PackRow): number => toPaise(row.taxable_value) + toPaise(row.exempt_value);

function salesRegister(data: AccountantPackData): string {
  const lines: string[][] = [['Document type', 'Number', 'Date', 'Customer', 'Customer GSTIN', 'Customer state', 'Place of supply', 'SAC',
    'Storage or labour', 'Taxable value', 'Exempt value', 'Tax rate', 'CGST', 'SGST', 'IGST', 'Tax', 'Discount', 'Round-off',
    'Document total', 'Status', 'Cancelled on', 'Linked document', 'GRN', 'Imported']];
  const sum = { taxable: 0, exempt: 0, cgst: 0, sgst: 0, igst: 0, tax: 0, discount: 0, roundOff: 0, total: 0 };
  for (const doc of data.documents) {
    const live = isLive(doc);
    const head = [docType(doc.doc_type), text(doc.number), dmy(doc.date), text(doc.customer_name), text(doc.customer_gstin),
      text(doc.customer_state), text(doc.place_of_supply)];
    const tail = [live ? 'Live' : 'Cancelled', dmy(doc.cancelled_on), text(doc.linked_number), text(doc.gr_no), yes(doc.imported)];
    const docFigures = [money(doc.discount), money(doc.round_off), money(doc.total)];
    const rows = rowsOf(doc);
    // A document whose rows all had no value still gets its line, so its total is listed and counted.
    if (rows.length === 0) lines.push([...head, '', '', '', '', '', '', '', '', '', ...docFigures, ...tail]);
    rows.forEach((row, i) => {
      lines.push([...head, text(sacOf(doc, row)), kindText(row.kind), money(row.taxable_value), money(row.exempt_value), money(row.rate),
        nullableMoney(row.cgst), nullableMoney(row.sgst), nullableMoney(row.igst), formatPaise(rowTax(row)),
        ...(i === 0 ? docFigures : ['', '', '']), ...tail]);
      if (live) {
        sum.taxable += toPaise(row.taxable_value); sum.exempt += toPaise(row.exempt_value);
        sum.cgst += toPaise(row.cgst); sum.sgst += toPaise(row.sgst); sum.igst += toPaise(row.igst); sum.tax += rowTax(row);
      }
    });
    if (live) { sum.discount += toPaise(doc.discount); sum.roundOff += toPaise(doc.round_off); sum.total += toPaise(doc.total); }
  }
  lines.push(['Total (live documents)', '', '', '', '', '', '', '', '', formatPaise(sum.taxable), formatPaise(sum.exempt), '',
    formatPaise(sum.cgst), formatPaise(sum.sgst), formatPaise(sum.igst), formatPaise(sum.tax), formatPaise(sum.discount),
    formatPaise(sum.roundOff), formatPaise(sum.total), '', '', '', '', '']);
  return csv(lines);
}

function receiptsRegister(payments: PackPayment[]): string {
  const lines: string[][] = [['Date paid', 'Receipt number', 'Customer', 'Invoice number', 'Amount', 'Mode', 'Bank',
    'Cheque or reference number', 'Note', 'Cash of ₹2,00,000 or more', 'Imported']];
  let total = 0;
  for (const p of payments) {
    lines.push([dmy(p.paid_on), text(p.payment_no), text(p.customer_name), text(p.invoice_number), money(p.amount), modeText(p.mode),
      text(p.bank), text(p.reference), text(p.note), yes(p.cash_large), yes(p.imported)]);
    total += toPaise(p.amount);
  }
  lines.push(['Total', '', '', '', formatPaise(total), '', '', '', '', '', '']);
  return csv(lines);
}

interface Group { taxable: number; exempt: number; cgst: Head; sgst: Head; igst: Head; tax: number }
const newGroup = (): Group => ({ taxable: 0, exempt: 0, cgst: null, sgst: null, igst: null, tax: 0 });
function addRow(g: Group, row: PackRow): void {
  g.taxable += toPaise(row.taxable_value); g.exempt += toPaise(row.exempt_value);
  g.cgst = addHead(g.cgst, row.cgst); g.sgst = addHead(g.sgst, row.sgst); g.igst = addHead(g.igst, row.igst); g.tax += rowTax(row);
}
const headSum = (groups: Group[], key: 'cgst' | 'sgst' | 'igst'): string => formatPaise(groups.reduce((s, g) => s + (g[key] ?? 0), 0));
const plainSum = (groups: Group[], key: 'taxable' | 'exempt' | 'tax'): string => formatPaise(groups.reduce((s, g) => s + g[key], 0));

/** The two-digit state code of "Gujarat (24)", or null. */
function stateCode(value: string | null | undefined): string | null {
  const m = /\((\d{1,2})\)\s*$/.exec(String(value ?? ''));
  return m ? m[1].padStart(2, '0') : null;
}
const compareText = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

function gstr1Working(data: AccountantPackData): string {
  const live = data.documents.filter(isLive);
  const facilityCode = data.facility.state_code ? String(data.facility.state_code).padStart(2, '0') : null;
  const b2b = new Map<string, { doc: PackDocument; rate: number; g: Group }>();
  const b2c = new Map<string, { place: string; rate: number; g: Group }>();
  const nil = new Map<string, number>([['Within the state|Registered', 0], ['Within the state|Unregistered', 0],
    ['Outside the state|Registered', 0], ['Outside the state|Unregistered', 0]]);
  const sac = new Map<string, { sac: string; kind: string; rate: number; g: Group }>();
  live.forEach((doc, index) => {
    const registered = Boolean(doc.customer_gstin);
    for (const row of rowsOf(doc)) {
      const rate = toPaise(row.rate);
      if (rate === 0 || row.exempt) {
        const code = stateCode(doc.place_of_supply);
        const outside = code !== null && facilityCode !== null && code !== facilityCode;
        const key = `${outside ? 'Outside the state' : 'Within the state'}|${registered ? 'Registered' : 'Unregistered'}`;
        nil.set(key, (nil.get(key) ?? 0) + rowValue(row));
      } else if (registered) {
        const key = `${index}|${rate}`;
        if (!b2b.has(key)) b2b.set(key, { doc, rate, g: newGroup() });
        addRow(b2b.get(key)!.g, row);
      } else {
        const place = doc.place_of_supply ? String(doc.place_of_supply) : 'Not given';
        const key = `${place}|${rate}`;
        if (!b2c.has(key)) b2c.set(key, { place, rate, g: newGroup() });
        addRow(b2c.get(key)!.g, row);
      }
      const code = sacOf(doc, row) ?? '';
      const sacKey = `${code}|${row.kind}|${rate}`;
      if (!sac.has(sacKey)) sac.set(sacKey, { sac: code, kind: row.kind, rate, g: newGroup() });
      addRow(sac.get(sacKey)!.g, row);
    }
  });

  const lines: string[][] = [['A working for your accountant to check. It is not a return.']];

  const b2bRows = [...b2b.values()];
  lines.push(['B2B: registered customers'],
    ['Number', 'Date', 'Customer', 'Customer GSTIN', 'Place of supply', 'Document type', 'Tax rate', 'Taxable value', 'CGST', 'SGST', 'IGST', 'Tax']);
  for (const { doc, rate, g } of b2bRows) {
    lines.push([text(doc.number), dmy(doc.date), text(doc.customer_name), text(doc.customer_gstin), text(doc.place_of_supply),
      docType(doc.doc_type), formatPaise(rate), formatPaise(g.taxable + g.exempt), headCell(g.cgst), headCell(g.sgst), headCell(g.igst),
      formatPaise(g.tax)]);
  }
  const b2bGroups = b2bRows.map(r => r.g);
  lines.push(['Total', '', '', '', '', '', '', formatPaise(b2bGroups.reduce((s, g) => s + g.taxable + g.exempt, 0)),
    headSum(b2bGroups, 'cgst'), headSum(b2bGroups, 'sgst'), headSum(b2bGroups, 'igst'), plainSum(b2bGroups, 'tax')], ['']);

  const b2cRows = [...b2c.values()].sort((a, b) => compareText(a.place, b.place) || a.rate - b.rate);
  lines.push(['B2C: unregistered customers'], ['Place of supply', 'Tax rate', 'Taxable value', 'CGST', 'SGST', 'IGST', 'Tax']);
  for (const { place, rate, g } of b2cRows) {
    lines.push([text(place), formatPaise(rate), formatPaise(g.taxable + g.exempt), headCell(g.cgst), headCell(g.sgst), headCell(g.igst),
      formatPaise(g.tax)]);
  }
  const b2cGroups = b2cRows.map(r => r.g);
  lines.push(['Total', '', formatPaise(b2cGroups.reduce((s, g) => s + g.taxable + g.exempt, 0)), headSum(b2cGroups, 'cgst'),
    headSum(b2cGroups, 'sgst'), headSum(b2cGroups, 'igst'), plainSum(b2cGroups, 'tax')], ['']);

  lines.push(['Nil-rated and exempt'], ['Supply', 'Customer', 'Value']);
  let nilTotal = 0;
  for (const [key, value] of nil) { const [supply, customer] = key.split('|'); lines.push([supply, customer, formatPaise(value)]); nilTotal += value; }
  lines.push(['Total', '', formatPaise(nilTotal)], ['']);

  const kindOrder = (kind: string): number => (kind === 'storage' ? 0 : kind === 'labour' ? 1 : 2);
  const sacRows = [...sac.values()].sort((a, b) =>
    (a.sac === '' ? 1 : 0) - (b.sac === '' ? 1 : 0) || compareText(a.sac, b.sac) || kindOrder(a.kind) - kindOrder(b.kind) ||
    compareText(a.kind, b.kind) || a.rate - b.rate);
  lines.push(['SAC summary'], ['SAC', 'Storage or labour', 'Tax rate', 'Taxable value', 'Exempt value', 'CGST', 'SGST', 'IGST', 'Tax']);
  for (const { sac: code, kind, rate, g } of sacRows) {
    lines.push([text(code), kindText(kind), formatPaise(rate), formatPaise(g.taxable), formatPaise(g.exempt), headCell(g.cgst),
      headCell(g.sgst), headCell(g.igst), formatPaise(g.tax)]);
  }
  const sacGroups = sacRows.map(r => r.g);
  lines.push(['Total', '', '', plainSum(sacGroups, 'taxable'), plainSum(sacGroups, 'exempt'), headSum(sacGroups, 'cgst'),
    headSum(sacGroups, 'sgst'), headSum(sacGroups, 'igst'), plainSum(sacGroups, 'tax')], ['']);

  lines.push(['Documents issued'], ['Document type', 'First number', 'Last number', 'How many', 'Cancelled']);
  for (const i of data.issued) {
    lines.push([docType(i.doc_type), text(i.first_number), text(i.last_number), String(whole(i.count)), String(whole(i.cancelled))]);
  }
  const missing = data.missing_numbers ?? [];
  lines.push(['Missing numbers', missing.length ? text(missing.join(' ')) : 'None'], ['']);
  return csv(lines);
}

function stockStatement(stock: PackStock[]): string {
  const lines: string[][] = [['Customer', 'GRN', 'GRN date', 'Item', 'Packaging', 'Mark', 'Kg per bag', 'Bags at start', 'Kg at start',
    'Bags received', 'Kg received', 'Bags sent', 'Kg sent', 'Bags at end', 'Kg at end', 'Imported']];
  const totals = [0, 0, 0, 0, 0, 0, 0, 0];
  for (const s of stock) {
    const kgPerBag = whole(s.kg_per_bag);
    const figures = [s.start_bags, s.received_bags, s.sent_bags, s.end_bags].flatMap(b => { const bags = whole(b); return [bags, bags * kgPerBag]; });
    figures.forEach((n, i) => { totals[i] += n; });
    lines.push([text(s.customer_name), text(s.gr_no), dmy(s.grn_date), text(s.item_name), text(s.packaging), text(s.mark),
      s.kg_per_bag === null || s.kg_per_bag === undefined ? '' : String(kgPerBag), ...figures.map(String), yes(s.imported)]);
  }
  lines.push(['Total', '', '', '', '', '', '', ...totals.map(String), '']);
  return csv(lines);
}

// ---------- Tally ----------

function ledgerName(data: AccountantPackData, key: LedgerKey): string {
  const name = data.ledgers?.[key];
  if (typeof name !== 'string' || name.trim() === '') throw new Error(`accountant pack: no ledger name for ${key}`);
  return name;
}

/** Signed entries (a credit positive, a debit negative), 0.00 left out. */
function entries(list: [string, number, boolean][]): TallyEntry[] {
  return list.filter(([, paise]) => paise !== 0)
    .map(([ledger, paise, party]) => ({ ledger, amount: formatPaise(paise), debit: paise < 0, party }));
}

function salesVoucher(data: AccountantPackData, doc: PackDocument): TallyVoucher {
  let storageTaxable = 0; let storageExempt = 0; let labour = 0; let cgst = 0; let sgst = 0; let igst = 0; let unsplit = 0;
  for (const row of rowsOf(doc)) {
    const value = rowValue(row);
    if (row.kind === 'labour') labour += value;
    else if (row.exempt) storageExempt += value;
    else storageTaxable += value;
    if (isNull(row.cgst) && isNull(row.sgst) && isNull(row.igst)) unsplit += rowTax(row);
    else { cgst += toPaise(row.cgst); sgst += toPaise(row.sgst); igst += toPaise(row.igst); }
  }
  // Tax stored as one figure (a document made before GST details): half to CGST rounded half away from zero, the rest to SGST,
  // so an odd paisa goes to CGST (6.25 -> 3.13 + 3.12), the rule of gst_half (migration 173).
  const half = Math.sign(unsplit) * Math.ceil(Math.abs(unsplit) / 2);
  cgst += half; sgst += unsplit - half;
  const party = String(doc.customer_name ?? '');
  const narration = [doc.gr_no ? `GRN ${doc.gr_no}` : '', doc.linked_number ? `with ${doc.linked_number}` : ''].filter(Boolean).join('; ');
  return {
    kind: 'sales', id: doc.id, date: ymd(doc.date), number: String(doc.number ?? ''), party, narration, cancelled: false,
    entries: entries([
      [party, -toPaise(doc.total), true],
      [ledgerName(data, 'storage_taxable'), storageTaxable, false],
      [ledgerName(data, 'storage_exempt'), storageExempt, false],
      [ledgerName(data, 'labour'), labour, false],
      [ledgerName(data, 'cgst'), cgst, false],
      [ledgerName(data, 'sgst'), sgst, false],
      [ledgerName(data, 'igst'), igst, false],
      [ledgerName(data, 'discount'), -toPaise(doc.discount), false],
      [ledgerName(data, 'round_off'), toPaise(doc.round_off), false],
    ]),
  };
}

const RECEIPT_LEDGERS: Record<string, LedgerKey> = {
  cash: 'receipt_cash', upi: 'receipt_upi', bank_transfer: 'receipt_bank_transfer', cheque: 'receipt_cheque', other: 'receipt_other',
};

function receiptVoucher(data: AccountantPackData, p: PackPayment): TallyVoucher {
  const amount = toPaise(p.amount);
  const party = String(p.customer_name ?? '');
  const ledger = ledgerName(data, (p.mode !== null && RECEIPT_LEDGERS[p.mode]) || 'receipt_other');
  return {
    kind: 'receipt', id: p.id, date: ymd(p.paid_on), number: String(p.payment_no ?? ''), party,
    narration: `Receipt ${p.payment_no}${p.invoice_number ? ` for ${p.invoice_number}` : ''}`, cancelled: false,
    entries: entries([[party, amount, true], [ledger, -amount, false]]),
  };
}

const cancellationVoucher = (c: PackCancellation): TallyVoucher => ({
  kind: 'sales', id: c.id, date: ymd(c.date), number: String(c.number ?? ''), party: null,
  narration: `Cancelled on ${dmy(c.cancelled_on)}`, entries: [], cancelled: true,
});

/** "Gujarat (24)" -> "Gujarat"; a plain name is kept. */
const stateName = (value: string | null): string | null => {
  const s = String(value ?? '').replace(/\s*\(\d{1,2}\)\s*$/, '').trim();
  return s === '' ? null : s;
};

// ---------- README ----------

/** A value on one README line: control characters (line breaks included) become spaces. */
const oneLine = (value: unknown): string => String(value ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ');
const listOrNone = (items: string[], separator: string): string => (items.length ? items.map(oneLine).join(separator) : 'None');

function readme(data: AccountantPackData, counts: { payments: number | null; sales: number; receipts: number; cancellations: number }): string {
  const f = data.facility;
  const docs = data.documents;
  const beforeGst = docs.filter(d => d.before_gst).map(d => d.number);
  const payments = counts.payments === null ? [] : (data.payments ?? []);
  const missing = data.missing_numbers ?? [];
  const missingText = missing.length === 0 ? 'None'
    : missing.slice(0, 50).map(oneLine).join(', ') + (missing.length > 50 ? ` and ${missing.length - 50} more` : '');
  const ledgersUsed = LEDGER_KEYS.map(key => `${LEDGER_LABELS[key]}: ${oneLine(ledgerName(data, key))}`).join('; ');
  const lines = [
    'Accountant pack',
    `Facility: ${oneLine(f.legal_name || f.name)}. GSTIN: ${f.registered && f.gstin ? oneLine(f.gstin) : 'Not registered'}`,
    `Period: ${dmy(data.period.from_date)} to ${dmy(data.period.to_date)}`,
    `Made on ${indiaDateTime(data.made_at)} (India time)${data.made_by ? ` by ${oneLine(data.made_by)}` : ''}`,
    '',
    'Files',
    `sales-register.csv: ${docs.length} documents, ${docs.filter(d => !isLive(d)).length} cancelled`,
    counts.payments === null ? 'Record payments is off: no receipts register and no receipt vouchers.' : `receipts-register.csv: ${counts.payments} payments`,
    'gstr1-working.csv: a working to check, not a return',
    `stock-statement.csv: ${data.stock.length} lines`,
    `tally-masters.xml: ${data.customers.length} customer ledgers`,
    `tally-vouchers.xml: ${counts.sales} sales vouchers, ${counts.receipts} receipt vouchers, ${counts.cancellations} cancellations`,
    '',
    'Notes',
    `Documents made before GST details were saved: ${beforeGst.length}: ${listOrNone(beforeGst, ', ')}. Their tax is shown as stored in the Tax column; their GST columns are empty.`,
    'Tax on these was split equally between CGST and SGST. Check them.',
    `Imported from the previous system: ${docs.filter(d => d.imported).length} documents, ${payments.filter(p => p.imported).length} payments. They are in the registers and not in the Tally files.`,
    `Missing document numbers: ${missingText}`,
    `Payments that name no invoice: ${payments.filter(p => !p.invoice_id).length}`,
    `Cancelled in Tally by this pack: ${listOrNone(data.cancellations.map(c => `${c.number} (dated ${dmy(c.date)}, cancelled ${dmy(c.cancelled_on)})`), ', ')}`,
    `Documents of earlier months changed in this period: ${listOrNone((data.changed_earlier ?? []).map(c => c.number), ', ')}`,
    `Customers whose name changed since ${dmy(data.period.from_date)}: ${listOrNone((data.renamed_customers ?? []).map(r => `${oneLine(r.old_name)} is now ${oneLine(r.new_name)}`), '; ')}`,
    '',
    'Tally',
    "Before importing: in Tally, turn on 'Overwrite voucher when a voucher with same GUID exists'. If it is off, importing a pack a second time adds every bill again.",
    'The two Tally files are on trial. Import them into a copy of your company first.',
    'Import tally-masters.xml first, then tally-vouchers.xml.',
    `Ledgers used: ${ledgersUsed}`,
  ];
  return lines.map(l => `${l}\r\n`).join('');
}

// ---------- the pack ----------

/** The pack's files, in the order of the zip (contract section 5). The receipts register only when Record payments is on. */
export function accountantPackFiles(data: AccountantPackData): PackFile[] {
  const paymentsOn = data.record_payments === true;
  const payments = paymentsOn ? (data.payments ?? []) : [];
  const sales = data.documents.filter(d => isLive(d) && !d.imported).map(d => salesVoucher(data, d));
  const receipts = payments.filter(p => !p.imported && p.customer_id).map(p => receiptVoucher(data, p));
  const cancellations = (data.cancellations ?? []).map(cancellationVoucher);
  const ledgers: TallyLedger[] = data.customers.map(c => ({ name: c.name, gstin: c.gstin || null, state: stateName(c.state_name) }));

  const files: PackFile[] = [
    { name: 'README.txt', text: readme(data, { payments: paymentsOn ? payments.length : null, sales: sales.length, receipts: receipts.length,
      cancellations: cancellations.length }) },
    { name: 'sales-register.csv', text: salesRegister(data) },
  ];
  if (paymentsOn) files.push({ name: 'receipts-register.csv', text: receiptsRegister(payments) });
  files.push(
    { name: 'gstr1-working.csv', text: gstr1Working(data) },
    { name: 'stock-statement.csv', text: stockStatement(data.stock ?? []) },
    { name: 'tally-masters.xml', text: tallyMastersXml(ledgers) },
    { name: 'tally-vouchers.xml', text: tallyVouchersXml([...sales, ...receipts, ...cancellations]) },
  );
  return files;
}

/** The zip's name: `<slug>-accountant-pack-<YYYY-MM>.zip` for a whole month, else `<slug>-accountant-pack-<from>-to-<to>.zip`. */
export function packFileName(data: AccountantPackData): string {
  const slug = String(data.facility?.name ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '')
    .slice(0, 40).replace(/-+$/, '') || 'facility';
  const { from_date: from, to_date: to, whole_month: wholeMonth } = data.period;
  dateParts(from); dateParts(to);
  return wholeMonth ? `${slug}-accountant-pack-${from.slice(0, 7)}.zip` : `${slug}-accountant-pack-${from.slice(0, 10)}-to-${to.slice(0, 10)}.zip`;
}
