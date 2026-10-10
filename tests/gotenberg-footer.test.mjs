import { test } from 'node:test';
import assert from 'node:assert/strict';

test('the PDF footer escapes every value it is given', async () => {
  const oldDeno = globalThis.Deno;
  globalThis.Deno = { env: { get: () => undefined } };
  try {
    const { createFooterHtml } = await import('../functions/_shared/gotenberg-client.ts');
    const html = createFooterHtml('A&B <script>fetch("http://meta:8080")</script>', '<img src=x onerror=1>', `"7'`);
    assert.ok(!html.includes('<script>') && !html.includes('<img'), 'no markup from a value reaches the page');
    assert.ok(html.includes('A&amp;B &lt;script&gt;fetch(&quot;http://meta:8080&quot;)&lt;/script&gt;'));
    assert.ok(html.includes('&lt;img src=x onerror=1&gt; #&quot;7&#39;'));
    // Page numbers come from Chromium's own classes, not from script.
    assert.ok(html.includes('<span class="pageNumber"></span>') && html.includes('<span class="totalPages"></span>'));
    assert.ok(createFooterHtml('My Warehouse', 'Sample', '123456').includes('<div class="footer-left">Sample #123456</div>'));
  } finally { globalThis.Deno = oldDeno; }
});
