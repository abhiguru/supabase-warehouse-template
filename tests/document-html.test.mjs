import { test } from 'node:test';
import assert from 'node:assert/strict';
import { documentDate, documentHtml, kgEach } from '../functions/_shared/document-html.ts';
test('every document field is escaped and external content is blocked', () => {
  const attack = '<script>fetch("http://private.internal")</script>';
  const html = documentHtml(attack,attack,{[attack]:attack},[attack],[[attack]]);
  assert.ok(!html.includes('<script>'));
  assert.equal(html.match(/&lt;script&gt;/g).length,6);
  assert.ok(html.includes("default-src 'none'"));
});
test('a Gujarati name is kept as written and set in the sans Gujarati font', () => {
  const html = documentHtml('Cold Storage','GRN',{Customer:'ગુરુ ટ્રેડર્સ'},['Item'],[['લસણ']]);
  assert.ok(html.includes('ગુરુ ટ્રેડર્સ') && html.includes('લસણ'));
  assert.match(html, /body\{font:12px [^;]*'Noto Sans Gujarati'[^;]*sans-serif;/);
});

test('the Kg each cell of a GRN line prints a dash for 0, null, undefined and NaN, and any other weight as it is', () => {
  for (const empty of [0, null, undefined, NaN]) assert.equal(kgEach(empty), '\u2014');
  for (const value of [50, 12.5, '25']) assert.equal(kgEach(value), value);
  assert.match(documentHtml('GRN', 'Co', {}, ['Kg each'], [[kgEach(0)], [kgEach(null)], [kgEach(50)]]), /<td>\u2014<\/td><\/tr><tr><td>\u2014<\/td><\/tr><tr><td>50<\/td>/);
});

test('the Date line of a document is DD-MM-YYYY on India\'s calendar, like the report PDFs', () => {
  // A receipt: the database writes a timestamptz; the raw text used to be printed.
  assert.equal(documentDate('2026-10-13T00:00:00+00:00'), '13-10-2026');
  assert.equal(documentDate('2026-01-15'), '15-01-2026');
  // 21:00 UTC on 30 September is 02:30 on 1 October in India.
  assert.equal(documentDate('2026-09-30T21:00:00+00:00'), '01-10-2026');
  assert.equal(documentDate('2026-10-13 06:30:00+00'), '13-10-2026');
  assert.equal(documentDate(undefined), '');
  assert.equal(documentDate('not a date'), 'not a date');
  const html = documentHtml('GRN', 'Co', { Number: 'G1', Date: documentDate('2026-10-13T00:00:00+00:00') }, [], []);
  assert.match(html, /<strong>Date:<\/strong> 13-10-2026<\/p>/);
  assert.doesNotMatch(html, /T00:00:00/);
});

test('the GRN, dispatch, invoice and stock documents all print their date through documentDate', async () => {
  const { readFileSync } = await import('node:fs');
  const source = readFileSync(new URL('../functions/_shared/document-pdf.ts', import.meta.url), 'utf8');
  assert.match(source, /Date: documentDate\(date\)/);
  assert.doesNotMatch(source, /Date: date[,\s]/);
});
