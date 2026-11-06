import test from 'node:test';
import assert from 'node:assert/strict';
import { bridgeBaseUrl, cupsQueueUrl, printTransportName, printerName, safeDocName, DEFAULT_PRINTER_NAME, CUPS_SERVER_URL } from '../functions/_shared/print-config.ts';

// WH-109: where print jobs go is read from four settings; an invalid value is a refusal, never a guess.
const env = values => name => values[name];

test('PRINT_TRANSPORT: cups when unset or empty, bridge when asked for, anything else is null', () => {
  assert.equal(printTransportName(env({})), 'cups');
  assert.equal(printTransportName(env({ PRINT_TRANSPORT: '' })), 'cups');
  assert.equal(printTransportName(env({ PRINT_TRANSPORT: '  CUPS ' })), 'cups');
  assert.equal(printTransportName(env({ PRINT_TRANSPORT: 'Bridge' })), 'bridge');
  for (const value of ['usb', 'cupss', 'bridge,cups', 'http', '0']) assert.equal(printTransportName(env({ PRINT_TRANSPORT: value })), null, value);
});

test('PRINTER_NAME: default LQ1310_RAW; CUPS takes letters, digits, _ and - only; a Windows name may have spaces and a few marks', () => {
  assert.equal(DEFAULT_PRINTER_NAME, 'LQ1310_RAW');
  assert.equal(printerName(env({})), 'LQ1310_RAW');
  assert.equal(printerName(env({ PRINTER_NAME: '   ' })), 'LQ1310_RAW');
  assert.equal(printerName(env({ PRINTER_NAME: ' Office-2 ' })), 'Office-2');
  // The transport decides which rule applies; unset means cups, an invalid transport falls back to cups rules.
  assert.equal(printerName(env({ PRINTER_NAME: 'EPSON LQ-1310 (Copy 1)' })), null);
  assert.equal(printerName(env({ PRINTER_NAME: 'EPSON LQ-1310 (Copy 1)', PRINT_TRANSPORT: 'bridge' })), 'EPSON LQ-1310 (Copy 1)');
  assert.equal(printerName(env({ PRINTER_NAME: 'EPSON LQ-1310', PRINT_TRANSPORT: 'nonsense' })), null);
  for (const bad of ['a/b', '../x', 'q?x', 'x'.repeat(128), 'café', 'a\nb']) {
    assert.equal(printerName(env({ PRINTER_NAME: bad }), 'cups'), null, JSON.stringify(bad));
    assert.equal(printerName(env({ PRINTER_NAME: bad }), 'bridge'), null, JSON.stringify(bad));
  }
  assert.equal(printerName(env({ PRINTER_NAME: 'x'.repeat(127) }), 'cups'), 'x'.repeat(127));
  assert.equal(printerName(env({ PRINTER_NAME: '-x' }), 'bridge'), null, 'a Windows name starts with a letter or digit');
});

test('the CUPS queue address is built only from a valid name, on the compose network host', () => {
  assert.equal(CUPS_SERVER_URL, 'http://cups:631');
  assert.equal(cupsQueueUrl(env({})), 'http://cups:631/printers/LQ1310_RAW');
  assert.equal(cupsQueueUrl(env({ PRINTER_NAME: 'Office_2' })), 'http://cups:631/printers/Office_2');
  // A name valid only for the bridge never becomes a CUPS path.
  assert.equal(cupsQueueUrl(env({ PRINTER_NAME: 'EPSON LQ-1310', PRINT_TRANSPORT: 'bridge' })), null);
  assert.equal(cupsQueueUrl(env({ PRINTER_NAME: 'a/../b' })), null);
});

test('the bridge address: an http(s) origin without a path, query or fragment; trailing slashes dropped', () => {
  assert.equal(bridgeBaseUrl(env({ PRINTBRIDGE_URL: 'http://172.28.80.1:6632' })), 'http://172.28.80.1:6632');
  assert.equal(bridgeBaseUrl(env({ PRINTBRIDGE_URL: ' http://172.28.80.1:6632/// ' })), 'http://172.28.80.1:6632');
  assert.equal(bridgeBaseUrl(env({ PRINTBRIDGE_URL: 'https://bridge.example.test' })), 'https://bridge.example.test');
  for (const bad of [undefined, '', 'bridge:6632', 'ftp://h:1', 'file:///etc/passwd', 'javascript:1', 'http://h:1/print', 'http://h:1/?a=1', 'http://h:1/#x', 'http://']) {
    assert.equal(bridgeBaseUrl(env({ PRINTBRIDGE_URL: bad })), null, String(bad));
  }
});

test('safeDocName: printable ASCII, 100 characters at most, a fallback', () => {
  assert.equal(safeDocName('GRN-1-to-9'), 'GRN-1-to-9');
  assert.equal(safeDocName('AગB'), 'A?B');
  assert.equal(safeDocName('line\r\nbreak'), 'line??break');
  assert.equal(safeDocName('x'.repeat(250)).length, 100);
  assert.equal(safeDocName('   '), 'Print Job');
  assert.equal(safeDocName(''), 'Print Job');
});
