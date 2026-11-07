// CSV import of customers, items and rates for a new facility (WH-142, part 1). Run it through scripts/import.sh, which takes the operator lock.
//
//   WAREHOUSE_STATE_DIR=/abs/state bash scripts/import.sh [--customers customers.csv] [--items items.csv] [--rates rates.csv] [--apply]
//
// Without --apply it is a dry run: the files are read and checked, the database is asked what an import would do (it really runs the
// import and rolls it back), and nothing is saved. With --apply the same run is kept, only when there is no error, all or nothing.
// Exit status: 0 = no error, 1 = at least one error (or the database could not be reached), 2 = wrong usage.
// The file format, the checks and the answer are in docs/OPERATOR_INSTALL.md, "Import customers, items and rates".
import { readFileSync, statSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

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
      for (const [field, label, limit] of [['rent', 'Rent (₹)', 999999], ['labour', 'Labour (₹)', 999999], ['tax', 'Tax (%)', 100]]) {
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

// ---- The database --------------------------------------------------------------------------------------------------------------

export function payloadFor(checked) {
  const labels = {};
  for (const file of FILES) labels[file] = Object.fromEntries(LAYOUT[file].map(c => [c.field, c.label]));
  const body = { labels };
  for (const file of FILES) if (checked[file]) body[file] = checked[file].rows.map(r => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v === '' ? null : v])));
  return body;
}

// The statement fed to psql: one transaction, as the service role. The JSON travels inside a dollar quote whose tag is not in it.
export function buildSql(payload, apply) {
  const json = JSON.stringify(payload);
  let tag;
  do { tag = `imp${randomBytes(8).toString('hex')}`; } while (json.includes(`$${tag}$`));
  return [
    'BEGIN;',
    'SET LOCAL ROLE service_role;',
    `SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true) \\gset`,
    `SELECT public.import_batch($${tag}$${json}$${tag}$::jsonb, ${apply ? 'true' : 'false'});`,
    'COMMIT;',
    '',
  ].join('\n');
}

function runDatabase(sql, root) {
  const run = spawnSync('bash', [join(root, 'scripts', 'compose.sh'), 'exec', '-T', 'db', 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres'],
    { input: sql, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (run.status !== 0) {
    const reason = (run.stderr || '').split('\n').map(s => s.replace(/^ERROR:\s+/, '').trim()).find(s => s && !s.startsWith('LINE') && !s.startsWith('CONTEXT')) || 'the database did not answer';
    throw new Error(`The database refused the import and nothing was saved: ${reason}`);
  }
  const lines = run.stdout.split('\n').map(s => s.trim()).filter(Boolean);
  const last = lines.at(-1);
  try { return JSON.parse(last); } catch { throw new Error('The database answered with something unexpected, and nothing was saved. Check the database log.'); }
}

// ---- Output --------------------------------------------------------------------------------------------------------------------

function sortProblems(list) {
  return [...list].sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line || (a.kind === b.kind ? 0 : a.kind === 'error' ? -1 : 1));
}
const problemLine = p => `${p.file} line ${p.line}${p.column ? `, column ${p.column}` : ''}: ${p.reason}${p.kind === 'conflict' ? ' (conflict)' : ''}`;

export function main(argv, env = process.env, out = line => console.log(line)) {
  const usage = 'Usage: bash scripts/import.sh [--customers customers.csv] [--items items.csv] [--rates rates.csv] [--apply]  (templates: scripts/import-templates/)';
  const paths = {};
  let apply = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--apply') apply = true;
    else if (a === '--customers' || a === '--items' || a === '--rates') {
      const value = argv[++i];
      if (!value || value.startsWith('--') || paths[a.slice(2)]) { console.error(usage); return 2; }
      paths[a.slice(2)] = value;
    } else { console.error(usage); return 2; }
  }
  if (Object.keys(paths).length === 0) { console.error(usage); return 2; }
  const root = join(dirname(fileURLToPath(import.meta.url)), '..');

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

  let report = null;
  const formatErrors = problems.length;
  if (formatErrors === 0) {
    try { report = runDatabase(buildSql(payloadFor(checked), apply), root); } catch (e) { console.error(e.message); return 1; }
    problems.push(...report.problems.map(p => ({ ...p, file: `${p.file}.csv` })));
  }

  out(apply ? 'Import (apply)' : 'Import (dry run: nothing is saved)');
  for (const file of FILES) {
    if (!checked[file]) continue;
    const label = `${file}.csv`;
    const fileErrors = problems.filter(p => p.file === label && p.kind === 'error').length;
    if (report) {
      const s = report.files[file];
      out(`${label}: read ${s.read}, ${apply && report.applied ? 'added' : 'would add'} ${s.add}, skip ${s.skip}, conflicts ${s.conflicts}, errors ${s.errors}`);
    } else {
      out(`${label}: read ${checked[file].read}, errors ${fileErrors} (the database checks run once the files have no format errors)`);
    }
  }
  const errors = problems.filter(p => p.kind === 'error').length;
  for (const p of sortProblems(problems)) out(problemLine(p));
  if (errors > 0) {
    out(apply ? 'Nothing was saved: fix the errors above and run it again.' : 'There are errors: fix them before --apply.');
    return 1;
  }
  const conflicts = problems.length;
  if (apply) {
    const s = report.files;
    out(`Saved: customers ${s.customers?.add ?? 0}, items ${s.items?.add ?? 0}, rates ${s.rates?.add ?? 0} (rows). Each added record is in the audit log as "import".`);
    if (conflicts) out(`${conflicts} conflict(s) were skipped and listed above; nothing existing was changed.`);
  } else {
    out(conflicts ? `No errors. ${conflicts} conflict(s) would be skipped; nothing existing is ever changed. Run again with --apply to save.` : 'No errors. Run again with --apply to save.');
  }
  return 0;
}

if (isMain(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); } catch (e) { console.error(basename(process.argv[1]) + ': ' + e.message); process.exitCode = 1; }
}
