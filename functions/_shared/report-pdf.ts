// generate-report-pdf: one report screen of the app as a PDF.
//
// The data comes from the report's existing RPC, called with the caller's own
// token, so warehouse_security.authorize_rpc and each function's customer
// checks apply exactly as on the screen. The server key is used only after
// that, to read the warehouse name and to store the file in the private
// documents bucket. The answer has the shape of the document PDFs
// (document-pdf.ts): { success, pdf_url, expires_in, document }.
import { createClient } from '../vendor/supabase-js.mjs';
import { validateUserAccess, createAuthErrorResponse } from './auth-helpers.ts';
import { corsHeaders, handleCors } from './cors.ts';
import { htmlToPdf, createFooterHtml } from './gotenberg-client.ts';
import { reportHtml } from './document-html.ts';
import { documentRequestBody } from './request-body.ts';
import { publicBaseUrl } from './public-url.ts';
import { parseReportRequest } from './report-request.ts';
import { buildReport, formatCell, reportFilters, reportLevel, reportRefusal, unwrapReportBody } from './report-definitions.ts';
import { label } from './report-labels.ts';

export async function reportPdf(req: Request): Promise<Response> {
  const cors = handleCors(req);
  if (cors) return cors;
  try {
    if (req.method !== 'POST') throw { status: 405, message: 'POST required' };
    await validateUserAccess(req);
    const request = parseReportRequest(await documentRequestBody(req));
    const internal = Deno.env.get('SUPABASE_URL')!;
    const publicUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    // Every business-data read uses the caller's token and row-level security.
    const reader = createClient(internal, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization')! } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const call = reportLevel(request).rpc(request);
    const answer = await reader.rpc(call.name, call.args);
    if (answer.error) {
      if (answer.error.code === '42501') throw { status: 403, message: 'Report not available to this account' };
      throw { status: 503, message: 'Report data unavailable' };
    }
    const refusal = reportRefusal(answer.data);
    if (refusal) throw refusal;
    const body = unwrapReportBody(answer.data);
    if (!body) throw { status: 503, message: 'Report data unavailable' };

    // After the RPC: a customer account asking for a customer that is not its
    // own was refused above (403); an id no one has is answered here.
    let customerName: string | null = null;
    if (request.customerId) {
      const customer = await reader.from('customers').select('id,name').eq('id', request.customerId).maybeSingle();
      if (customer.error || !customer.data) throw { status: 404, message: 'Customer unavailable' };
      customerName = String(customer.data.name ?? '');
    }

    const report = buildReport(request, body);
    const lang = request.lang;
    const now = new Date().toISOString();
    const filters = reportFilters(request, customerName, report, now);
    const note = report.truncated
      ? label(lang, 'showing', { shown: formatCell('number', report.rows.length, lang), total: formatCell('number', report.rowsTotal, lang) })
      : '';

    // Installation and supported administration use the same company setting.
    const writer = createClient(internal, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { autoRefreshToken: false, persistSession: false } });
    const company = await writer.from('system_settings').select('value').eq('key', 'app_name').single();
    if (company.error || typeof company.data?.value !== 'string' || !company.data.value.trim()) {
      throw { status: 503, message: 'Warehouse branding unavailable' };
    }
    const html = reportHtml({
      title: report.title, company: company.data.value, lang,
      filters,
      summaryTitle: label(lang, 'summary'), summary: report.summary,
      columns: report.columns, rows: report.rows, totals: report.totals,
      note, empty: report.empty,
    });
    const pdf = await htmlToPdf(html, { footerHtml: createFooterHtml(company.data.value, report.title, '', note) });
    // Upload uses server authority only after the report read was authorized.
    const path = `report/${request.report}/${request.customerId ?? 'all'}/${crypto.randomUUID()}.pdf`;
    const upload = await writer.storage.from('documents').upload(path, pdf, { contentType: 'application/pdf', upsert: false });
    if (upload.error) throw { status: 503, message: 'Document storage unavailable' };
    const signed = await writer.storage.from('documents').createSignedUrl(path, 3600);
    if (signed.error || !signed.data) throw { status: 503, message: 'Document link unavailable' };
    const signedUrl = new URL(signed.data.signedUrl);
    const document: Record<string, unknown> = { type: 'report', report: request.report };
    if (customerName !== null) document.customer = customerName;
    if (request.from && request.to) Object.assign(document, { from: request.from, to: request.to });
    if (request.status) document.status = request.status;
    Object.assign(document, {
      rows_count: report.rows.length, rows_total: report.rowsTotal, truncated: report.truncated,
      sort: { field: report.sort.field, order: report.sort.order },
    });
    return new Response(JSON.stringify({ success: true, pdf_url: publicUrl + signedUrl.pathname + signedUrl.search, expires_in: 3600, document }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  } catch (error) { return createAuthErrorResponse(error, corsHeaders); }
}
