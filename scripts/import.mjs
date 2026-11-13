// CSV import for a facility: customers, items and rates (WH-142), and past years' GRNs, dispatches, invoices and payments from an old
// system (WH-180). Run it through scripts/import.sh, which takes the operator lock.
//
//   WAREHOUSE_STATE_DIR=/abs/state bash scripts/import.sh [--folder <dir>] [--customers customers.csv] [--items items.csv] [--rates rates.csv] [--apply]
//
// Without --apply it is a dry run: the files are read and checked, the database is asked what an import would do (it really runs the
// import and rolls it back), and nothing is saved. With --apply the same run is kept, only when there is no error, all or nothing, and only
// when a backup made and verified today (India) is on record (config/backups-verified.list, as scripts/watch.mjs keeps it).
// Exit status: 0 = no error, 1 = at least one error (or the database could not be reached, or no backup of today), 2 = wrong usage.
// The file format, the checks and the answer are in docs/OPERATOR_INSTALL.md, "Import customers, items and rates" and "Import past years".
//
// Past years (--folder with any of grns.csv, grn-lines.csv, dispatches.csv, dispatch-lines.csv, invoices.csv, invoice-lines.csv,
// payments.csv): each file is read twice as a stream, never whole. The first pass checks every cell and the repeats within the file; when
// no file has a format error, the second pass writes the normalised rows into the staging tables of migration 192 with COPY, in one psql
// session that then calls public.import_history (with the customers, items and rates as WH-142's payload) and commits or rolls back.
import { createReadStream, lstatSync, readFileSync, statSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';
import { readVerifiedList } from './watch.mjs';

export const ENCODING_MESSAGE = 'Save the file as CSV UTF-8 and try again.';
const MAX_BYTES = 5 * 1024 * 1024;
const MAX_ROWS = 20000;

// The columns of each file, in template order. `label` is the header (the English label of the app's form, matched without regard to case
// and outer spaces); `field` is the key sent to import_batch (migration 171).
export const LAYOUT = {
  customers: [
    { field: 'name', label: 'Customer name', required: true },
    { field: 'mobile', label: 'Mobile number', required: true },
    { field: 'email', label: 'Email' },
    { field: 'address', label: 'Full address' },
    { field: 'city', label: 'City' },
    { field: 'state', label: 'State' },
    { field: 'pincode', label: 'Pincode' },
    { field: 'gst', label: 'GST number' },
    { field: 'pan', label: 'PAN' },
    { field: 'contact_person', label: 'Contact name' },
    { field: 'contact_mobile', label: 'Contact mobile' },
    { field: 'contact_email', label: 'Contact email' },
  ],
  items: [
    { field: 'name', label: 'Item name', required: true },
    { field: 'packaging', label: 'Packaging', required: true },
    { field: 'description', label: 'Description' },
  ],
  rates: [
    { field: 'item_name', label: 'Item name', required: true },
    { field: 'packaging', label: 'Packaging', required: true },
    { field: 'customer', label: 'Customer name' },
    { field: 'price_type', label: 'Price type', required: true },
    { field: 'start_on', label: 'Start date', required: true },
    { field: 'weight_min', label: 'From (kg)', required: true },
    { field: 'weight_max', label: 'Up to (kg)', required: true },
    { field: 'rent', label: 'Rent (₹)', required: true },
    { field: 'labour', label: 'Labour (₹)', required: true },
    { field: 'tax', label: 'Tax (%)', required: true },
  ],
};
export const FILES = Object.keys(LAYOUT);

export const EXAMPLES = {
  customers: [['Example Traders', '9876543210', 'accounts@example.com', '12 Market Road', 'Ahmedabad', 'Gujarat', '380001', '24AAAAA0000A1Z5', 'AAAAA0000A', 'Asha Example', '9123456780', 'asha@example.com']],
  items: [['Example Potato', 'Bag', 'Table potato']],
  rates: [['Example Potato', 'Bag', '', 'Monthly', '01/04/2026', '0', '50', '12.50', '2.00', '0']],
};

// ---- Reading -------------------------------------------------------------------------------------------------------------------

export function decodeUtf8(buffer) {
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(buffer); } catch { throw new Error(ENCODING_MESSAGE); }
  return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
}

// RFC 4180: comma-separated, double quotes, "" inside quotes, line breaks (LF, CRLF, CR) inside quotes belong to the cell.
// Returns [{ line, cells }] where line is the physical line the record starts on. A comma-or-semicolon guess is not made: Excel and
// Google Sheets "CSV UTF-8" use commas, and a header that does not match says so.
export function parseCsv(text) {
  const records = [];
  let cells = [];
  let cell = '';
  let quoted = false;
  let line = 1;
  let start = 1;
  let touched = false;
  const endCell = () => { cells.push(cell); cell = ''; };
  const endRecord = () => { endCell(); records.push({ line: start, cells }); cells = []; touched = false; };
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') { cell += '"'; i++; } else quoted = false;
      } else {
        if (ch === '\n' || (ch === '\r' && text[i + 1] !== '\n')) line++;
        cell += ch;
      }
      continue;
    }
    if (ch === '"' && cell === '') { quoted = true; touched = true; continue; }
    if (ch === ',') { endCell(); touched = true; continue; }
    if (ch === '\r' || ch === '\n') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      if (touched || cell !== '' || cells.length) endRecord();
      line++;
      start = line;
      continue;
    }
    cell += ch;
    touched = true;
  }
  if (quoted) throw new Error(`file line ${start}: a quoted cell is never closed`);
  if (touched || cell !== '' || cells.length) endRecord();
  return records;
}

// ---- Checks --------------------------------------------------------------------------------------------------------------------

const GUJARATI_DIGITS = '૦૧૨૩૪૫૬૭૮૯';
const asciiDigits = s => s.replace(/[૦-૯]/g, d => String(GUJARATI_DIGITS.indexOf(d)));
const clean = s => s.replace(/^[\s\p{Z}\p{Cf}]+|[\s\p{Z}\p{Cf}]+$/gu, '');
export const nameKey = s => clean(s).toLowerCase().replace(/[\s\p{Z}\p{Cf}]+/gu, ' ');
export const packagingKey = s => {
  const k = clean(s).toLowerCase();
  if (/^(bags?)?$/.test(k)) return 'bag';
  if (/^box(es)?$/.test(k)) return 'box';
  if (/^crates?$/.test(k)) return 'crate';
  return k;
};
export function nationalMobile(value) {
  const digits = asciiDigits(value).replace(/\D/g, '');
  if (digits.length === 12 && digits.startsWith('91')) return digits.slice(2);
  if (digits.length === 11 && digits.startsWith('0')) return digits.slice(1);
  return digits;
}
export function parseDate(text) {
  const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(asciiDigits(text));
  if (!m) return null;
  const [d, mo, y] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const date = new Date(Date.UTC(y, mo - 1, d));
  if (date.getUTCFullYear() !== y || date.getUTCMonth() !== mo - 1 || date.getUTCDate() !== d) return null;
  return `${String(y).padStart(4, '0')}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}
const AMOUNT = /^\d{1,6}(\.\d{1,2})?$/;
const WHOLE = /^\d{1,6}$/;

const maxLen = (label, value, max) => (value.length > max ? `${label} is longer than ${max} characters` : null);
const CUSTOMER_RULES = {
  name: v => (v.length < 2 ? 'Customer name needs at least 2 characters' : maxLen('Customer name', v, 80)),
  mobile: v => (/^[6-9]\d{9}$/.test(nationalMobile(v)) ? null : `"${v}" is not a 10-digit mobile number`),
  email: v => (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? maxLen('Email', v, 100) : `"${v}" is not an email address`),
  address: v => maxLen('Full address', v, 300),
  city: v => maxLen('City', v, 25),
  state: v => maxLen('State', v, 50),
  pincode: v => (/^[1-9][0-9]{5}$/.test(asciiDigits(v)) ? null : `Pincode "${v}" must be 6 digits`),
  gst: v => (/^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/.test(v.toUpperCase()) ? null : `GST number "${v}" must be 15 characters, like 22AAAAA0000A1Z5`),
  pan: v => (/^[A-Z]{5}[0-9]{4}[A-Z]$/.test(v.toUpperCase()) ? null : `PAN "${v}" must be 10 characters, like AAAAA0000A`),
  contact_person: v => maxLen('Contact name', v, 100),
  contact_mobile: v => (/^[6-9]\d{9}$/.test(nationalMobile(v)) ? null : `"${v}" is not a 10-digit mobile number`),
  contact_email: v => (/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v) ? maxLen('Contact email', v, 100) : `"${v}" is not an email address`),
};
const ITEM_RULES = {
  name: v => maxLen('Item name', v, 80),
  packaging: v => maxLen('Packaging', v, 40),
  description: v => maxLen('Description', v, 40),
};

// text of one file -> { rows: [{ line, ...fields }], problems: [{ kind: 'error', file, line, column, reason }], read }
export function checkFile(file, text) {
  const layout = LAYOUT[file];
  const name = `${file}.csv`;
  const problems = [];
  const problem = (line, column, reason) => problems.push({ kind: 'error', file: name, line, column, reason });
  let records;
  try { records = parseCsv(text); } catch (e) { return { rows: [], read: 0, problems: [{ kind: 'error', file: name, line: Number(/line (\d+)/.exec(e.message)?.[1] ?? 1), column: null, reason: e.message.replace(/^file line \d+: /, '') }] }; }
  if (records.length === 0) return { rows: [], read: 0, problems: [{ kind: 'error', file: name, line: 1, column: null, reason: 'the file is empty; it needs a header row' }] };
  const header = records[0].cells.map(c => clean(c));
  const index = new Map();
  header.forEach((h, i) => {
    const match = layout.find(col => col.label.toLowerCase() === h.toLowerCase());
    if (!match) { problem(records[0].line, h || `column ${i + 1}`, `unknown column "${h}"; the columns are: ${layout.map(c => c.label).join(', ')}`); return; }
    if (index.has(match.field)) { problem(records[0].line, match.label, 'this column appears twice'); return; }
    index.set(match.field, i);
  });
  for (const col of layout) if (col.required && !index.has(col.field)) problem(records[0].line, col.label, 'this required column is missing');
  if (problems.length) return { rows: [], read: records.length - 1, problems };

  const data = records.slice(1).filter(r => r.cells.some(c => clean(c) !== ''));
  if (data.length > MAX_ROWS) return { rows: [], read: data.length, problems: [{ kind: 'error', file: name, line: 1, column: null, reason: `more than ${MAX_ROWS} rows; split the file` }] };
  const rows = [];
  const seen = new Map();
  const dup = (key, line, column, what) => {
    if (seen.has(key)) { problem(line, column, `${what} is already on line ${seen.get(key)} of this file`); return true; }
    seen.set(key, line);
    return false;
  };
  for (const rec of data) {
    const before = problems.length;
    const line = rec.line;
    if (rec.cells.length > header.length && rec.cells.slice(header.length).some(c => clean(c) !== '')) {
      problem(line, null, `the row has ${rec.cells.length} cells but the header has ${header.length}; a comma inside a cell needs the cell in quotes`);
      continue;
    }
    const row = { line };
    for (const col of layout) {
      const raw = index.has(col.field) ? clean(rec.cells[index.get(col.field)] ?? '') : '';
      row[col.field] = raw;
      if (raw === '' && col.required) problem(line, col.label, 'this is required');
    }
    if (file === 'customers') {
      for (const col of layout) if (row[col.field] !== '') { const why = CUSTOMER_RULES[col.field](row[col.field]); if (why) problem(line, col.label, why); }
      if (problems.length === before) {
        row.mobile = nationalMobile(row.mobile);
        if (row.contact_mobile) row.contact_mobile = nationalMobile(row.contact_mobile);
        row.gst = row.gst.toUpperCase();
        row.pan = row.pan.toUpperCase();
        row.pincode = asciiDigits(row.pincode);
        dup(`n:${nameKey(row.name)}`, line, 'Customer name', `the customer "${row.name}"`);
        dup(`m:${row.mobile}`, line, 'Mobile number', `the mobile number ${row.mobile}`);
      }
    } else if (file === 'items') {
      for (const col of layout) if (row[col.field] !== '') { const why = ITEM_RULES[col.field](row[col.field]); if (why) problem(line, col.label, why); }
      if (problems.length === before) dup(`${nameKey(row.name)}|${packagingKey(row.packaging)}`, line, 'Item name', `the item "${row.name}" with the packaging "${row.packaging}"`);
    } else {
      if (row.item_name.length > 80) problem(line, 'Item name', 'Item name is longer than 80 characters');
      const type = row.price_type.toLowerCase().replace(/[\s_-]+/g, '');
      if (row.price_type !== '' && type !== 'monthly' && type !== 'onetime') problem(line, 'Price type', `"${row.price_type}" must be Monthly or One-time`);
      row.price_type = type === 'onetime' ? 'one_time' : 'monthly';
      const date = row.start_on === '' ? null : parseDate(row.start_on);
      if (row.start_on !== '' && !date) problem(line, 'Start date', `"${row.start_on}" is not a date; write it as DD/MM/YYYY`);
      row.start_on = date;
      for (const [field, label] of [['weight_min', 'From (kg)'], ['weight_max', 'Up to (kg)']]) {
        const v = asciiDigits(row[field]);
        if (row[field] !== '' && !WHOLE.test(v)) problem(line, label, `"${row[field]}" must be whole kilograms, like 40`);
        else if (row[field] !== '') row[field] = Number(v);
      }
      if (typeof row.weight_min === 'number' && typeof row.weight_max === 'number' && row.weight_min > row.weight_max) problem(line, 'Up to (kg)', 'must not be less than From (kg)');
      for (const [field, label, limit] of [['rent', 'Rent (₹)', 9999.99], ['labour', 'Labour (₹)', 9999.99], ['tax', 'Tax (%)', 100]]) {
        const v = asciiDigits(row[field]);
        if (row[field] === '') continue;
        if (!AMOUNT.test(v) || Number(v) > limit) problem(line, label, `"${row[field]}" must be a plain number from 0 to ${limit} with at most two decimals`);
        else row[field] = Number(v);
      }
      if (problems.length === before) {
        dup(`${nameKey(row.item_name)}|${packagingKey(row.packaging)}|${nameKey(row.customer)}|${row.price_type}|${row.start_on}|${row.weight_min}`,
          line, 'From (kg)', `a rate for the same item, customer, start date and weight from ${row.weight_min} kg`);
      }
    }
    if (problems.length === before) rows.push(row);
  }
  return { rows, read: data.length, problems };
}

// ---- Past years (WH-180) ------------------------------------------------------------------------------------------------------

const HISTORY_MAX_BYTES = 512 * 1024 * 1024;
const HISTORY_MAX_ROWS = 3000000;
const PROBLEMS_SHOWN = 200;

// Column kinds: text (max length), docno (a GRN or dispatch number as issued), date, int (whole number, min), amount (up to 10 digits and two
// decimals), pct (0-100), pricing, invno (an invoice number as issued), mode (payment mode). `col` is the staging column (migration 192);
// the order of each list is the staging table's column order after `line`.
export const HISTORY_LAYOUT = {
  grns: [
    { label: 'GRN number', col: 'gr_no', kind: 'docno', required: true },
    { label: 'GRN date', col: 'gr_date', kind: 'date', required: true },
    { label: 'Customer name', col: 'customer', kind: 'text', max: 80, required: true },
    { label: 'Pricing', col: 'pricing', kind: 'pricing' },
    { label: 'Vehicle', col: 'vehicle', kind: 'text', max: 20 },
    { label: 'Sender', col: 'sender', kind: 'text', max: 200 },
    { label: 'Note', col: 'note', kind: 'text', max: 280 },
  ],
  'grn-lines': [
    { label: 'GRN number', col: 'gr_no', kind: 'docno', required: true },
    { label: 'GRN date', col: 'gr_date', kind: 'date', required: true },
    { label: 'Line', col: 'line_no', kind: 'int', min: 1, required: true },
    { label: 'Item name', col: 'item', kind: 'text', max: 80, required: true },
    { label: 'Packaging', col: 'packaging', kind: 'text', max: 40, required: true },
    { label: 'Quantity', col: 'qty', kind: 'int', min: 1, required: true },
    { label: 'Kg each', col: 'weight', kind: 'int', min: 0, max: 9999 },
    { label: 'Rack', col: 'rack', kind: 'text', max: 30, digits: true },
    { label: 'Mark', col: 'mark', kind: 'text', max: 60, digits: true },
    { label: 'Stock now', col: 'stock_now', kind: 'int', min: 0 },
  ],
  dispatches: [
    { label: 'Dispatch number', col: 'disp_no', kind: 'docno', required: true },
    { label: 'Dispatch date', col: 'disp_date', kind: 'date', required: true },
    { label: 'Customer name', col: 'customer', kind: 'text', max: 80, required: true },
    { label: 'Vehicle', col: 'vehicle', kind: 'text', max: 20 },
    { label: 'Note', col: 'note', kind: 'text', max: 800 },
  ],
  'dispatch-lines': [
    { label: 'Dispatch number', col: 'disp_no', kind: 'docno', required: true },
    { label: 'Dispatch date', col: 'disp_date', kind: 'date', required: true },
    { label: 'GRN number', col: 'gr_no', kind: 'docno', required: true },
    { label: 'GRN date', col: 'gr_date', kind: 'date', required: true },
    { label: 'GRN line', col: 'grn_line', kind: 'int', min: 1, required: true },
    { label: 'Quantity', col: 'qty', kind: 'int', min: 1, required: true },
  ],
  invoices: [
    { label: 'Invoice number', col: 'inv', kind: 'invno', required: true },
    { label: 'Invoice date', col: 'inv_date', kind: 'date', required: true },
    { label: 'Customer name', col: 'customer', kind: 'text', max: 80, required: true },
    { label: 'GRN number', col: 'gr_no', kind: 'docno', required: true },
    { label: 'GRN date', col: 'gr_date', kind: 'date', required: true },
    { label: 'Name on invoice', col: 'inv_name', kind: 'text', max: 300 },
    { label: 'Labour', col: 'labour', kind: 'amount', required: true },
    { label: 'Tax', col: 'tax', kind: 'amount', required: true },
    { label: 'Discount', col: 'discount', kind: 'amount' },
    { label: 'Total', col: 'total', kind: 'amount', required: true },
    { label: 'Note', col: 'note', kind: 'text', max: 800 },
  ],
  'invoice-lines': [
    { label: 'Invoice number', col: 'inv', kind: 'invno', required: true },
    { label: 'Invoice date', col: 'inv_date', kind: 'date', required: true },
    { label: 'Item name', col: 'item', kind: 'text', max: 80, required: true },
    { label: 'Packaging', col: 'packaging', kind: 'text', max: 40, required: true },
    { label: 'Quantity', col: 'qty', kind: 'int', min: 0, required: true },
    { label: 'Dispatch number', col: 'disp_no', kind: 'docno' },
    { label: 'Dispatch date', col: 'disp_date', kind: 'date' },
    { label: 'GRN line', col: 'grn_line', kind: 'int', min: 1 },
    { label: 'Months', col: 'months', kind: 'amount' },
    { label: 'Days', col: 'days', kind: 'int', min: 0 },
    { label: 'Rate', col: 'rate', kind: 'amount', required: true },
    { label: 'Labour rate', col: 'labour_rate', kind: 'amount' },
    { label: 'Tax (%)', col: 'tax_pct', kind: 'pct' },
    { label: 'Storage amount', col: 'storage', kind: 'amount', required: true },
    { label: 'Labour amount', col: 'labour', kind: 'amount' },
    { label: 'Tax amount', col: 'tax_amount', kind: 'amount', required: true },
  ],
  payments: [
    { label: 'Receipt number', col: 'receipt', kind: 'text', max: 30, required: true },
    { label: 'Payment date', col: 'pay_date', kind: 'date', required: true },
    { label: 'Customer name', col: 'customer', kind: 'text', max: 80, required: true },
    { label: 'Invoice number', col: 'inv', kind: 'invno' },
    { label: 'Invoice date', col: 'inv_date', kind: 'date' },
    { label: 'Amount', col: 'amount', kind: 'amount', required: true, positive: true },
    { label: 'Mode', col: 'mode', kind: 'mode' },
    { label: 'Note', col: 'note', kind: 'text', max: 800 },
  ],
};
export const HISTORY_FILES = Object.keys(HISTORY_LAYOUT);
const stageTable = file => `warehouse_import.stage_${file.replace('-', '_')}`;
// The staging columns of each file after `line`, in order (an invoice number is staged as label, number and prefix; a reference to one
// as label and number).
const STAGE_COLUMNS = {
  grns: ['gr_no', 'gr_date', 'customer', 'pricing', 'vehicle', 'sender', 'note'],
  'grn-lines': ['gr_no', 'gr_date', 'line_no', 'item', 'packaging', 'qty', 'weight', 'rack', 'mark', 'stock_now'],
  dispatches: ['disp_no', 'disp_date', 'customer', 'vehicle', 'note'],
  'dispatch-lines': ['disp_no', 'disp_date', 'gr_no', 'gr_date', 'grn_line', 'qty'],
  invoices: ['inv_label', 'inv_no', 'inv_prefix', 'inv_date', 'customer', 'gr_no', 'gr_date', 'inv_name', 'labour', 'tax', 'discount', 'total', 'note'],
  'invoice-lines': ['inv_label', 'inv_no', 'inv_date', 'item', 'packaging', 'qty', 'disp_no', 'disp_date', 'grn_line', 'months', 'days', 'rate',
    'labour_rate', 'tax_pct', 'storage', 'labour', 'tax_amount'],
  payments: ['receipt', 'pay_date', 'customer', 'inv_label', 'inv_no', 'inv_date', 'amount', 'mode', 'note'],
};

export const HISTORY_EXAMPLES = {
  grns: [['G-101', '05/05/2023', 'Example Traders', 'Monthly', 'GJ00XX0000', 'Example Farms', '']],
  'grn-lines': [['G-101', '05/05/2023', '1', 'Example Potato', 'Bag', '100', '50', 'A1', 'ET', '']],
  dispatches: [['D-201', '14/06/2023', 'Example Traders', 'GJ00XX0000', '']],
  'dispatch-lines': [['D-201', '14/06/2023', 'G-101', '05/05/2023', '1', '60']],
  invoices: [['GC/125', '20/06/2023', 'Example Traders', 'G-101', '05/05/2023', '', '120.00', '0.00', '', '4250.00', '']],
  'invoice-lines': [['GC/125', '20/06/2023', 'Example Potato', 'Bag', '60', 'D-201', '14/06/2023', '1', '1.5', '', '45.00', '2.00', '0', '4130.00', '120.00', '0.00']],
  payments: [['R-301', '30/06/2023', 'Example Traders', 'GC/125', '20/06/2023', '3250.00', 'Cash', '']],
};

const DOC_NUMBER = /^[A-Za-z0-9/-]{1,20}$/;
const BIG_AMOUNT = /^\d{1,10}(\.\d{1,2})?$/;
const BIG_WHOLE = /^\d{1,9}$/;
const MODES = { cash: 'cash', upi: 'upi', banktransfer: 'bank_transfer', bank: 'bank_transfer', neft: 'bank_transfer', rtgs: 'bank_transfer', imps: 'bank_transfer', cheque: 'cheque', check: 'cheque', other: 'other' };

// An invoice number as issued: the trailing run of digits is the number, everything before it (with that run's leading zeros) the prefix,
// so "GC/000125" is 125 with the prefix "GC/000" and prints back as issued. Returns { no, prefix } or { why }.
export function splitInvoiceNumber(text) {
  const m = /^(.*?)(\d+)$/.exec(text);
  if (!m) return { why: `"${text}" must end in digits, like GC/125` };
  const zeros = /^0*/.exec(m[2])[0];
  const digits = m[2].slice(zeros.length);
  if (digits === '' || digits.length > 9) return { why: `"${text}" must end in a number from 1 to 999999999` };
  const prefix = m[1] + zeros;
  if (!/^[A-Z0-9/-]{0,8}$/.test(prefix)) return { why: `the part before the number ("${prefix}") must be at most 8 capital letters, digits, / or -` };
  return { no: Number(digits), prefix };
}

// One cell: { value } (normalised; null for empty) or { why }.
function historyCell(col, raw) {
  if (raw === '') return { value: null };
  const v = asciiDigits(raw);
  switch (col.kind) {
    case 'text': {
      const value = col.digits ? v : raw;
      return value.length > col.max ? { why: `${col.label} is longer than ${col.max} characters` } : { value };
    }
    case 'docno': return DOC_NUMBER.test(v) ? { value: v } : { why: `"${raw}" must be 1 to 20 letters, digits, / or -` };
    case 'date': { const d = parseDate(raw); return d ? { value: d } : { why: `"${raw}" is not a date; write it as DD/MM/YYYY` }; }
    case 'int': {
      if (!BIG_WHOLE.test(v)) return { why: `"${raw}" must be a whole number` };
      const n = Number(v);
      if (n < (col.min ?? 0)) return { why: `"${raw}" must be at least ${col.min}` };
      if (col.max !== undefined && n > col.max) return { why: `"${raw}" must be at most ${col.max}` };
      return { value: n };
    }
    case 'amount': {
      if (!BIG_AMOUNT.test(v)) return { why: `"${raw}" must be a plain number with at most two decimals (no ₹ sign, no commas)` };
      if (col.positive && Number(v) <= 0) return { why: `"${raw}" must be more than 0` };
      return { value: v };
    }
    case 'pct': return AMOUNT.test(v) && Number(v) <= 100 ? { value: v } : { why: `"${raw}" must be a number from 0 to 100 with at most two decimals` };
    case 'pricing': {
      const t = raw.toLowerCase().replace(/[\s_-]+/g, '');
      if (t === 'monthly') return { value: 'MONTHLY' };
      if (t === 'onetime') return { value: 'ONE_TIME' };
      return { why: `"${raw}" must be Monthly or One-time` };
    }
    case 'invno': { const r = splitInvoiceNumber(raw); return r.why ? { why: r.why } : { value: raw, no: r.no, prefix: r.prefix }; }
    case 'mode': {
      const m = MODES[raw.toLowerCase().replace(/[\s_-]+/g, '')];
      return m ? { value: m } : { why: `"${raw}" must be Cash, UPI, Bank transfer, Cheque or Other (or empty)` };
    }
    default: throw new Error(`unknown column kind ${col.kind}`);
  }
}

// One data record -> { stage: [cells after line], key, problems }.
export function checkHistoryRecord(file, index, header, rec) {
  const layout = HISTORY_LAYOUT[file];
  const name = `${file}.csv`;
  const problems = [];
  const problem = (column, reason) => problems.push({ kind: 'error', file: name, line: rec.line, column, reason });
  if (rec.cells.length > header.length && rec.cells.slice(header.length).some(c => clean(c) !== '')) {
    problem(null, `the row has ${rec.cells.length} cells but the header has ${header.length}; a comma inside a cell needs the cell in quotes`);
    return { problems };
  }
  const row = {};
  for (const col of layout) {
    const raw = index.has(col.col) ? clean(rec.cells[index.get(col.col)] ?? '') : '';
    if (raw === '') { if (col.required) problem(col.label, 'this is required'); row[col.col] = { value: null }; continue; }
    const cell = historyCell(col, raw);
    if (cell.why) problem(col.label, cell.why);
    row[col.col] = cell;
  }
  const val = c => row[c]?.value ?? null;
  // Cells that go together.
  if (file === 'grns' && row.pricing.value === null) row.pricing = { value: 'MONTHLY' };
  if (file === 'invoice-lines') {
    if ((val('disp_no') === null) !== (val('disp_date') === null)) problem(val('disp_no') === null ? 'Dispatch number' : 'Dispatch date', 'Dispatch number and Dispatch date go together');
    if (val('grn_line') !== null && val('disp_no') === null) problem('GRN line', 'a GRN line needs the Dispatch number and Dispatch date');
  }
  if (file === 'payments' && (val('inv') === null) !== (val('inv_date') === null)) {
    problem(val('inv') === null ? 'Invoice number' : 'Invoice date', 'Invoice number and Invoice date go together');
  }
  if (problems.length) return { problems };

  let key = null;
  const k = (...parts) => parts.join('\u001f');
  if (file === 'grns') key = { key: k(val('gr_no'), val('gr_date')), column: 'GRN number', what: `GRN ${val('gr_no')} of that date` };
  else if (file === 'grn-lines') key = { key: k(val('gr_no'), val('gr_date'), val('line_no')), column: 'Line', what: `line ${val('line_no')} of GRN ${val('gr_no')}` };
  else if (file === 'dispatches') key = { key: k(val('disp_no'), val('disp_date')), column: 'Dispatch number', what: `dispatch ${val('disp_no')} of that date` };
  else if (file === 'dispatch-lines') key = { key: k(val('disp_no'), val('disp_date'), val('gr_no'), val('gr_date'), val('grn_line')), column: 'GRN line', what: 'this dispatch line' };
  else if (file === 'invoices') key = { key: k(row.inv.no, val('inv_date')), column: 'Invoice number', what: `invoice ${val('inv')} of that date` };
  else if (file === 'payments') key = { key: k(nameKey(val('customer')), val('receipt'), val('pay_date')), column: 'Receipt number', what: `receipt ${val('receipt')} of this customer and date` };

  const stage = STAGE_COLUMNS[file].map(c => {
    if (c === 'inv_label') return row.inv.value;
    if (c === 'inv_no') return row.inv.no ?? null;
    if (c === 'inv_prefix') return row.inv.prefix;
    return val(c);
  });
  return { stage, key, problems };
}

// RFC 4180 records of a stream of text chunks, as parseCsv does for a whole text. push(chunk) returns the records it completed.
export function csvStream() {
  let cells = []; let cell = ''; let quoted = false; let line = 1; let start = 1; let touched = false; let carry = '';
  const out = [];
  const endCell = () => { cells.push(cell); cell = ''; };
  const endRecord = () => { endCell(); out.push({ line: start, cells }); cells = []; touched = false; };
  function run(text, final) {
    // A quote or a CR at the end of a chunk decides with the next character: keep it for the next chunk.
    let end = text.length;
    if (!final && end > 0 && (text[end - 1] === '"' || text[end - 1] === '\r')) { carry = text[end - 1]; end--; } else carry = '';
    for (let i = 0; i < end; i++) {
      const ch = text[i];
      if (quoted) {
        if (ch === '"') {
          if (text[i + 1] === '"') { cell += '"'; i++; } else quoted = false;
        } else {
          if (ch === '\n' || (ch === '\r' && text[i + 1] !== '\n')) line++;
          cell += ch;
        }
        continue;
      }
      if (ch === '"' && cell === '') { quoted = true; touched = true; continue; }
      if (ch === ',') { endCell(); touched = true; continue; }
      if (ch === '\r' || ch === '\n') {
        if (ch === '\r' && text[i + 1] === '\n') i++;
        if (touched || cell !== '' || cells.length) endRecord();
        line++;
        start = line;
        continue;
      }
      cell += ch;
      touched = true;
    }
  }
  return {
    push(chunk) { out.length = 0; run(carry + chunk, false); return out.splice(0); },
    end() {
      out.length = 0;
      run(carry, true);
      if (quoted) throw new Error(`file line ${start}: a quoted cell is never closed`);
      if (touched || cell !== '' || cells.length) endRecord();
      return out.splice(0);
    },
  };
}

// Calls onRecord(record) for every record of a UTF-8 CSV file, streamed; returns { sha256, bytes }. Throws ENCODING_MESSAGE on bad UTF-8.
export async function eachCsvRecord(path, onRecord) {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const hash = createHash('sha256');
  const parser = csvStream();
  let first = true;
  let bytes = 0;
  for await (const buf of createReadStream(path, { highWaterMark: 1024 * 1024 })) {
    hash.update(buf);
    bytes += buf.length;
    let text;
    try { text = decoder.decode(buf, { stream: true }); } catch { throw new Error(ENCODING_MESSAGE); }
    if (first) { if (text.charCodeAt(0) === 0xfeff) text = text.slice(1); first = false; }
    for (const rec of parser.push(text)) await onRecord(rec);
  }
  let rest;
  try { rest = decoder.decode(); } catch { throw new Error(ENCODING_MESSAGE); }
  for (const rec of parser.push(rest)) await onRecord(rec);
  for (const rec of parser.end()) await onRecord(rec);
  return { sha256: hash.digest('hex'), bytes };
}

function headerIndex(file, cells, line, problems) {
  const layout = HISTORY_LAYOUT[file];
  const name = `${file}.csv`;
  const index = new Map();
  const header = cells.map(c => clean(c));
  header.forEach((h, i) => {
    const match = layout.find(col => col.label.toLowerCase() === h.toLowerCase());
    if (!match) { problems.push({ kind: 'error', file: name, line, column: h || `column ${i + 1}`, reason: `unknown column "${h}"; the columns are: ${layout.map(c => c.label).join(', ')}` }); return; }
    if (index.has(match.col)) { problems.push({ kind: 'error', file: name, line, column: match.label, reason: 'this column appears twice' }); return; }
    index.set(match.col, i);
  });
  for (const col of layout) if (col.required && !index.has(col.col)) problems.push({ kind: 'error', file: name, line, column: col.label, reason: 'this required column is missing' });
  return { header, index };
}

// Pass 1: checks one history file. Returns { read, problems, count, sha256 }: the first PROBLEMS_SHOWN format errors and how many there are.
export async function checkHistoryFile(file, path) {
  const name = `${file}.csv`;
  const problems = [];
  let count = 0;
  const keep = list => { for (const p of list) { count++; if (problems.length < PROBLEMS_SHOWN) problems.push(p); } };
  let st;
  try { st = statSync(path); } catch (e) { return { read: 0, count: 1, problems: [{ kind: 'error', file: name, line: 1, column: null, reason: e.code === 'ENOENT' ? `${path} was not found` : e.message }] }; }
  if (!st.isFile() || st.size > HISTORY_MAX_BYTES) return { read: 0, count: 1, problems: [{ kind: 'error', file: name, line: 1, column: null, reason: `${path} is not a regular file under 512 MB; split it` }] };
  let head = null;
  let read = 0;
  const seen = new Map();
  let result;
  try {
    result = await eachCsvRecord(path, rec => {
      if (head === null) { const hp = []; head = headerIndex(file, rec.cells, rec.line, hp); head.bad = hp.length > 0; keep(hp); return; }
      if (!rec.cells.some(c => clean(c) !== '')) return;
      read++;
      if (head.bad) return;   // the header's errors come first; the rows are only counted
      if (read > HISTORY_MAX_ROWS) { if (read === HISTORY_MAX_ROWS + 1) keep([{ kind: 'error', file: name, line: rec.line, column: null, reason: `more than ${HISTORY_MAX_ROWS} rows; split the file` }]); return; }
      const r = checkHistoryRecord(file, head.index, head.header, rec);
      keep(r.problems);
      if (!r.problems.length && r.key) {
        const before = seen.get(r.key.key);
        if (before !== undefined) keep([{ kind: 'error', file: name, line: rec.line, column: r.key.column, reason: `${r.key.what} is already on line ${before} of this file` }]);
        else seen.set(r.key.key, rec.line);
      }
    });
  } catch (e) {
    const line = Number(/line (\d+)/.exec(e.message)?.[1] ?? 1);
    keep([{ kind: 'error', file: name, line, column: null, reason: e.message.replace(/^file line \d+: /, '') }]);
    return { read, problems, count };
  }
  if (head === null) keep([{ kind: 'error', file: name, line: 1, column: null, reason: 'the file is empty; it needs a header row' }]);
  return { read, problems, count, sha256: result.sha256 };
}

// COPY text format: \N for null; backslash, tab, newline and CR escaped.
const tsvCell = v => (v === null || v === undefined ? '\\N' : String(v).replace(/\\/g, '\\\\').replace(/\t/g, '\\t').replace(/\n/g, '\\n').replace(/\r/g, '\\r'));

// Pass 2: writes one checked file into its staging table through `write` (COPY ... FROM STDIN, the rows, \.).
export async function copyHistoryFile(file, path, write) {
  await write(`COPY ${stageTable(file)} (line, ${STAGE_COLUMNS[file].join(', ')}) FROM STDIN;\n`);
  let head = null;
  let batch = [];
  await eachCsvRecord(path, async rec => {
    if (head === null) { head = headerIndex(file, rec.cells, rec.line, []); return; }
    if (!rec.cells.some(c => clean(c) !== '')) return;
    const r = checkHistoryRecord(file, head.index, head.header, rec);
    if (r.problems.length) throw new Error(`${file}.csv line ${rec.line} changed between the check and the load; run the import again`);
    batch.push([rec.line, ...r.stage].map(tsvCell).join('\t'));
    if (batch.length >= 2000) { await write(batch.join('\n') + '\n'); batch = []; }
  });
  if (batch.length) await write(batch.join('\n') + '\n');
  await write('\\.\n');
}

// ---- The backup rule (--apply) --------------------------------------------------------------------------------------------------

export const indiaDay = ms => new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(ms));
export const BACKUP_ADVICE = 'Make a backup and verify it first: bash scripts/backup.sh, then bash scripts/verify-restore.sh <folder>, then node scripts/watch.mjs record-verified <name>';

// null when the newest backup on config/backups-verified.list was made today (India; its name carries the UTC time it was made) and
// verified today, and its folder exists; else the reason.
export function backupProblem(state, now = Date.now()) {
  if (typeof state !== 'string' || !state.startsWith('/')) return 'WAREHOUSE_STATE_DIR is not set to the absolute state path';
  const newest = readVerifiedList(state).at(-1);
  if (!newest) return 'no backup is on record as verified';
  const m = /^warehouse-(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(newest.name);
  const made = m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : NaN;
  const today = indiaDay(now);
  if (!Number.isFinite(made) || indiaDay(made) !== today) return `the newest verified backup, ${newest.name}, was not made today`;
  if (!newest.epoch || indiaDay(newest.epoch * 1000) !== today) return `the newest verified backup, ${newest.name}, was not verified today`;
  if (!lstatSync(join(state, 'backups', newest.name), { throwIfNoEntry: false })?.isDirectory()) return `the newest verified backup, ${newest.name}, is not in ${join(state, 'backups')}`;
  return null;
}

// ---- The database --------------------------------------------------------------------------------------------------------------

export function payloadFor(checked) {
  const labels = {};
  for (const file of FILES) labels[file] = Object.fromEntries(LAYOUT[file].map(c => [c.field, c.label]));
  const body = { labels };
  for (const file of FILES) if (checked[file]) body[file] = checked[file].rows.map(r => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v === '' ? null : v])));
  return body;
}

const dollarQuote = text => {
  let tag;
  do { tag = `imp${randomBytes(8).toString('hex')}`; } while (text.includes(`$${tag}$`));
  return `$${tag}$${text}$${tag}$`;
};
const SERVICE_ROLE = ['SET LOCAL ROLE service_role;', `SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true) \\gset`];

// The statement fed to psql: one transaction, as the service role. The JSON travels inside a dollar quote whose tag is not in it.
export function buildSql(payload, apply) {
  return [
    'BEGIN;',
    ...SERVICE_ROLE,
    `SELECT public.import_batch(${dollarQuote(JSON.stringify(payload))}::jsonb, ${apply ? 'true' : 'false'});`,
    'COMMIT;',
    '',
  ].join('\n');
}

// The SQL around the staged rows of a past-years run. The COPYs run before the role switch (the staging tables are supabase_admin's).
const STAGE_TABLES = () => HISTORY_FILES.map(stageTable).join(', ');
export const historySqlStart = () => `BEGIN;\nTRUNCATE ${STAGE_TABLES()};\n`;
export function historySqlEnd(payload, apply) {
  return [
    ...SERVICE_ROLE,
    `SELECT public.import_history(${dollarQuote(JSON.stringify(payload))}::jsonb, ${apply ? 'true' : 'false'});`,
    'RESET ROLE;',
    `TRUNCATE ${STAGE_TABLES()};`,
    'COMMIT;',
    // Fresh statistics for the lists after an apply (design §1).
    ...(apply ? ['ANALYZE public.goodsreceived, public.goodsreceived_trl, public.dispatch, public.dispatch_trl, public.invoice, public.invoice_trl, public.payments;'] : []),
    '',
  ].join('\n');
}

export const psqlCommand = root => ['bash', [join(root, 'scripts', 'compose.sh'), 'exec', '-T', 'db', 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres']];

const databaseReason = stderr => (stderr || '').split('\n').map(s => s.replace(/^(psql:[^:]*:\d+: )?ERROR:\s+/, '').trim()).find(s => s && !s.startsWith('LINE') && !s.startsWith('CONTEXT')) || 'the database did not answer';
function lastJson(stdout) {
  const last = stdout.split('\n').map(s => s.trim()).filter(Boolean).filter(s => s.startsWith('{')).at(-1);
  try { return JSON.parse(last); } catch { throw new Error('The database answered with something unexpected, and nothing was saved. Check the database log.'); }
}

function runDatabase(sql, command) {
  const [cmd, args] = command;
  const run = spawnSync(cmd, args, { input: sql, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (run.status !== 0) throw new Error(`The database refused the import and nothing was saved: ${databaseReason(run.stderr)}`);
  return lastJson(run.stdout);
}

// One psql session: start, then every file's COPY, then the call; resolves with the answer.
async function runHistory(command, paths, payload, apply) {
  const [cmd, args] = command;
  const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = ''; let stderr = '';
  child.stdout.setEncoding('utf8').on('data', d => { stdout += d; });
  child.stderr.setEncoding('utf8').on('data', d => { stderr = (stderr + d).slice(-65536); });
  const closed = new Promise(resolve => child.on('close', code => resolve(code)));
  let broken = null;
  child.stdin.on('error', e => { broken = e; });
  const write = text => new Promise((resolve, reject) => {
    if (broken) { reject(broken); return; }
    if (child.stdin.write(text)) resolve(); else child.stdin.once('drain', resolve);
  });
  try {
    await write(historySqlStart());
    for (const file of HISTORY_FILES) if (paths[file]) await copyHistoryFile(file, paths[file], write);
    await write(historySqlEnd(payload, apply));
  } catch (e) {
    child.stdin.destroy();
    await closed;
    if (stderr) throw new Error(`The database refused the import and nothing was saved: ${databaseReason(stderr)}`);
    throw e;
  }
  child.stdin.end();
  const code = await closed;
  if (code !== 0) throw new Error(`The database refused the import and nothing was saved: ${databaseReason(stderr)}`);
  return lastJson(stdout);
}

// ---- Output --------------------------------------------------------------------------------------------------------------------

function sortProblems(list) {
  return [...list].sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || (a.kind === b.kind ? 0 : a.kind === 'error' ? -1 : 1));
}
const problemLine = p => `${p.file} line ${p.line}${p.column ? `, column ${p.column}` : ''}: ${p.reason}${p.kind === 'conflict' ? ' (conflict)' : p.kind === 'note' ? ' (note)' : ''}`;
const money = n => Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fyLabel = fy => `${fy}-${String((Number(fy) + 1) % 100).padStart(2, '0')}`;

// The problems of one file, at most PROBLEMS_SHOWN, then "and N more".
function printProblems(out, list, total) {
  for (const p of sortProblems(list).slice(0, PROBLEMS_SHOWN)) out(problemLine(p));
  const shown = Math.min(list.length, PROBLEMS_SHOWN);
  if (total > shown) out(`  and ${total - shown} more`);
}

export function printTotals(out, t) {
  out('Sign-off totals (whole facility, after this import):');
  // WH-180 (spec answer 4): imported dispatches that an imported invoice naming no dispatch takes as billed, ahead of the never-billed list.
  const taken = t.taken_as_billed ?? [];
  out('  Dispatches taken as billed by an imported invoice that names no dispatch, per customer:');
  if (!taken.length) out('    none');
  for (const r of taken) {
    out(`    ${r.customer}:`);
    for (const d of r.dispatches) out(`      dispatch ${d.disp_no} of ${String(d.disp_date).split('-').reverse().join('/')} taken as billed by invoice ${d.invoice}`);
  }
  out('  Dispatches on no invoice, per customer:');
  if (!t.uninvoiced_dispatches.length) out('    none');
  for (const r of t.uninvoiced_dispatches) out(`    ${r.customer}: ${r.dispatches} dispatch(es), ${r.bags} bag(s)`);
  out('  Stock in store, per item:');
  if (!t.stock.length) out('    none');
  for (const r of t.stock) out(`    ${r.item}${r.packaging ? ` (${r.packaging})` : ''}: ${r.bags}`);
  out('  Owed, per customer (due on invoices; payments on account; due less on account):');
  let due = 0; let onAccount = 0;
  for (const r of t.owed) {
    due += Number(r.due); onAccount += Number(r.on_account);
    out(`    ${r.customer}: due ${money(r.due)}; on account ${money(r.on_account)}; ${money(Number(r.due) - Number(r.on_account))}`);
  }
  out(`    All customers: due ${money(due)}; on account ${money(onAccount)}; ${money(due - onAccount)}`);
  out('  Invoices per financial year (count and total):');
  if (!t.invoices_by_year.length) out('    none');
  for (const r of t.invoices_by_year) out(`    ${fyLabel(r.fin_year)}: imported ${r.imported_count} (${money(r.imported_total)}), made in the app ${r.app_count} (${money(r.app_total)})`);
  const n = t.next_invoice;
  out(n.number ? `  Next invoice number for ${fyLabel(n.fin_year)}: ${n.prefix ?? ''}${n.number}` : `  Next invoice number for ${fyLabel(n.fin_year)}: ${n.message ?? 'typed by hand'}`);
}

function parseArgs(argv) {
  const opts = { paths: {}, folder: null, apply: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') opts.apply = true;
    else if (a === '--folder' || a === '--customers' || a === '--items' || a === '--rates') {
      const value = argv[++i];
      const key = a.slice(2);
      if (!value || value.startsWith('--') || (key === 'folder' ? opts.folder : opts.paths[key])) return null;
      if (key === 'folder') opts.folder = value; else opts.paths[key] = value;
    } else return null;
  }
  return opts;
}

export async function main(argv, env = process.env, out = line => console.log(line), deps = {}) {
  const usage = 'Usage: bash scripts/import.sh [--folder <dir>] [--customers customers.csv] [--items items.csv] [--rates rates.csv] [--apply]  (templates: scripts/import-templates/)';
  const opts = parseArgs(argv);
  if (!opts) { console.error(usage); return 2; }
  const paths = { ...opts.paths };
  if (opts.folder) {
    let isDir = false;
    try { isDir = statSync(opts.folder).isDirectory(); } catch { /* not there */ }
    if (!isDir) { console.error(`${opts.folder} is not a folder.`); return 2; }
    for (const file of [...FILES, ...HISTORY_FILES]) {
      const p = join(opts.folder, `${file}.csv`);
      if (!statSync(p, { throwIfNoEntry: false })) continue;
      if (paths[file]) { console.error(`${file}.csv is both in ${opts.folder} and given with --${file}; give it once.`); return 2; }
      paths[file] = p;
    }
  }
  if (Object.keys(paths).length === 0) { console.error(opts.folder ? `No import files in ${opts.folder} (the names are in scripts/import-templates/).` : usage); return 2; }
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');
  const command = deps.psqlCommand ?? psqlCommand(root);
  const history = HISTORY_FILES.some(f => paths[f]);

  // The backup rule comes before the database is asked (WH-180 step 16; it covers the masters-only apply too).
  if (opts.apply) {
    const why = backupProblem(env.WAREHOUSE_STATE_DIR, deps.now ?? Date.now());
    if (why) { out(`The import was not applied: ${why}. ${BACKUP_ADVICE}`); return 1; }
  }

  // Customers, items and rates: read whole, as WH-142.
  const checked = {};
  const problems = [];
  for (const file of FILES) {
    if (!paths[file]) continue;
    const label = `${file}.csv`;
    let text;
    try {
      const st = statSync(paths[file]);
      if (!st.isFile() || st.size > MAX_BYTES) throw new Error(`${paths[file]} is not a regular file under 5 MB`);
      text = decodeUtf8(readFileSync(paths[file]));
    } catch (e) {
      const reason = e.code === 'ENOENT' ? `${paths[file]} was not found` : e.message;
      checked[file] = { rows: [], read: 0, problems: [{ kind: 'error', file: label, line: 1, column: null, reason }] };
      problems.push(...checked[file].problems);
      continue;
    }
    checked[file] = checkFile(file, text);
    problems.push(...checked[file].problems);
  }
  // Past years: pass 1, streamed.
  const historyChecked = {};
  let historyErrors = 0;
  for (const file of HISTORY_FILES) {
    if (!paths[file]) continue;
    historyChecked[file] = await checkHistoryFile(file, paths[file]);
    historyErrors += historyChecked[file].count;
  }

  out(history ? (opts.apply ? 'Import of past years (apply)' : 'Import of past years (dry run: nothing is saved)') : (opts.apply ? 'Import (apply)' : 'Import (dry run: nothing is saved)'));

  if (problems.length > 0 || historyErrors > 0) {
    for (const file of [...FILES, ...HISTORY_FILES]) {
      if (!paths[file]) continue;
      const label = `${file}.csv`;
      const mine = historyChecked[file]?.problems ?? problems.filter(p => p.file === label);
      const total = historyChecked[file]?.count ?? mine.length;
      const read = checked[file]?.read ?? historyChecked[file]?.read ?? 0;
      out(`${label}: read ${read}, errors ${total} (the database checks run once the files have no format errors)`);
      printProblems(out, mine, total);
    }
    out(opts.apply ? 'Nothing was saved: fix the errors above and run it again.' : 'There are errors: fix them before --apply.');
    return 1;
  }

  let report;
  const payload = payloadFor(checked);
  try {
    if (!history) report = (deps.runDatabase ?? runDatabase)(buildSql(payload, opts.apply), command);
    else {
      payload.history_files = HISTORY_FILES.filter(f => paths[f]).map(f => ({ name: `${f}.csv`, sha256: historyChecked[f].sha256, rows: historyChecked[f].read }));
      report = await runHistory(command, paths, payload, opts.apply);
    }
  } catch (e) { console.error(e.message); return 1; }

  if (!history) {
    const all = report.problems.map(p => ({ ...p, file: `${p.file}.csv` }));
    for (const file of FILES) {
      if (!checked[file]) continue;
      const s = report.files[file];
      out(`${file}.csv: read ${s.read}, ${opts.apply && report.applied ? 'added' : 'would add'} ${s.add}, skip ${s.skip}, conflicts ${s.conflicts}, errors ${s.errors}`);
    }
    for (const p of sortProblems(all)) out(problemLine(p));
    const errors = all.filter(p => p.kind === 'error').length;
    if (errors > 0) { out(opts.apply ? 'Nothing was saved: fix the errors above and run it again.' : 'There are errors: fix them before --apply.'); return 1; }
    if (opts.apply) {
      const s = report.files;
      out(`Saved: customers ${s.customers?.add ?? 0}, items ${s.items?.add ?? 0}, rates ${s.rates?.add ?? 0} (rows). Each added record is in the audit log as "Import".`);
      if (all.length) out(`${all.length} conflict(s) were skipped and listed above; nothing existing was changed.`);
    } else {
      out(all.length ? `No errors. ${all.length} conflict(s) would be skipped; nothing existing is ever changed. Run again with --apply to save.` : 'No errors. Run again with --apply to save.');
    }
    return 0;
  }

  // Past years: the masters first (as WH-142 prints them), then each history file, then the sign-off totals.
  const added = opts.apply && report.applied;
  if (report.masters) {
    const all = report.masters.problems.map(p => ({ ...p, file: `${p.file}.csv` }));
    for (const file of FILES) {
      if (!checked[file]) continue;
      const s = report.masters.files[file];
      out(`${file}.csv: read ${s.read}, ${added ? 'added' : 'would add'} ${s.add}, skip ${s.skip}, conflicts ${s.conflicts}, errors ${s.errors}`);
      printProblems(out, all.filter(p => p.file === `${file}.csv`), all.filter(p => p.file === `${file}.csv`).length);
    }
  }
  const dbProblems = report.problems.map(p => ({ ...p, file: p.file === 'database' ? 'database' : `${p.file}.csv` }));
  for (const file of HISTORY_FILES) {
    if (!paths[file]) continue;
    const s = report.files[file];
    out(`${file}.csv: read ${s.read}, ${added ? 'added' : 'would add'} ${s.add}, already there ${s.skip}, errors ${s.errors}, notes ${s.notes}`);
    printProblems(out, dbProblems.filter(p => p.file === `${file}.csv`), report.problem_counts[file] ?? 0);
  }
  for (const p of dbProblems.filter(p => p.file === 'database')) out(`The database: ${p.reason}`);
  if (!report.success) {
    out(opts.apply ? 'Nothing was saved: fix the errors above and run it again.' : 'There are errors: fix them before --apply.');
    return 1;
  }
  printTotals(out, report.totals);
  const anyNew = HISTORY_FILES.some(f => paths[f] && report.files[f].add > 0) || FILES.some(f => checked[f] && report.masters?.files[f]?.add > 0);
  if (added) out(anyNew ? 'Saved, all in one go. Each imported document is marked Imported and can\'t be changed in the app.' : 'Nothing new was saved: every document was already there.');
  else out('No errors. Compare the sign-off totals with the old system, then run again with --apply to save.');
  return 0;
}

if (isMain(import.meta.url)) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, e => { console.error(basename(process.argv[1]) + ': ' + e.message); process.exitCode = 1; });
}
