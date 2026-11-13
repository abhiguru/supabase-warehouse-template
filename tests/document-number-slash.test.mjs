// WH-185 (with WH-180 step 3): a GRN or dispatch number written by the year scheme (migration 127) holds '/', e.g. GRN/26-27/0042.
// The PDF functions accepted only letters, digits and '-', so those documents were refused with 400. These tests run the number rule
// the function ships (read out of functions/_shared/document-pdf.ts, which needs Deno to load), the 409 answer, and pin the lookup by id
// and by number. The function end to end needs Deno and the gateway (not run here).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createAuthErrorResponse } from '../functions/_shared/auth-helpers.ts';
import { importedNotice } from '../functions/_shared/document-html.ts';
import { documentLookupColumns } from '../functions/_shared/document-columns.ts';

const source = readFileSync(new URL('../functions/_shared/document-pdf.ts', import.meta.url), 'utf8');
const rule = source.match(/const documentNumber = (\/\^.*\$\/);/);

test('the number rule is found in the function and accepts a number with "/"', () => {
  assert.ok(rule, 'const documentNumber = /.../ is in document-pdf.ts');
  const documentNumber = new RegExp(rule[1].slice(1, rule[1].lastIndexOf('/')));
  for (const ok of ['GRN/26-27/0042', 'DSP/26-27/0042', 'G/1', 'T0001', 'A-12', '1234', 'X'.repeat(20)]) assert.ok(documentNumber.test(ok), ok);
  for (const bad of ['', 'X'.repeat(21), 'GRN 1', 'GRN;1', 'a\nb', 'GRN\\1', "G'1", 'G%2F1', 'G?x=1', 'G..', 'é1']) assert.ok(!documentNumber.test(bad), JSON.stringify(bad));
});

test('both lookups exist: by id (a UUID) and by number, the number checked with the shared rule, for GRN and dispatch alike', () => {
  assert.match(source, /body\.id !== undefined && body\.id !== null/);
  assert.match(source, /lookup = lookup\.eq\('id',body\.id\)/);
  assert.match(source, /documentNumber\.test\(String\(value\)\)/);
  assert.match(source, /const value = kind === 'grn' \? body\.gr_no : kind === 'dispatch' \? body\.disp_no : body\.inv_no/);
  assert.ok(!/\^\[A-Za-z0-9-\]\{1,20\}\$/.test(source), 'the old rule without "/" is gone');
  // The number goes to REST as a filter value of the client library (encoded by it), never spliced into a URL by hand.
  assert.match(source, /lookup\.eq\(key,value\)/);
  assert.ok(!/gr_no=eq\.\$\{|disp_no=eq\.\$\{/.test(source), 'no hand-built filter string');
});

test('a number shared by two documents is a 409 SEVERAL_DOCUMENTS, never one of them', async () => {
  assert.match(source, /found\.data\.length > 1\) throw \{ status: 409, code: 'SEVERAL_DOCUMENTS'/);
  const response = createAuthErrorResponse({ status: 409, code: 'SEVERAL_DOCUMENTS', message: 'Several documents have this number; update the app' });
  assert.equal(response.status, 409);
  assert.match((await response.json()).error ?? '', /Several documents/);
});

test('other statuses are still folded as before (an unknown one is a 500)', () => {
  for (const status of [400, 401, 403, 404, 405, 503]) assert.equal(createAuthErrorResponse({ status, message: 'x' }).status, status);
  assert.equal(createAuthErrorResponse({ status: 418, message: 'x' }).status, 500);
});

test('the lookup columns carry the number, id and the imported mark per kind; imported PDFs say so', () => {
  assert.equal(documentLookupColumns('grn'), 'id,import_batch_id,gr_no');
  assert.equal(documentLookupColumns('dispatch'), 'id,import_batch_id,disp_no');
  assert.equal(documentLookupColumns('invoice'), 'id,import_batch_id,inv_no');
  assert.equal(importedNotice, 'Imported from the previous system');
});
