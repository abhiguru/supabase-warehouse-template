import { test } from 'node:test';
import assert from 'node:assert/strict';

test('the PDF footer escapes every value it is given', async () => {
  const oldDeno = globalThis.Deno;
  globalThis.Deno = { env: { get: () => undefined } };
  try {
    const { createFooterHtml } = await import('../functions/_shared/pdf-renderer-client.ts');
    const html = createFooterHtml('A&B <script>fetch("http://meta:8080")</script>', '<img src=x onerror=1>', `"7'`);
    assert.ok(!html.includes('<script>') && !html.includes('<img'), 'no markup from a value reaches the page');
    assert.ok(html.includes('A&amp;B &lt;script&gt;fetch(&quot;http://meta:8080&quot;)&lt;/script&gt;'));
    assert.ok(html.includes('&lt;img src=x onerror=1&gt; #&quot;7&#39;'));
    // Page numbers come from Chromium's own classes, not from script.
    assert.ok(html.includes('<span class="pageNumber"></span>') && html.includes('<span class="totalPages"></span>'));
    assert.ok(createFooterHtml('My Warehouse', 'Sample', '123456').includes('<div class="footer-left">Sample #123456</div>'));
  } finally { globalThis.Deno = oldDeno; }
});

test('htmlToPdf posts to the renderer /render route and logs at most 2 KB of an error body', async () => {
  const oldDeno = globalThis.Deno;
  const oldFetch = globalThis.fetch;
  const oldError = console.error;
  const logged = [];
  const calls = [];
  globalThis.Deno = { env: { get: () => undefined } };
  console.error = (...args) => logged.push(args.join(' '));
  try {
    const { htmlToPdf } = await import('../functions/_shared/pdf-renderer-client.ts');
    globalThis.fetch = async (url, init) => { calls.push({ url, init }); return new Response('%PDF-1.4 %%EOF', { status: 200 }); };
    const pdf = await htmlToPdf('<p>x</p>', { footerHtml: '<p>f</p>' });
    assert.equal(new TextDecoder().decode(pdf), '%PDF-1.4 %%EOF');
    assert.equal(calls[0].url, 'http://pdf-renderer:3000/render');
    assert.equal(calls[0].init.redirect, 'error');
    assert.ok(calls[0].init.signal, 'a timeout signal is set');
    const form = calls[0].init.body;
    assert.deepEqual(form.getAll('files').map(file => file.name).sort(), ['footer.html', 'index.html']);
    assert.equal(form.get('marginBottom'), '1');
    assert.equal(form.get('preferCssPageSize'), 'true');

    globalThis.fetch = async () => new Response(JSON.stringify({ error: 'x'.repeat(10000), code: 503 }), { status: 503 });
    await assert.rejects(() => htmlToPdf('<p>x</p>'), /PDF generation failed: 503/);
    assert.match(logged[0], /^PDF renderer returned HTTP 503 \{"error":"x+/);
    assert.ok(logged[0].length <= 2048 + 64, `log line is bounded (${logged[0].length})`);
  } finally { globalThis.Deno = oldDeno; globalThis.fetch = oldFetch; console.error = oldError; }
});
