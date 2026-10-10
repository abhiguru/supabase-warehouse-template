import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validPrinterName, printerStatusFailure } from '../functions/_shared/printer-name.ts';

test('a printer name is a CUPS queue name, not a path', () => {
  for (const name of ['default', 'Office_Printer-2', 'a'.repeat(127)]) assert.equal(validPrinterName(name), true, name);
  for (const name of ['../admin', 'default#x', 'a/b', 'a b', '', 'a'.repeat(128), 'é', 7, null, undefined, ['default'], { name: 'default' }]) {
    assert.equal(validPrinterName(name), false, String(name));
  }
});

test('a printer status failure names only the causes an administrator can act on', () => {
  assert.deepEqual(printerStatusFailure(new Error('connect ECONNREFUSED 172.18.0.7:631')),
    { status: 503, message: 'Cannot connect to printer. Check if CUPS service is running.' });
  assert.deepEqual(printerStatusFailure(new Error('The printer or class was not found.')), { status: 404, message: 'Printer not found. Check printer name.' });
  for (const error of [new Error('getaddrinfo ENOTFOUND cups'), new Error('socket hang up'), { message: 'NotEnoughData' }, 'text', undefined]) {
    assert.deepEqual(printerStatusFailure(error), { status: 500, message: 'Printer status unavailable' });
  }
});

test('get-printer-status checks the name before building the CUPS URL and answers through the shared failure text', () => {
  const source = readFileSync(new URL('../functions/get-printer-status/index.ts', import.meta.url), 'utf8');
  assert.ok(source.indexOf('validPrinterName(printer_name)') > 0, 'name is validated');
  assert.ok(source.indexOf('validPrinterName(printer_name)') < source.indexOf('http://cups:631/printers/'), 'validated before the URL is built');
  assert.ok(source.includes('printerStatusFailure(error)'));
  assert.ok(!/error:\s*error\.message/.test(source) && !source.includes('let errorMessage = error.message'), 'raw error text is not returned');
});
