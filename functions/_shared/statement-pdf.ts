// generate-statement-pdf: one customer's statement as an English PDF (WH-155, migration 176).
//
// The figures are get_customer_statement's, called with the caller's own token, so warehouse_security.authorize_rpc decides access
// exactly as on the screen (administrators, supervisors, and a customer account for its own customers; staff are refused). Nothing is
// worked out here: every amount is printed as the server answered it. The server key is used only after that read, for the warehouse
// name and the private upload. The answer has the shape of the other PDFs: { success, pdf_url, expires_in, document }.
import { restClient } from './supabase-rest.ts';
import { validateUserAccess, createAuthErrorResponse, requestId } from './auth-helpers.ts';
import { securityHeaders } from './security-headers.ts';
import { createFooterHtml, renderDocumentPdf } from './pdf-renderer-client.ts';
import { escapeHtml } from './document-html.ts';
import { documentRequestBody } from './request-body.ts';
import { publicBaseUrl } from './public-url.ts';
import { formatCell } from './report-definitions.ts';
import { estimatePages, MAX_PDF_PAGES, SOLO_PDF_PAGES } from './document-pages.ts';

const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

interface StatementLot { item_name?: string; packaging?: string | null; bags?: number; has_rate?: boolean; amount?: number | string | null }
interface StatementLeft { gr_no?: string; bags?: number; amount?: number | string }
interface StatementStore { gr_no?: string; grn_date?: string; days_in_store?: number; bags?: number; amount?: number | string; lots?: StatementLot[] | null }
interface StatementInvoice {
  invoice_label?: string; inv_no?: number; inv_date?: string; total?: number | string | null;
  payment_status?: string | null; due_amount?: number | string | null;
}
export interface Statement {
  as_of: string;
  customer: { id: string; name: string; active?: boolean };
  record_payments: boolean;
  figures: { invoices_amount: number | string; not_invoiced_left: number | string; not_invoiced_in_store: number | string };
  lots_without_rate: number;
  left: StatementLeft[] | null;
  in_store: StatementStore[] | null;
  invoices: StatementInvoice[] | null;
}

const money = (value: unknown) => {
  const text = formatCell('money', value, 'en');
  return text ? `Rs ${text}` : '';
};
const day = (value: unknown) => formatCell('date', value, 'en');
const bags = (value: unknown) => formatCell('number', value, 'en');

/** The moment of the read on India's clock: 11-11-2026 14:05. */
export function asOfText(value: string): string {
  const moment = new Date(value);
  if (Number.isNaN(moment.getTime())) return value;
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(moment).map(part => [part.type, part.value]));
  return `${parts.day}-${parts.month}-${parts.year} ${parts.hour}:${parts.minute}`;
}

const STATUS: Record<string, string> = { due: 'Due', part_paid: 'Part paid', paid: 'Paid' };

/** The rows the statement prints, for the page estimate and the HTML. */
export function statementTables(statement: Statement) {
  const left = (statement.left ?? []).map(row => [`GRN ${row.gr_no ?? ''}`, bags(row.bags), money(row.amount)]);
  const store: string[][] = [];
  for (const row of statement.in_store ?? []) {
    store.push([`GRN ${row.gr_no ?? ''}`, day(row.grn_date), `${bags(row.days_in_store)} days in store`, bags(row.bags), money(row.amount)]);
    for (const lot of row.lots ?? []) {
      store.push([`  ${lot.item_name ?? ''}${lot.packaging ? ` (${lot.packaging})` : ''}`, '', '', bags(lot.bags),
        lot.has_rate ? money(lot.amount) : 'No rate yet']);
    }
  }
  const invoices = (statement.invoices ?? []).map(row => {
    const cells = [`Invoice ${row.invoice_label ?? String(row.inv_no ?? '')}`, day(row.inv_date), money(row.total)];
    if (statement.record_payments) cells.push(STATUS[String(row.payment_status ?? '')] ?? '', money(row.due_amount));
    return cells;
  });
  return { left, store, invoices };
}

export function statementHtml(statement: Statement, company: string): string {
  const { left, store, invoices } = statementTables(statement);
  const table = (columns: { label: string; numeric: boolean }[], rows: string[][], empty: string) => rows.length === 0
    ? `<p class="empty">${escapeHtml(empty)}</p>`
    : `<table><thead><tr>${columns.map(c => `<th${c.numeric ? ' class="num"' : ''}>${escapeHtml(c.label)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(row => `<tr${row[0].startsWith('  ') ? ' class="lot"' : ''}>${row.map((cell, index) =>
      `<td${columns[index]?.numeric ? ' class="num"' : ''}>${escapeHtml(cell.trimStart())}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
  const figures: [string, string][] = [
    [statement.record_payments ? 'Due on invoices' : 'Invoiced', money(statement.figures.invoices_amount)],
    ['Not yet invoiced: goods that have left', money(statement.figures.not_invoiced_left)],
    ['Not yet invoiced: goods in store (estimate)', money(statement.figures.not_invoiced_in_store)],
  ];
  const invoiceColumns = [{ label: 'Invoice', numeric: false }, { label: 'Date', numeric: false }, { label: 'Total', numeric: true }];
  if (statement.record_payments) invoiceColumns.push({ label: 'Status', numeric: false }, { label: 'Due', numeric: true });
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{font:12px 'Liberation Sans','Noto Sans Gujarati',sans-serif;color:#18212f}h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:0 0 4px}
    h3{font-size:14px;margin:20px 0 6px}.meta{margin:0 0 12px}
    .figures{border:1px solid #cfd6de;border-radius:4px;padding:8px 12px;margin:0 0 8px;break-inside:avoid}
    .figure{display:flex;justify-content:space-between;gap:16px;padding:3px 0}.figure dd{margin:0;font-weight:bold;font-variant-numeric:tabular-nums;white-space:nowrap}.figure dt{margin:0}
    table{border-collapse:collapse;width:100%}th,td{padding:6px 8px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}th{background:#edf1f5}
    thead{display:table-header-group}.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}tr{break-inside:avoid}
    tr.lot td{color:#444;font-size:11px}tr.lot td:first-child{padding-left:24px}.note{color:#555}.warn{color:#8a4b00}.empty{color:#555}</style>
    </head><body><h1>${escapeHtml(company)}</h1><h2>Statement</h2>
    <p class="meta"><strong>${escapeHtml(statement.customer.name)}</strong>${statement.customer.active === false ? ' (Deactivated)' : ''}<br>As of ${escapeHtml(asOfText(statement.as_of))}</p>
    <dl class="figures">${figures.map(([key, value]) => `<div class="figure"><dt>${escapeHtml(key)}</dt><dd>${escapeHtml(value)}</dd></div>`).join('')}</dl>
    <p class="note">Estimate if the goods left today. The invoice may differ.</p>
    ${statement.lots_without_rate > 0 ? `<p class="warn">${escapeHtml(bags(statement.lots_without_rate))} lots have no rate and are not counted.</p>` : ''}
    <h3>Not yet invoiced: goods that have left</h3>
    ${table([{ label: 'GRN', numeric: false }, { label: 'Bags', numeric: true }, { label: 'Amount', numeric: true }], left, 'None.')}
    <h3>Stock in store</h3>
    ${table([{ label: 'GRN / item', numeric: false }, { label: 'Received', numeric: false }, { label: 'Age', numeric: false },
             { label: 'Bags', numeric: true }, { label: 'Estimate', numeric: true }], store, 'None.')}
    <h3>Invoices</h3>
    ${table(invoiceColumns, invoices, 'None.')}
    </body></html>`;
}

export async function statementPdf(req: Request): Promise<Response> {
  try {
    if (req.method !== 'POST') throw { status: 405, message: 'POST required' };
    await validateUserAccess(req);
    const body = await documentRequestBody(req) as Record<string, unknown>;
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw { status: 400, message: 'Invalid document request' };
    if (typeof body.customer_id !== 'string' || !uuid.test(body.customer_id)) throw { status: 400, message: 'customer_id must be a UUID' };
    const internal = Deno.env.get('SUPABASE_URL')!;
    const publicUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    // The business read uses the caller's token: the RPC guard decides access.
    const reader = restClient(internal, Deno.env.get('SUPABASE_ANON_KEY')!, { authorization: req.headers.get('Authorization')! });
    const answer = await reader.rpc('get_customer_statement', { p_customer_id: body.customer_id });
    if (answer.error) {
      if (answer.error.code === '42501') throw { status: 403, message: 'Statement not available to this account' };
      throw { status: 503, message: 'Statement data unavailable' };
    }
    if (answer.data?.success !== true) {
      if (answer.data?.error === 'Customer not found') throw { status: 404, message: 'Customer unavailable' };
      throw { status: 503, message: 'Statement data unavailable' };
    }
    const statement = answer.data as Statement;
    const { left, store, invoices } = statementTables(statement);
    const pages = estimatePages([...left, ...store, ...invoices]);
    if (pages > MAX_PDF_PAGES) throw { status: 400, message: `Document is too long to print (about ${pages} pages; the limit is ${MAX_PDF_PAGES})` };

    // Installation and supported administration use the same company setting.
    const writer = restClient(internal, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const company = await writer.from('system_settings').select('value').eq('key', 'app_name').single();
    if (company.error || typeof company.data?.value !== 'string' || !company.data.value.trim()) {
      throw { status: 503, message: 'Warehouse branding unavailable' };
    }
    const html = statementHtml(statement, company.data.value);
    const pdf = await renderDocumentPdf(html, { solo: pages > SOLO_PDF_PAGES, requestId: requestId(req),
      footerHtml: createFooterHtml(company.data.value, 'Statement', '', `As of ${asOfText(statement.as_of)}`) });
    // Upload uses server authority only after the statement read was authorized.
    const path = `statement/${statement.customer.id}/${crypto.randomUUID()}.pdf`;
    const upload = await writer.storage.from('documents').upload(path, pdf, { contentType: 'application/pdf', upsert: false });
    if (upload.error) throw { status: 503, message: 'Document storage unavailable' };
    const signed = await writer.storage.from('documents').createSignedUrl(path, 3600);
    if (signed.error || !signed.data) throw { status: 503, message: 'Document link unavailable' };
    const signedUrl = new URL(signed.data.signedUrl);
    return new Response(JSON.stringify({ success: true, pdf_url: publicUrl + signedUrl.pathname + signedUrl.search, expires_in: 3600,
      document: { type: 'statement', customer: statement.customer.name, as_of: statement.as_of } }), {
      headers: { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  } catch (error) { return createAuthErrorResponse(error, securityHeaders, req); }
}
