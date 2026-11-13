// The facility's legal settings (migration 199, WH-140): the setup.sh options and the checks of scripts/legal.mjs that run before anything is
// changed, the warnings doctor prints, and how setup.sh, configure-operator.sql and the edge function use them. The database side (what is
// stored, the audit row, who may change it) is tests/facility_legal_199.sql.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { LEGAL_OPTIONS, LEGAL_SQL, checkLegal, legalProblems } from '../scripts/legal.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const script = fileURLToPath(new URL('../scripts/legal.mjs', import.meta.url));
const cli = (...args) => spawnSync(process.execPath, [script, ...args], { encoding: 'utf8' });

test('the six setup options map to the six keys the database takes, trimmed', () => {
  assert.deepEqual(Object.keys(LEGAL_OPTIONS), ['--legal-name', '--legal-city', '--legal-state', '--grievance-name', '--grievance-email', '--grievance-phone']);
  assert.deepEqual(checkLegal({ city: '  Ahmedabad ', grievanceEmail: ' officer@example.test ', grievancePhone: '+91 99999 00000' }),
    { city: 'Ahmedabad', grievanceEmail: 'officer@example.test', grievancePhone: '+91 99999 00000' });
  assert.deepEqual(checkLegal({}), {});
  assert.deepEqual(checkLegal({ grievanceEmail: '', city: '' }), { grievanceEmail: '', city: '' }, 'an empty value is passed on: it clears');
});

test('a value that is wrong is refused before anything is changed, naming the option', () => {
  assert.throws(() => checkLegal({ grievanceEmail: 'not-an-email' }), /--grievance-email must be an email address/);
  assert.throws(() => checkLegal({ grievanceEmail: 'a@b' }), /--grievance-email/);
  assert.throws(() => checkLegal({ grievancePhone: 'call me' }), /--grievance-phone must be 5 to 20 digits/);
  assert.throws(() => checkLegal({ grievancePhone: '1234' }), /--grievance-phone/);
  assert.throws(() => checkLegal({ city: 'x'.repeat(121) }), /--legal-city must be printable text of at most 120 characters/);
  assert.equal(checkLegal({ city: 'x'.repeat(120) }).city.length, 120);
  assert.throws(() => checkLegal({ state: 'a\nb' }), /--legal-state must be printable/);
  assert.throws(() => checkLegal({ grievanceName: 'a b' }), /--grievance-name must be printable/);
});

test('the command line prints the JSON the database takes, and refuses what is wrong with exit 1', () => {
  const ok = cli('check', '--legal-city=Ahmedabad', '--grievance-email=officer@example.test');
  assert.equal(ok.status, 0, ok.stderr);
  assert.deepEqual(JSON.parse(ok.stdout), { city: 'Ahmedabad', grievanceEmail: 'officer@example.test' });
  const bad = cli('check', '--grievance-email=nope');
  assert.equal(bad.status, 1);
  assert.match(bad.stderr, /Legal settings: --grievance-email must be an email address/);
  assert.equal(bad.stdout, '');
  const unknown = cli('check', '--legal-website=x');
  assert.equal(unknown.status, 1);
  assert.match(unknown.stderr, /unknown option --legal-website/);
  const usage = cli('rule', '--legal-city=x');
  assert.equal(usage.status, 1);
  assert.match(usage.stderr, /Usage: node scripts\/legal\.mjs check/);
});

test('doctor warns once for each empty value except the legal name, and says nothing when the database does not answer', () => {
  const answer = json => () => ({ ok: true, output: `${JSON.stringify(json)}\n` });
  const empty = { legalName: 'Fictional Cold Storage', city: '', state: '', grievanceName: '', grievanceEmail: '', grievancePhone: '' };
  const all = legalProblems(answer(empty));
  assert.equal(all.length, 5);
  for (const option of ['--legal-city', '--legal-state', '--grievance-name', '--grievance-email', '--grievance-phone']) assert.ok(all.some(text => text.includes(option)), option);
  assert.ok(all.every(text => /Not given yet/.test(text) && /docs\/PRIVACY_FOR_OPERATORS\.md/.test(text)));
  assert.deepEqual(legalProblems(answer({ ...empty, legalName: '' })).length, 5, 'an empty legal name is no warning');
  const filled = { legalName: 'A', city: 'Ahmedabad', state: 'Gujarat', grievanceName: 'A. Officer', grievanceEmail: 'officer@example.test', grievancePhone: '+91 99999 00000' };
  assert.deepEqual(legalProblems(answer(filled)), []);
  assert.deepEqual(legalProblems(answer({ ...filled, grievancePhone: '  ' })).length, 1);
  assert.match(legalProblems(answer({ ...filled, grievanceEmail: '' }))[0], /grievance email/);
  assert.deepEqual(legalProblems(() => ({ ok: false, output: '' })), []);
  for (const output of ['', 'not json', '[]', 'null', '{"off": 5}']) assert.deepEqual(legalProblems(() => ({ ok: true, output })), [], output);
  // It asks the database as the owner, through the one SQL text.
  let asked;
  legalProblems(args => { asked = args; return { ok: false, output: '' }; });
  assert.ok(asked.includes(LEGAL_SQL) && asked.includes('supabase_admin'));
});

test('setup.sh checks the legal options before it starts anything and stores them after the migrations, only when given', () => {
  const setup = read('setup.sh');
  for (const option of Object.keys(LEGAL_OPTIONS)) assert.ok(setup.includes(option), option);
  assert.match(setup, /--legal-name\|--legal-city\|--legal-state\|--grievance-name\|--grievance-email\|--grievance-phone\)/);
  assert.match(setup, /LEGAL_JSON="\$\(node "\$ROOT\/scripts\/legal\.mjs" check "\$\{LEGAL_ARGS\[@\]\}"\)" \|\| exit 1/, 'a refusal stops setup');
  assert.match(setup, /if \(\(\$\{#LEGAL_ARGS\[@\]\}\)\); then/, 'checked only when an option was given');
  // The order: the check runs after the host preflight and before configure, the migrations and the first service start.
  const gate = setup.indexOf('scripts/legal.mjs" check');
  assert.ok(gate > setup.indexOf('doctor.mjs" --host-preflight'), 'checked after the host preflight');
  assert.ok(gate < setup.indexOf('node "$ROOT/scripts/configure.mjs"'), 'and before configure writes anything');
  assert.ok(gate < setup.indexOf('scripts/migrate.sh" --operator'), 'and before the migrations');
  assert.match(setup, /-v company="\$COMPANY" .*\$\{LEGAL_VARS\[@\]\+"\$\{LEGAL_VARS\[@\]\}"\} < "\$ROOT\/scripts\/configure-operator\.sql"/, 'the checked values reach configure-operator.sql');
  assert.ok(!/CONFIG_ARGS\+=\("\$1" "\$2"\)[^\n]*legal/.test(setup), 'the values do not go into the state files: the database holds them');
  const sql = read('scripts/configure-operator.sql');
  assert.ok(sql.includes('\\if :{?legal}'), 'stored only when the variable is set');
  assert.ok(sql.includes("warehouse_security.apply_facility_legal(:'legal'::jsonb, NULL)"));
});

test('the edge function passes the legal object on with six text values, empty where missing', () => {
  const edge = read('functions/get-public-config/index.ts');
  assert.match(edge, /for \(const key of \['legalName', 'city', 'state', 'grievanceName', 'grievanceEmail', 'grievancePhone'\]\)/);
  assert.match(edge, /legal: legalSettings\(config\.legal\)/);
});

test('the operator note and the changelog describe the legal settings', () => {
  const doc = read('docs/PRIVACY_FOR_OPERATORS.md');
  for (const option of Object.keys(LEGAL_OPTIONS)) assert.ok(doc.includes(option), `${option} in docs/PRIVACY_FOR_OPERATORS.md`);
  assert.match(doc, /set_facility_legal|administrator/i);
  assert.match(read('CHANGELOG.md'), /legal/i);
  assert.ok(read('README.md').includes('PRIVACY_FOR_OPERATORS.md') || read('docs/RELEASE_CHECKLIST.md').includes('PRIVACY_FOR_OPERATORS.md') || read('CONTRIBUTING.md').includes('PRIVACY_FOR_OPERATORS.md'), 'the note is linked');
});
