import { test } from 'node:test';
import assert from 'node:assert/strict';
import { documentHtml, kgEach } from '../functions/_shared/document-html.ts';
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
