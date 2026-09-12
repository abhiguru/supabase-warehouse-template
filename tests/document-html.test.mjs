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
