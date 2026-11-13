// WH-180: scripts/import.mjs, the import of past years (--folder). Exit codes, the backup rule, format errors found before the database is asked,
// the "and N more" cap, a repeated number inside a file, and the report printed from the database's answer (a stand-in psql: no Docker).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, copyFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { main, splitInvoiceNumber, backupProblem, indiaDay, HISTORY_FILES, historySqlEnd } from '../scripts/import.mjs';

const TEMPLATES = new URL('../scripts/import-templates/', import.meta.url).pathname;

function scratch() {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-import-'));
  const folder = join(dir, 'files'); mkdirSync(folder);
  const state = join(dir, 'state'); mkdirSync(join(state, 'config'), { recursive: true }); mkdirSync(join(state, 'backups'));
  return { dir, folder, state, clean: () => rmSync(dir, { recursive: true, force: true }) };
}
const copyTemplates = folder => { for (const f of readdirSync(TEMPLATES)) copyFileSync(join(TEMPLATES, f), join(folder, f)); };
const run = async (argv, env = {}, deps = {}) => {
  const lines = [];
  const realError = console.error; const errors = [];
  console.error = m => errors.push(String(m));
  try { const code = await main(argv, env, l => lines.push(l), deps); return { code, lines, errors }; } finally { console.error = realError; }
};
// A stand-in psql that reads the whole session and answers with a fixed report on its last line.
const standIn = report => ['node', ['-e', `let n=0;process.stdin.on('data',d=>n+=d.length).on('end',()=>console.log(${JSON.stringify(JSON.stringify(report))}))`]];
const totals = { uninvoiced_dispatches: [], stock: [], owed: [], invoices_by_year: [], next_invoice: { fin_year: 2023, prefix: 'GC/', number: 311 } };
const report = (extra = {}) => ({ success: true, applied: false, masters: null, problems: [], problem_counts: {}, totals,
  files: Object.fromEntries(HISTORY_FILES.map(f => [f, { read: 1, add: 1, skip: 0, errors: 0, notes: 0 }])), ...extra });

// A backup made and verified at `now` (India day), in a state directory.
function backupAt(state, now) {
  const d = new Date(now);
  const p = n => String(n).padStart(2, '0');
  const name = `warehouse-${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}T${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`;
  mkdirSync(join(state, 'backups', name));
  writeFileSync(join(state, 'config/backups-verified.list'), `${name} ${Math.floor(now / 1000)}\n`);
  return name;
}

test('usage errors exit 2: unknown option, no files, a folder that is not there, a file given twice', async () => {
  const s = scratch();
  try {
    assert.equal((await run(['--nonsense'])).code, 2);
    assert.equal((await run([])).code, 2);
    assert.equal((await run(['--folder', join(s.dir, 'missing')])).code, 2);
    assert.equal((await run(['--folder', s.folder])).code, 2, 'an empty folder holds no import files');
    copyTemplates(s.folder);
    writeFileSync(join(s.folder, 'customers.csv'), 'Name\nA\n');
    assert.equal((await run(['--folder', s.folder, '--customers', join(s.folder, 'customers.csv')])).code, 2, 'a file given twice');
  } finally { s.clean(); }
});

test('--apply without a backup made and verified today exits 1 before the files or the database are looked at', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    const never = ['node', ['-e', 'process.exit(9)']];
    const now = Date.UTC(2026, 10, 13, 6, 0, 0);
    let r = await run(['--folder', s.folder, '--apply'], { WAREHOUSE_STATE_DIR: s.state }, { psqlCommand: never, now });
    assert.equal(r.code, 1); assert.match(r.lines.join('\n'), /no backup is on record as verified/); assert.match(r.lines.join('\n'), /scripts\/backup\.sh/);
    // yesterday's backup (India day)
    backupAt(s.state, now - 36 * 3600 * 1000);
    r = await run(['--folder', s.folder, '--apply'], { WAREHOUSE_STATE_DIR: s.state }, { psqlCommand: never, now });
    assert.equal(r.code, 1); assert.match(r.lines.join('\n'), /was not made today/);
    // without the state directory at all
    r = await run(['--folder', s.folder, '--apply'], {}, { psqlCommand: never, now });
    assert.equal(r.code, 1); assert.match(r.lines.join('\n'), /WAREHOUSE_STATE_DIR/);
    // a dry run needs no backup
    r = await run(['--folder', s.folder], {}, { psqlCommand: standIn(report()) });
    assert.equal(r.code, 0, r.lines.join('\n'));
  } finally { s.clean(); }
});

test('backupProblem: today and verified today passes; made today but verified yesterday, or the folder gone, does not', () => {
  const s = scratch();
  try {
    const now = Date.UTC(2026, 10, 13, 6, 0, 0);
    const name = backupAt(s.state, now);
    assert.equal(backupProblem(s.state, now), null);
    writeFileSync(join(s.state, 'config/backups-verified.list'), `${name} ${Math.floor((now - 36 * 3600 * 1000) / 1000)}\n`);
    assert.match(backupProblem(s.state, now), /was not verified today/);
    writeFileSync(join(s.state, 'config/backups-verified.list'), `${name} ${Math.floor(now / 1000)}\n`);
    rmSync(join(s.state, 'backups', name), { recursive: true });
    assert.match(backupProblem(s.state, now), /is not in/);
    assert.match(backupProblem('relative/path', now), /absolute/);
    // the India day: 19:00 UTC on the 12th is already the 13th in India
    assert.equal(indiaDay(Date.UTC(2026, 10, 12, 19, 0, 0)), '2026-11-13');
  } finally { s.clean(); }
});

test('--apply with a backup of today reaches the database and prints the sign-off totals and the Imported sentence', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    const now = Date.now();
    backupAt(s.state, now);
    const r = await run(['--folder', s.folder, '--apply'], { WAREHOUSE_STATE_DIR: s.state }, { psqlCommand: standIn(report({ applied: true })), now });
    assert.equal(r.code, 0, r.lines.join('\n') + r.errors.join('\n'));
    const text = r.lines.join('\n');
    assert.match(text, /Import of past years \(apply\)/);
    assert.match(text, /Sign-off totals/);
    assert.match(text, /Next invoice number for 2023-24: GC\/311/);
    assert.match(text, /marked Imported and can't be changed/);
  } finally { s.clean(); }
});

test('format errors are found without the database: exit 1, the file, line and column named, nothing sent', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    writeFileSync(join(s.folder, 'grns.csv'), 'GRN number,GRN date,Customer name,Pricing,Vehicle,Sender,Note\nG-1,31/02/2023,Example Traders,Monthly,,,\nG 2,01/03/2023,Example Traders,Sometimes,,,\n');
    const r = await run(['--folder', s.folder], {}, { psqlCommand: ['node', ['-e', 'process.exit(9)']] });
    assert.equal(r.code, 1);
    const text = r.lines.join('\n');
    assert.match(text, /grns\.csv line 2, column GRN date: .*not a date/);
    assert.match(text, /grns\.csv line 3, column GRN number: /);
    assert.match(text, /grns\.csv line 3, column Pricing: .*Monthly or One-time/);
    assert.match(text, /There are errors: fix them before --apply\./);
    // with --apply the sentence says nothing was saved
    backupAt(s.state, Date.now());
    const a = await run(['--folder', s.folder, '--apply'], { WAREHOUSE_STATE_DIR: s.state }, { psqlCommand: ['node', ['-e', 'process.exit(9)']] });
    assert.equal(a.code, 1); assert.match(a.lines.join('\n'), /Nothing was saved/);
  } finally { s.clean(); }
});

test('a GRN number repeated in one file is an error naming the first line; a wrong header is named', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    writeFileSync(join(s.folder, 'grns.csv'), 'GRN number,GRN date,Customer name\nG-1,01/03/2023,A\nG-1,01/03/2023,A\n');
    let r = await run(['--folder', s.folder]);
    assert.equal(r.code, 1);
    assert.match(r.lines.join('\n'), /grns\.csv line 3.*already on line 2/);
    writeFileSync(join(s.folder, 'grns.csv'), 'Nothing,Useful\nx,y\n');
    r = await run(['--folder', s.folder]);
    assert.equal(r.code, 1);
    assert.match(r.lines.join('\n'), /grns\.csv line 1/);
  } finally { s.clean(); }
});

test('a GRN number with "/" and the same number on another date are both fine in the files (the database decides repeats)', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    writeFileSync(join(s.folder, 'grns.csv'), 'GRN number,GRN date,Customer name\nGRN/22-23/0001,01/03/2023,A\nGRN/22-23/0001,02/04/2023,A\n');
    const r = await run(['--folder', s.folder], {}, { psqlCommand: standIn(report()) });
    assert.equal(r.code, 0, r.lines.join('\n'));
  } finally { s.clean(); }
});

test('more than 200 problems in a file: 200 are listed, then "and N more"', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    const rows = ['GRN number,GRN date,Customer name'];
    for (let i = 1; i <= 250; i++) rows.push(`G-${i},not-a-date,A`);
    writeFileSync(join(s.folder, 'grns.csv'), rows.join('\n') + '\n');
    const r = await run(['--folder', s.folder]);
    assert.equal(r.code, 1);
    assert.equal(r.lines.filter(l => /^grns\.csv line \d+, column GRN date/.test(l)).length, 200);
    assert.ok(r.lines.includes('  and 50 more'), r.lines.slice(0, 4).join('|'));
    assert.match(r.lines.join('\n'), /grns\.csv: read 250, errors 250/);
  } finally { s.clean(); }
});

test('a repeated receipt number is not an error in the files (old receipt numbers repeat; the database keys it by customer, number and date)', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    writeFileSync(join(s.folder, 'payments.csv'), 'Receipt number,Payment date,Customer name,Invoice number,Invoice date,Amount,Mode,Note\nR-1,30/06/2023,A,GC/125,20/06/2023,100.00,Cash,\nR-1,30/06/2024,A,GC/125,20/06/2023,50.00,Cash,\n');
    const r = await run(['--folder', s.folder], {}, { psqlCommand: standIn(report()) });
    assert.equal(r.code, 0, r.lines.join('\n'));
  } finally { s.clean(); }
});

test('the database refusing the call (psql fails) exits 1 and says nothing was saved', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    const failing = ['node', ['-e', 'process.stdin.resume();process.stdin.on("end",()=>{console.error("ERROR:  The import runs from the operator command only");process.exit(3)})']];
    const r = await run(['--folder', s.folder], {}, { psqlCommand: failing });
    assert.equal(r.code, 1);
    assert.match(r.errors.join('\n'), /nothing was saved: The import runs from the operator command only/);
  } finally { s.clean(); }
});

test('database errors in the report exit 1 and print the problem lines', async () => {
  const s = scratch();
  try {
    copyTemplates(s.folder);
    const bad = report({ success: false, totals: null,
      problems: [{ kind: 'error', file: 'dispatch-lines', line: 2, column: 'Quantity', reason: 'more than the GRN line received' }],
      problem_counts: { 'dispatch-lines': 1 } });
    bad.files['dispatch-lines'].errors = 1;
    const r = await run(['--folder', s.folder], {}, { psqlCommand: standIn(bad) });
    assert.equal(r.code, 1);
    assert.match(r.lines.join('\n'), /dispatch-lines\.csv line 2, column Quantity: more than the GRN line received/);
  } finally { s.clean(); }
});

test('splitInvoiceNumber: prefix and number from the old number', () => {
  assert.deepEqual(splitInvoiceNumber('GC/125'), { no: 125, prefix: 'GC/' });
  assert.deepEqual(splitInvoiceNumber('310'), { no: 310, prefix: '' });
  assert.deepEqual(splitInvoiceNumber('A-007'), { no: 7, prefix: 'A-00' });
  assert.ok(splitInvoiceNumber('GC/').why);
  assert.ok(splitInvoiceNumber('lowercase1').why);
  assert.ok(splitInvoiceNumber('1234567890').why);
});

test('the SQL around the call: staged rows first, the call as the service role, staging emptied before COMMIT', () => {
  const sql = historySqlEnd({ history_files: [] }, true);
  const at = s => sql.indexOf(s);
  assert.ok(at('SET LOCAL ROLE service_role') < at('import_history('));
  assert.ok(at('import_history(') < at('RESET ROLE'));
  assert.ok(at('TRUNCATE') < at('COMMIT'));
  assert.match(sql, /, true\);/);
  assert.match(historySqlEnd({}, false), /, false\);/);
});
