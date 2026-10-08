// Edge Function: generate-sample-pdf
// Demonstrates Gotenberg HTML-to-PDF conversion
// POST with optional { title, items: [{ name, quantity, rate }] }

import { serve } from "https://deno.land/std@0.192.0/http/server.ts"
import { corsHeaders, handleCors } from '../_shared/cors.ts'
import { htmlToPdf, createFooterHtml } from '../_shared/gotenberg-client.ts'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'

const escapeHtml = (value: unknown) => String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]!));

serve(async (req) => {
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: corsHeaders });

  try {
    await validatePrintAccess(req);
    const { title = 'Sample Document', items = [] } = await req.json().catch(() => ({}));
    if (typeof title !== 'string' || title.length > 200 || !Array.isArray(items) || items.length > 500 ||
        items.some(item => !item || typeof item.name !== 'string' || item.name.length > 500 ||
          !Number.isFinite(item.quantity) || item.quantity <= 0 || !Number.isFinite(item.rate) || item.rate < 0)) {
      throw { status: 400, message: 'Invalid sample document inputs' };
    }

    const defaultItems = [
      { name: 'Cold Storage Rental - Room A', quantity: 100, rate: 5.00 },
      { name: 'Loading/Unloading Charges', quantity: 50, rate: 10.00 },
      { name: 'Insurance Premium', quantity: 1, rate: 250.00 },
    ];

    const displayItems = items.length > 0 ? items : defaultItems;
    const total = displayItems.reduce((sum: number, item: any) =>
      sum + item.quantity * item.rate, 0
    );

    const html = `<!DOCTYPE html>
<html>
<head>
  <style>
    body { font-family: 'Helvetica Neue', Arial, sans-serif; margin: 0; padding: 20px; color: #333; }
    .header { background: #1a1a2e; color: white; padding: 24px; margin: -20px -20px 24px; }
    .header h1 { margin: 0; font-size: 24px; font-weight: 600; }
    .header p { margin: 5px 0 0; opacity: 0.8; font-size: 13px; }
    .info-grid { display: flex; gap: 40px; margin-bottom: 24px; }
    .info-block h3 { margin: 0 0 6px; font-size: 11px; text-transform: uppercase; color: #888; letter-spacing: 0.5px; }
    .info-block p { margin: 0; font-size: 14px; }
    table { width: 100%; border-collapse: collapse; margin-top: 16px; }
    th { background: #f8f9fa; padding: 10px 12px; text-align: left; border-bottom: 2px solid #dee2e6; font-size: 12px; text-transform: uppercase; color: #666; }
    td { padding: 10px 12px; border-bottom: 1px solid #eee; font-size: 14px; }
    tr:hover { background: #fafafa; }
    .text-right { text-align: right; }
    .total-row { font-weight: 700; background: #f8f9fa; }
    .total-row td { border-top: 2px solid #333; border-bottom: none; font-size: 15px; }
    .meta { color: #999; font-size: 11px; margin-top: 40px; border-top: 1px solid #eee; padding-top: 12px; }
  </style>
</head>
<body>
  <div class="header">
    <h1>${escapeHtml(title)}</h1>
    <p>Generated on ${new Date().toLocaleDateString('en-IN', { year: 'numeric', month: 'long', day: 'numeric' })}</p>
  </div>

  <div class="info-grid">
    <div class="info-block">
      <h3>Document Type</h3>
      <p>Sample Invoice</p>
    </div>
    <div class="info-block">
      <h3>Document #</h3>
      <p>SAMPLE-${Date.now().toString().slice(-6)}</p>
    </div>
    <div class="info-block">
      <h3>Date</h3>
      <p>${new Date().toLocaleDateString('en-IN')}</p>
    </div>
  </div>

  <table>
    <thead>
      <tr>
        <th>#</th>
        <th>Description</th>
        <th class="text-right">Qty</th>
        <th class="text-right">Rate</th>
        <th class="text-right">Amount</th>
      </tr>
    </thead>
    <tbody>
      ${displayItems.map((item: any, i: number) => `
      <tr>
        <td>${i + 1}</td>
        <td>${escapeHtml(item.name || 'Item')}</td>
        <td class="text-right">${item.quantity}</td>
        <td class="text-right">${item.rate.toFixed(2)}</td>
        <td class="text-right">${(item.quantity * item.rate).toFixed(2)}</td>
      </tr>`).join('')}
      <tr class="total-row">
        <td colspan="4">Total</td>
        <td class="text-right">${total.toFixed(2)}</td>
      </tr>
    </tbody>
  </table>

  <div class="meta">
    <p>This is a sample PDF generated via Gotenberg HTML-to-PDF conversion.</p>
    <p>Document ID: ${crypto.randomUUID()}</p>
  </div>
</body>
</html>`;

    const footerHtml = createFooterHtml('My Warehouse', 'Sample', Date.now().toString().slice(-6));

    const pdfBytes = await htmlToPdf(html, { footerHtml, marginBottom: 1.0 });

    return new Response(pdfBytes, {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/pdf',
        'Content-Disposition': `inline; filename="sample-${Date.now()}.pdf"`,
      },
    });
  } catch (error) {
    console.error('generate-sample-pdf ERROR:', error);
    return createAuthErrorResponse(error, corsHeaders);
  }
});
