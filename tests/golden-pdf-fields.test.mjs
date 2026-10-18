import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fieldsFor } from './golden-pdf/fields.mjs';

const root = new URL('..', import.meta.url);

// What the real client puts in the form for a set of options (fetch is captured, nothing is sent).
async function clientFields(options) {
  const oldDeno = globalThis.Deno;
  const oldFetch = globalThis.fetch;
  let form;
  globalThis.Deno = { env: { get: () => undefined } };
  globalThis.fetch = async (url, init) => { form = init.body; return new Response('%PDF-1.4 %%EOF'); };
  try {
    const { htmlToPdf } = await import('../functions/_shared/pdf-renderer-client.ts');
    await htmlToPdf('<p>x</p>', options);
    return [...form.entries()].filter(([, value]) => typeof value === 'string');
  } finally { globalThis.Deno = oldDeno; globalThis.fetch = oldFetch; }
}

const sets = [
  {},
  { footerHtml: '<p>f</p>' },
  { footerHtml: '<p>f</p>', marginBottom: 1 },
  { headerHtml: '<p>h</p>', footerHtml: '<p>f</p>', marginTop: 1.2, marginBottom: 0.7 },
  { landscape: true, scale: 0.9, printBackground: false, emulatedMediaType: 'screen', preferCssPageSize: false, paperWidth: 5.83, paperHeight: 8.27, marginLeft: 0.2, marginRight: 0.3 },
  { landscape: false, scale: 0, waitDelay: '1s' },
];

test('the golden job posts exactly the fields the function client posts, defaults included', async () => {
  for (const options of sets) {
    const expected = await clientFields(options);
    assert.deepEqual(fieldsFor(options), expected, `fields differ for ${JSON.stringify(options)}`);
  }
});

test('every corpus case has an options.json whose fields the client accepts, and run.sh uses fields.mjs', () => {
  const corpus = new URL('tests/golden-pdf/corpus/', root);
  const cases = readdirSync(corpus);
  assert.ok(cases.length >= 11, 'the corpus was read');
  for (const name of cases) {
    const options = JSON.parse(readFileSync(new URL(`${name}/options.json`, corpus), 'utf8'));
    assert.deepEqual(Object.keys(options).filter(key => !['footerHtml', 'headerHtml', 'marginBottom', 'marginTop', 'marginLeft', 'marginRight', 'paperWidth', 'paperHeight', 'landscape', 'scale', 'printBackground', 'emulatedMediaType', 'preferCssPageSize', 'waitDelay'].includes(key)), [], `${name}: an option the client does not know`);
    // The footer travels as a file; the case must carry the same HTML in footer.html.
    if (options.footerHtml) assert.equal(readFileSync(new URL(`${name}/footer.html`, corpus), 'utf8').replace(/\s+/g, ''), options.footerHtml.replace(/\s+/g, ''), `${name}: footer.html matches options.json`);
  }
  assert.match(readFileSync(new URL('tests/golden-pdf/run.sh', root), 'utf8'), /node "\$HERE\/fields\.mjs" "\$dir\/options\.json"/);
});
