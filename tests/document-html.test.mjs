import { test } from 'node:test';
import assert from 'node:assert/strict';
import { documentHtml } from '../functions/_shared/document-html.ts';
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
