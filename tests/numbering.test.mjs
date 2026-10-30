// The numbering rule options of setup.sh --operator (--grn-numbering, --dispatch-numbering, --invoice-numbering): the checks of
// scripts/numbering.mjs that run before anything is changed, the line doctor prints, and how setup.sh and configure-operator.sql
// use them. The database side (what is stored, the history, the suggestions) is tests/document_numbering.sql.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { NUMBERING_PROBLEMS_SQL, NUMBERING_SQL, numberingLine, numberingProblems, parseSpec, specOf } from '../scripts/numbering.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const script = fileURLToPath(new URL('../scripts/numbering.mjs', import.meta.url));

test('a rule is read from its words, with the defaults left to the database', () => {
  assert.deepEqual(parseSpec('grn', 'letters'), { scheme: 'letters' });
  assert.deepEqual(parseSpec('grn', 'letters,first=X,digits=4,per-letter=1000'), { scheme: 'letters', first_letter: 'X', width: 4, per_letter: 1000 });
  assert.deepEqual(parseSpec('grn', 'year,prefix=GRN/,digits=5'), { scheme: 'year', prefix: 'GRN/', width: 5 });
  assert.deepEqual(parseSpec('dispatch', 'sequence,prefix=I,digits=4,start=1'), { scheme: 'sequence', prefix: 'I', width: 4, start: 1 });
  assert.deepEqual(parseSpec('dispatch', 'sequence,start=1001'), { scheme: 'sequence', start: 1001 });
  assert.deepEqual(parseSpec('grn', 'free'), { scheme: 'free' });
  assert.deepEqual(parseSpec('invoice', 'year'), { scheme: 'year' });
  assert.deepEqual(parseSpec('invoice', 'sequence,start=500'), { scheme: 'sequence', start: 500 });
  assert.deepEqual(parseSpec('grn', ' year , prefix=G/ '), { scheme: 'year', prefix: 'G/' }, 'spaces around the parts do not matter');
  // The check of a rule: on or off, for the schemes that have a format to check.
  assert.deepEqual(parseSpec('dispatch', 'sequence,prefix=I,check=off'), { scheme: 'sequence', prefix: 'I', check: false });
  assert.deepEqual(parseSpec('grn', 'letters,first=X,check=on'), { scheme: 'letters', first_letter: 'X', check: true });
  assert.deepEqual(parseSpec('grn', 'year,prefix=GRN/,check=off'), { scheme: 'year', prefix: 'GRN/', check: false });
  // The longest sequence rule (a 10-character prefix and 7 digits, 17 characters) fits the 20 of the column: nothing to check, nothing refused.
  assert.deepEqual(parseSpec('dispatch', 'sequence,prefix=ABCDEFGHIJ,digits=7'), { scheme: 'sequence', prefix: 'ABCDEFGHIJ', width: 7 });
});

test('a rule that is wrong is refused with what to change', () => {
  const refused = [
    ['grn', '', /Unknown scheme ""/],
    ['grn', 'words', /Unknown scheme "words"\. Use letters, year, sequence or free/],
    ['grn', 'letters,prefix=G', /"prefix=G" does not belong to a letters rule \(it takes first, digits, per-letter, check\)/],
    ['grn', 'year,first=A', /"first=A" does not belong to a year rule/],
    ['grn', 'free,digits=4', /"digits=4" does not belong to a free rule/],
    ['grn', 'free,check=off', /"check=off" does not belong to a free rule/],
    ['grn', 'letters,check=maybe', /check must be on \(a number outside the rule is refused\) or off \(it is saved\)/],
    ['grn', 'letters,check=', /check must be on/],
    ['grn', 'letters,check=off,check=on', /check is given twice/],
    ['invoice', 'year,check=off', /"check=off" does not belong to a year rule for invoices \(it takes start\)/],
    ['grn', 'sequence,digits', /"digits" does not belong/],
    ['grn', 'sequence,start=1,start=2', /start is given twice/],
    ['grn', 'letters,first=a', /first letter must be one capital letter/],
    ['grn', 'letters,first=AB', /first letter must be one capital letter/],
    ['grn', 'sequence,prefix=i', /prefix can have up to 10 characters/],
    ['grn', 'sequence,prefix=ABCDEFGHIJK', /prefix can have up to 10 characters/],
    ['grn', 'sequence,digits=0', /number of digits must be a whole number from 1 to 7/],
    ['grn', 'sequence,digits=8', /number of digits must be a whole number from 1 to 7/],
    ['grn', 'sequence,digits=four', /number of digits/],
    ['grn', 'sequence,start=0', /first number must be a whole number from 1 to 9999999/],
    ['grn', 'sequence,start=10000000', /first number must be a whole number from 1 to 9999999/],
    ['grn', 'letters,per-letter=0', /numbers per letter/],
    ['grn', 'year,prefix=ABCDEFGHIJ,digits=5', /longer than 20 characters/],
    ['invoice', 'letters', /An invoice number is a whole number/],
    ['invoice', 'free', /An invoice number is a whole number/],
    ['invoice', 'year,prefix=INV', /does not belong to a year rule for invoices \(it takes start\)/],
    ['invoice', 'sequence,digits=4', /does not belong to a sequence rule for invoices/],
    ['boxes', 'free', /Unknown document type boxes/],
  ];
  for (const [type, spec, message] of refused) assert.throws(() => parseSpec(type, spec), message, `${type} ${spec}`);
});

test('the command prints the rule as JSON, or the refusal with exit 1 and nothing on standard output', () => {
  const ok = spawnSync(process.execPath, [script, 'rule', 'grn', 'letters,first=X'], { encoding: 'utf8' });
  assert.equal(ok.status, 0);
  assert.deepEqual(JSON.parse(ok.stdout), { scheme: 'letters', first_letter: 'X' });
  const bad = spawnSync(process.execPath, [script, 'rule', 'grn', 'year,digits=9'], { encoding: 'utf8' });
  assert.equal(bad.status, 1);
  assert.equal(bad.stdout, '');
  assert.match(bad.stderr, /^Document numbers: The number of digits must be a whole number from 1 to 7\.\n$/);
  const usage = spawnSync(process.execPath, [script, 'rule', 'grn'], { encoding: 'utf8' });
  assert.equal(usage.status, 1);
  assert.match(usage.stderr, /Usage: node scripts\/numbering\.mjs rule/);
});

test('doctor prints the rules in force, and nothing when the database does not answer', () => {
  let asked;
  const answer = { ok: true, output: 'grn|letters|A####\ndispatch|sequence|I####\ninvoice|year|#\n' };
  assert.equal(numberingLine(args => { asked = args; return answer; }), 'Document numbers: GRN A#### (letters), dispatch I#### (sequence), invoice # (year)');
  assert.deepEqual(asked.slice(0, 3), ['psql', '-X', '-qAt']);
  assert.ok(asked.includes('supabase_admin') && asked.includes(NUMBERING_SQL));
  assert.equal(numberingLine(() => ({ ok: true, output: 'grn|free|typed by hand\ndispatch|year|GRN/26-27/####\ninvoice|sequence|#\n' })), 'Document numbers: GRN typed by hand (free), dispatch GRN/26-27/#### (year), invoice # (sequence)');
  for (const output of ['', 'grn|letters|A####\n', 'x|y|z\nx|y|z\nx|y|z\n']) assert.equal(numberingLine(() => ({ ok: true, output })), '', output);
  assert.equal(numberingLine(() => ({ ok: false, output: '' })), '');
});

test('doctor warns while a check is off, with the count, examples and the setup option that switches it on', () => {
  const dispatch = { scheme: 'sequence', prefix: 'I', width: 4, start: 1, first_letter: null, per_letter: null, check: false };
  const answer = JSON.stringify({ off: [{ type: 'dispatch', rule: dispatch, hint: 'I####', misfits: { count: 7912, examples: ['CLR0001', 'G2674', 'H0012A'] } }], strays: {} });
  let asked;
  const [warning, ...rest] = numberingProblems(args => { asked = args; return { ok: true, output: `${answer}\n` }; });
  assert.equal(rest.length, 0);
  assert.equal(warning, 'Dispatch numbers are not checked: 7912 existing numbers do not follow I#### (for example CLR0001, G2674, H0012A), so a number outside the rule is saved. '
    + 'To refuse them, run setup.sh --operator <your usual options> --dispatch-numbering sequence,prefix=I,digits=4,start=1,check=on (the numbers saved so far keep theirs), or an administrator switches the check on in the app.');
  assert.ok(asked.includes('supabase_admin') && asked.includes(NUMBERING_PROBLEMS_SQL));
  // The spec printed is one setup.sh accepts, and it is the stored rule with the check on.
  assert.deepEqual(parseSpec('dispatch', specOf(dispatch)), { scheme: 'sequence', prefix: 'I', width: 4, start: 1, check: true });
  const letters = { scheme: 'letters', prefix: '', width: 4, start: 1, first_letter: 'W', per_letter: 1000, check: false };
  assert.equal(specOf(letters), 'letters,first=W,digits=4,per-letter=1000,check=on');
  assert.deepEqual(parseSpec('grn', specOf(letters)), { scheme: 'letters', first_letter: 'W', width: 4, per_letter: 1000, check: true });
  const one = JSON.stringify({ off: [{ type: 'grn', rule: letters, hint: 'W####', misfits: { count: 1, examples: ['DG1'] } }], strays: {} });
  assert.match(numberingProblems(() => ({ ok: true, output: one }))[0], /^GRN numbers are not checked: 1 existing number does not follow W#### \(for example DG1\)/);
  assert.deepEqual(numberingProblems(() => ({ ok: true, output: JSON.stringify({ off: [], strays: {} }) })), [], 'nothing to say while every check is on');
});

test('doctor names the GRN letters in use outside the main series', () => {
  const output = JSON.stringify({ off: [], strays: { series: 'W–A', strays: [{ letter: 'Q', numbers: 1, example: 'Q0001' }, { letter: 'C', numbers: 2, example: 'C0001' }] } });
  assert.deepEqual(numberingProblems(() => ({ ok: true, output })), [
    'GRN letters are in use outside the main series W–A: Q (1 number, Q0001), C (2 numbers, C0001). A stray letter can steer the suggested GRN number; correct the number if it was a typing slip.']);
});

test('doctor names a single stray letter, and a highest letter that follows a letter that is not full', () => {
  const one = JSON.stringify({ off: [], strays: { series: 'W–A', strays: [{ letter: 'Q', numbers: 1, example: 'Q0001' }] } });
  assert.deepEqual(numberingProblems(() => ({ ok: true, output: one })), [
    'GRN letters are in use outside the main series W–A: Q (1 number, Q0001). A stray letter can steer the suggested GRN number; correct the number if it was a typing slip.']);
  const open = JSON.stringify({ off: [], strays: { series: 'A–B', strays: [], previous_not_full: { letter: 'B', previous: 'A', highest: 'A0500' } } });
  assert.deepEqual(numberingProblems(() => ({ ok: true, output: open })), [
    'GRN letter B is in use while the letter before it, A, is not full (its highest number is A0500), so the suggested GRN number continues B. If a B number was a typing slip, correct it.']);
  assert.deepEqual(numberingProblems(() => ({ ok: true, output: JSON.stringify({ off: [], strays: { series: 'W–A', strays: [] } }) })), [], 'a full series and no stray: nothing to say');
});

test('doctor says nothing about the numbers when the database does not answer or answers something else', () => {
  assert.deepEqual(numberingProblems(() => ({ ok: false, output: '' })), []);
  for (const output of ['', 'not json', '[]', 'null', '{"off": 5}']) assert.deepEqual(numberingProblems(() => ({ ok: true, output })), [], output);
});

test('doctor prints the numbering warnings after the other warnings, before the sensor warnings and the rules line', () => {
  const doctor = read('scripts/doctor.mjs');
  assert.match(doctor, /const numberingWarnings = numberingProblems\(inDb\)\.map\(text => `\\nWarning: \$\{text\}`\)\.join\(''\);/);
  assert.match(doctor, /\+ lanNote \+ numberingWarnings \+ sensorWarnings \+ \(numbering \? `\\n\$\{numbering\}` : ''\);/);
});

test('setup.sh checks the given rules before it changes anything, and stores only the ones that were given', () => {
  const setup = read('setup.sh');
  for (const option of ['--grn-numbering', '--dispatch-numbering', '--invoice-numbering']) assert.ok(setup.includes(option), option);
  const gate = setup.indexOf('node "$ROOT/scripts/numbering.mjs" rule');
  assert.ok(gate > setup.indexOf('doctor.mjs" --host-preflight') && gate < setup.indexOf('node "$ROOT/scripts/configure.mjs"'), 'the rules are checked after the host check and before configure.mjs');
  assert.ok(gate < setup.indexOf('scripts/migrate.sh" --operator'), 'and before the migrations');
  assert.match(setup, /if \[\[ -n "\$\{!given\+x\}" \]\]; then/, 'a rule is checked only when the option was given');
  assert.match(setup, /rule="\$\(node "\$ROOT\/scripts\/numbering\.mjs" rule "\$numbering" "\$\{!given\}"\)" \|\| exit 1/, 'a refusal stops setup');
  assert.match(setup, /-v company="\$COMPANY" \$\{NUMBERING_VARS\[@\]\+"\$\{NUMBERING_VARS\[@\]\}"\} < "\$ROOT\/scripts\/configure-operator\.sql"/, 'the checked rules reach configure-operator.sql as psql variables');
  assert.ok(!/CONFIG_ARGS\+=\("\$1" "\$2"\)[^\n]*numbering/.test(setup), 'the rules do not go into compose.env: the database holds them');
});

test('configure-operator.sql stores each rule that was given through the one function, and prints a change only', () => {
  const sql = read('scripts/configure-operator.sql');
  for (const type of ['grn', 'dispatch', 'invoice']) {
    assert.ok(sql.includes(`\\if :{?${type}_numbering}`), `${type} is stored only when its variable is set`);
    assert.ok(sql.includes(`warehouse_security.apply_document_numbering('${type}', :'${type}_numbering'::jsonb, NULL)`), type);
  }
  assert.equal(sql.split('\\if :numbering_changed').length - 1, 3, 'the message is printed only for a change');
  assert.match(sql, /Next GRN: %s; %s/);
  assert.match(sql, / GRNs keep their numbers\./);
});
