import { documentRequestBody } from './request-body.ts';
import { restClient } from './supabase-rest.ts';
import { validateUserAccess, createAuthErrorResponse, requestId } from './auth-helpers.ts';
import { securityHeaders } from './security-headers.ts';
import { renderDocumentPdf } from './pdf-renderer-client.ts';
import { cancelledNotice, documentDate, documentHtml, kgEach, withNotice } from './document-html.ts';
import { headerColumns, invoiceCancelColumns, invoiceDocTypeColumns, invoiceGstLineColumns } from './document-columns.ts';
import { gstColumns, gstDocumentHtml, gstRows, isGstDocType } from './gst-document-html.ts';
import type { GstInvoice } from './gst-document-html.ts';
import { publicBaseUrl } from './public-url.ts';
import { readDocumentLines } from './document-lines.ts';
import { estimatePages, MAX_PDF_PAGES, SOLO_PDF_PAGES } from './document-pages.ts';

type Kind = 'grn' | 'dispatch' | 'invoice' | 'stock';
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

export const documentPdf = (kind: Kind) => async (req: Request): Promise<Response> => {
  try {
    if (req.method !== 'POST') throw { status: 405, message: 'POST required' };
    await validateUserAccess(req);
    const body = await documentRequestBody(req) as Record<string, unknown>;
    if (!body || Array.isArray(body)) throw { status: 400, message: 'Invalid document request' };
    const internal = Deno.env.get('SUPABASE_URL')!;
    const publicUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    // Every business-data read uses the caller's token and row-level security.
    const reader = restClient(internal, Deno.env.get('SUPABASE_ANON_KEY')!, { authorization: req.headers.get('Authorization')! });
    let header; let details; let number; let date; let columns; let rows; let notice: string | undefined;
    let gstInvoice: GstInvoice | undefined;
    if (kind === 'stock') {
      if (typeof body.customer_id !== 'string' || !uuid.test(body.customer_id)) throw { status: 400, message: 'customer_id must be a UUID' };
      const customer = await reader.from('customers').select('id,name').eq('id',body.customer_id).single();
      if (customer.error || !customer.data) throw { status: 404, message: 'Customer unavailable' };
      header = { ...customer.data, customer_name: customer.data.name };
      details = await readDocumentLines(reader,kind,'goodsreceived_trl','item_name,packaging,stock,rack,package_mark,goodsreceived!inner(gr_no,customer_id,deleted_at)',
        query => query.eq('goodsreceived.customer_id',body.customer_id).is('goodsreceived.deleted_at',null).gt('stock',0));
      columns = ['Item','Packaging','Stock','Rack','Mark'];
      rows = details.data?.map(line => [line.item_name,line.packaging,line.stock,line.rack,line.package_mark]);
      number = 'Current stock'; date = new Date().toISOString();
    } else {
      const value = kind === 'grn' ? body.gr_no : kind === 'dispatch' ? body.disp_no : body.inv_no;
      if ((typeof value !== 'string' && typeof value !== 'number') || !/^[A-Za-z0-9-]{1,20}$/.test(String(value))) throw { status: 400, message: 'Invalid document number' };
      const table = kind === 'grn' ? 'goodsreceived' : kind;
      const key = kind === 'grn' ? 'gr_no' : kind === 'dispatch' ? 'disp_no' : 'inv_no';
      let query = reader.from(table).select(headerColumns(kind)).eq(key,value).is('deleted_at',null);
      if (kind === 'invoice') {
        if (!Number.isInteger(Number(body.fin_year)) || Number(body.fin_year)<2000 || Number(body.fin_year)>9999) throw { status: 400, message: 'Invalid financial year' };
        query = query.eq('inv_fin_year',body.fin_year);
      }
      const result = await query.single();
      if (result.error || !result.data) throw { status: 404, message: 'Document unavailable' };
      header = result.data; number = kind === 'invoice' ? `${header.inv_prefix ?? ''}${value}` : String(value); date = header.date || header.disp_date || header.inv_date;
      if (kind === 'invoice') {
        // Only a cancelled invoice gets the line; an invoice that is not cancelled prints as it always did.
        const cancel = await reader.from('invoice').select(invoiceCancelColumns).eq('id',header.id).single();
        if (cancel.error) throw { status: 503, message: 'Document status unavailable' };
        if (cancel.data?.cancelled_at) notice = cancelledNotice(cancel.data.cancelled_at, cancel.data.cancel_reason);
        // Migration 173: a GST document (any type but 'invoice') prints the GST layout from what the save stored; an 'invoice' prints as before.
        const type = await reader.from('invoice').select(invoiceDocTypeColumns).eq('id',header.id).single();
        if (type.error) throw { status: 503, message: 'Document status unavailable' };
        if (isGstDocType(type.data?.doc_type)) {
          const detail = await reader.rpc('get_invoice_detail',{ p_invoice_id: header.id });
          if (detail.error || detail.data?.success !== true || !detail.data?.invoice?.gst) throw { status: 503, message: 'Document details unavailable' };
          gstInvoice = detail.data.invoice as GstInvoice;
        }
      }
      if (kind === 'grn') {
        details = await readDocumentLines(reader,kind,'goodsreceived_trl','item_name,packaging,qty,stock,weight,rack,package_mark',query => query.eq('gr_id',header.id));
        columns = ['Item','Packaging','Quantity','Stock','Kg each','Rack','Mark'];
        rows = details.data?.map(line => [line.item_name,line.packaging,line.qty,line.stock,kgEach(line.weight),line.rack,line.package_mark]);
      } else if (kind === 'dispatch') {
        details = await readDocumentLines(reader,kind,'dispatch_trl','disp_qty,goodsreceived_trl(item_name,packaging,package_mark)',query => query.eq('disp_id',header.id));
        columns = ['Item','Packaging','Quantity','Mark'];
        rows = details.data?.map(line => {
          const item = Array.isArray(line.goodsreceived_trl) ? line.goodsreceived_trl[0] : line.goodsreceived_trl;
          return [item?.item_name,item?.packaging,line.disp_qty,item?.package_mark];
        });
      } else if (gstInvoice) {
        const invoice = gstInvoice;
        details = await readDocumentLines(reader,kind,'invoice_trl',invoiceGstLineColumns,query => query.eq('invoice_id',header.id));
        columns = gstColumns(invoice);
        rows = details.data ? gstRows(invoice, details.data) : undefined;
      } else {
        details = await readDocumentLines(reader,kind,'invoice_trl','duration,no_of_days,labour_rate,charge,tax,details_kept_at,kept_item_name,kept_disp_qty,dispatch_trl(disp_qty,goodsreceived_trl(item_name))',query => query.eq('invoice_id',header.id));
        columns = ['Item','Quantity','Duration','Days','Labour rate','Charge','Tax'];
        rows = details.data?.map(line => {
          const dispatch = Array.isArray(line.dispatch_trl) ? line.dispatch_trl[0] : line.dispatch_trl;
          const item = Array.isArray(dispatch?.goodsreceived_trl) ? dispatch.goodsreceived_trl[0] : dispatch?.goodsreceived_trl;
          // Migration 143: a cancelled invoice's line prints the details it kept at cancel; a line emptied before that says so.
          if (line.details_kept_at) return [line.kept_item_name,line.kept_disp_qty,line.duration,line.no_of_days,line.labour_rate,line.charge,line.tax];
          if (!dispatch) return ['Details not available',null,line.duration,line.no_of_days,line.labour_rate,line.charge,line.tax];
          return [item?.item_name,dispatch?.disp_qty,line.duration,line.no_of_days,line.labour_rate,line.charge,line.tax];
        });
      }
    }
    if (details.error || !rows) throw { status: 503, message: 'Document items unavailable' };
    // The renderer's memory, not the number of lines, is the limit: a document of many wrapped rows is as heavy as a longer one of short rows.
    const pages = estimatePages(rows);
    if (pages > MAX_PDF_PAGES) throw { status: 400, message: `Document is too long to print (about ${pages} pages; the limit is ${MAX_PDF_PAGES})` };
    const metadata: Record<string,unknown> = { Number: number, Date: documentDate(date), Customer: header.customer_name };
    if (kind === 'invoice') Object.assign(metadata, { 'Financial year': header.inv_fin_year, Labour: header.labour, Tax: header.tax_amount, Discount: header.discount, Total: header.total });
    // Installation and supported administration use the same company setting.
    // Keep warehouse record reads on the caller's RLS-protected client above.
    const writer = restClient(internal,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const company = await writer.from('system_settings').select('value').eq('key','app_name').single();
    if (company.error || typeof company.data?.value !== 'string' || !company.data.value.trim()) {
      throw { status:503,message:'Warehouse branding unavailable' };
    }
    // The optional letterhead: the router read the file and passed the data URI. Nothing here can fail a PDF; documentHtml
    // ignores a value that is not exactly a JPEG or PNG data URI.
    let html = gstInvoice
      ? gstDocumentHtml({ invoice: gstInvoice, lines: details.data, number, date: documentDate(date), financialYear: header.inv_fin_year,
                          company: company.data.value, letterhead: Deno.env.get('LETTERHEAD_DATA_URI') || undefined })
      : documentHtml(kind.toUpperCase(),company.data.value,metadata,columns,rows,Deno.env.get('LETTERHEAD_DATA_URI') || undefined);
    if (notice) html = withNotice(html,notice);
    const pdf = await renderDocumentPdf(html,{ solo: pages > SOLO_PDF_PAGES, requestId: requestId(req) });
    // Upload uses server authority only after document reads were authorized.
    const path = `${kind}/${header.id}/${crypto.randomUUID()}.pdf`;
    const upload = await writer.storage.from('documents').upload(path,pdf,{ contentType:'application/pdf',upsert:false });
    if (upload.error) throw { status:503,message:'Document storage unavailable' };
    const signed = await writer.storage.from('documents').createSignedUrl(path,3600);
    if (signed.error || !signed.data) throw { status:503,message:'Document link unavailable' };
    const signedUrl = new URL(signed.data.signedUrl);
    return new Response(JSON.stringify({ success:true,pdf_url:publicUrl+signedUrl.pathname+signedUrl.search,expires_in:3600,
      document:{type:kind,number,date,customer:header.customer_name,items_count:rows.length} }), {
      headers:{...securityHeaders,'Content-Type':'application/json','Cache-Control':'no-store'},
    });
  } catch(error) { return createAuthErrorResponse(error,securityHeaders,req); }
};
