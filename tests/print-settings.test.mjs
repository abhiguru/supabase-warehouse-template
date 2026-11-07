import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { addMissingPrintValues, isWsl, printValues } from '../scripts/print-settings.mjs';
import { configure } from '../scripts/configure.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';

// WH-109: the print settings of compose.env. A fresh state gets them; an existing state gains only the missing ones.
const scratch = mkdtempSync(join(tmpdir(), 'warehouse-print-settings-'));
test.after(() => rmSync(scratch, { recursive: true, force: true }));

test('isWsl: true when the kernel release names Microsoft, false for a plain Linux kernel or an unreadable file', () => {
  const file = join(scratch, 'osrelease');
  writeFileSync(file, '5.15.167.4-microsoft-standard-WSL2\n');
  assert.equal(isWsl(file), true);
  writeFileSync(file, '6.8.0-45-generic\n');
  assert.equal(isWsl(file), false);
  assert.equal(isWsl(join(scratch, 'does-not-exist')), false);
});

test('isWsl reads WAREHOUSE_OSRELEASE_FILE when no file is passed', () => {
  const file = join(scratch, 'osrelease-hook');
  writeFileSync(file, '6.6.0-microsoft-standard-WSL2\n');
  const previous = process.env.WAREHOUSE_OSRELEASE_FILE;
  try {
    process.env.WAREHOUSE_OSRELEASE_FILE = file;
    assert.equal(isWsl(), true);
    assert.equal(printValues().PRINT_TRANSPORT, 'bridge');
    writeFileSync(file, '6.8.0-generic\n');
    assert.equal(printValues().PRINT_TRANSPORT, 'cups');
  } finally {
    if (previous === undefined) delete process.env.WAREHOUSE_OSRELEASE_FILE; else process.env.WAREHOUSE_OSRELEASE_FILE = previous;
  }
});

test('a fresh state: bridge on WSL, cups elsewhere, the one queue name, a random 64-hex token each time', () => {
  const wsl = printValues(true);
  const linux = printValues(false);
  assert.equal(wsl.PRINT_TRANSPORT, 'bridge');
  assert.equal(linux.PRINT_TRANSPORT, 'cups');
  for (const values of [wsl, linux]) {
    assert.equal(values.PRINTER_NAME, 'LQ1310_RAW');
    assert.match(values.PRINTBRIDGE_TOKEN, /^[0-9a-f]{64}$/);
  }
  assert.notEqual(printValues(true).PRINTBRIDGE_TOKEN, printValues(true).PRINTBRIDGE_TOKEN);
  assert.deepEqual(Object.keys(wsl).sort(), ['PRINTBRIDGE_TOKEN', 'PRINTER_NAME', 'PRINT_TRANSPORT'], 'the address and the printer URI are left to the operator and compose.sh');
});

test('addMissingPrintValues adds absent and empty values, never replaces one that is set', () => {
  const none = addMissingPrintValues('A=1\nB=2\n', true);
  assert.deepEqual(none.added.sort(), ['PRINTBRIDGE_TOKEN', 'PRINTER_NAME', 'PRINT_TRANSPORT']);
  assert.match(none.text, /^A=1\nB=2\n/);
  assert.match(none.text, /^PRINT_TRANSPORT=bridge$/m);
  // A file without a final newline still gets one line per value.
  assert.match(addMissingPrintValues('A=1', false).text, /^A=1\nPRINT_TRANSPORT=cups\n/);

  // The template has the lines, empty: they are filled in place, once each.
  const template = 'PRINT_TRANSPORT=cups\nPRINTER_NAME=LQ1310_RAW\nPRINTER_URI=\nPRINTBRIDGE_TOKEN=\nPRINTBRIDGE_URL=\n';
  const filled = addMissingPrintValues(template, false);
  assert.deepEqual(filled.added, ['PRINTBRIDGE_TOKEN']);
  assert.equal(filled.text.match(/^PRINTBRIDGE_TOKEN=/gm).length, 1);
  assert.match(filled.text, /^PRINTBRIDGE_TOKEN=[0-9a-f]{64}$/m);
  assert.match(filled.text, /^PRINTER_URI=$/m);

  // Everything set: unchanged, whatever the host. An operator's choice of bridge on Linux (or cups on WSL) survives.
  const set = 'PRINT_TRANSPORT=bridge\nPRINTER_NAME=Office Printer\nPRINTBRIDGE_TOKEN=abc\n';
  for (const wsl of [true, false]) assert.deepEqual(addMissingPrintValues(set, wsl), { text: set, added: [] });
});

function state(name) {
  const root = join(scratch, `${name}-checkout`);
  mkdirSync(root);
  copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
  const providerEnv = join(scratch, `${name}-provider.env`);
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=provider-key\nMSG91_TEMPLATE_ID=flow-id\nMSG91_PE_ID=pe-id\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
  const stateDir = join(scratch, `${name}-state`);
  return { root, stateDir, envPath: join(stateDir, 'config/compose.env'), options: { stateDir, apiUrl: 'https://api.example.com', company: 'Acme Stores', providerEnv } };
}

test('configure: a fresh state gets the print values (cups here), printing stays off, and a rerun changes nothing', () => {
  const { root, envPath, options, stateDir } = state('fresh');
  const osrelease = join(scratch, 'plain-linux');
  writeFileSync(osrelease, '6.8.0-generic\n');
  const previous = process.env.WAREHOUSE_OSRELEASE_FILE;
  process.env.WAREHOUSE_OSRELEASE_FILE = osrelease;
  try {
    configure(root, options);
    const env = readEnv(envPath);
    assert.equal(env.PRINT_TRANSPORT, 'cups');
    assert.equal(env.PRINTER_NAME, 'LQ1310_RAW');
    assert.match(env.PRINTBRIDGE_TOKEN, /^[0-9a-f]{64}$/);
    assert.equal(env.PRINTBRIDGE_URL, '');
    assert.equal(env.PRINTER_URI, '');
    assert.equal(JSON.parse(readFileSync(join(stateDir, 'public/instance.json'), 'utf8')).capabilities.printing, false);
    const before = readFileSync(envPath);
    configure(root, options);
    assert.deepEqual(readFileSync(envPath), before, 'a rerun keeps the token and every other line');
  } finally {
    if (previous === undefined) delete process.env.WAREHOUSE_OSRELEASE_FILE; else process.env.WAREHOUSE_OSRELEASE_FILE = previous;
  }
});

test('configure: a state from before WH-109 gains the values on a rerun; values the operator set stay', () => {
  const { root, envPath, options } = state('old');
  configure(root, options);
  const original = readFileSync(envPath, 'utf8');
  const stripped = original.replace(/^(?:PRINT_TRANSPORT|PRINTER_NAME|PRINTER_URI|PRINTBRIDGE_[A-Z]+)=.*\n/gm, '').replace(/^# (?:Where print jobs|The one printer|cups only|bridge only).*\n(?:#.*\n)*/gm, '');
  assert.doesNotMatch(stripped, /^PRINT/m);
  writeFileSync(envPath, stripped, { mode: 0o600 });
  configure(root, options);
  const gained = readEnv(envPath);
  assert.match(gained.PRINT_TRANSPORT, /^(?:cups|bridge)$/);
  assert.equal(gained.PRINTER_NAME, 'LQ1310_RAW');
  assert.match(gained.PRINTBRIDGE_TOKEN, /^[0-9a-f]{64}$/);
  // Rerun again: the token is not regenerated.
  configure(root, options);
  assert.equal(readEnv(envPath).PRINTBRIDGE_TOKEN, gained.PRINTBRIDGE_TOKEN);
  // An operator's own values survive a rerun.
  writeFileSync(envPath, readFileSync(envPath, 'utf8').replace(/^PRINTER_NAME=.*$/m, 'PRINTER_NAME=Office Printer').replace(/^PRINT_TRANSPORT=.*$/m, 'PRINT_TRANSPORT=bridge'), { mode: 0o600 });
  configure(root, options);
  const kept = readEnv(envPath);
  assert.equal(kept.PRINTER_NAME, 'Office Printer');
  assert.equal(kept.PRINT_TRANSPORT, 'bridge');
  assert.equal(kept.PRINTBRIDGE_TOKEN, gained.PRINTBRIDGE_TOKEN);
});

test('product: configure from the command line does not say "unchanged" when a rerun only added the print values (scripts/configure.mjs:460 and :529 leave withPrintValues.added out)', { todo: 'the report ignores the added print values' }, () => {
  const { root, envPath, options, stateDir } = state('cli');
  configure(root, options);
  writeFileSync(envPath, readFileSync(envPath, 'utf8').replace(/^PRINTBRIDGE_TOKEN=.*$/m, 'PRINTBRIDGE_TOKEN='), { mode: 0o600 });
  const run = spawnSync(process.execPath, [new URL('../scripts/configure.mjs', import.meta.url).pathname, '--state-dir', stateDir], {
    encoding: 'utf8', env: { ...process.env, NODE_TEST_CONTEXT: '' },
  });
  assert.equal(run.status, 0, run.stderr);
  assert.match(readEnv(envPath).PRINTBRIDGE_TOKEN, /^[0-9a-f]{64}$/, 'the empty token was filled');
  assert.doesNotMatch(run.stdout, /^Preserved existing operator state unchanged\.$/m, 'the state did change');
});
