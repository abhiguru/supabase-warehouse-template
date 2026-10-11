import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

// The printing functions import Deno-only modules, so the fallback that writes a
// quantity in words is taken out of each file as text and run on its own.
for (const name of ['print-grn-preprinted', 'print-dispatch-preprinted']) {
  test(`${name}: quantity in words handles lakhs with a thousands part`, () => {
    const source = readFileSync(new URL(`../functions/${name}/index.ts`, import.meta.url), 'utf8');
    const text = /^function numberToIndianWords\(num: number\): string \{\n[\s\S]*?\n\}\n/m.exec(source)?.[0];
    assert.ok(text, 'numberToIndianWords was not found');
    const words = new Function(`${stripTypeScriptTypes(text)}; return numberToIndianWords;`)();
    assert.equal(words(999), 'Nine Hundred Ninety Nine only');
    assert.equal(words(12000), 'Twelve Thousand only');
    assert.equal(words(100000), 'One Lakh only');
    // At 1,01,000 and above with a thousands part the function assigned to a constant and threw.
    assert.equal(words(101000), 'One Lakh One Thousand only');
    assert.equal(words(250345), 'Two Lakh Fifty Thousand Three Hundred Forty Five only');
  });
}
