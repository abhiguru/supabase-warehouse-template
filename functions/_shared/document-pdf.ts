import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { validateUserAccess, createAuthErrorResponse } from './auth-helpers.ts';
import { corsHeaders, handleCors } from './cors.ts';
import { htmlToPdf } from './gotenberg-client.ts';
import { documentHtml } from './document-html.ts';
import { publicBaseUrl } from './public-url.ts';

type Kind = 'grn' | 'dispatch' | 'invoice' | 'stock';
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

export const documentPdf = (kind: Kind) => async (req: Request): Promise<Response> => {
  const cors = handleCors(req);
  if (cors) return cors;
  try {
    if (req.method !== 'POST') throw { status: 405, message: 'POST required' };
    await validateUserAccess(req);
    const text = await req.text();
    if (text.length > 4096) throw { status: 400, message: 'Request too large' };
    let body;
    try { body = JSON.parse(text); } catch { throw { status: 400, message: 'Invalid JSON' }; }
    if (!body || Array.isArray(body)) throw { status: 400, message: 'Invalid document request' };
    const internal = Deno.env.get('SUPABASE_URL')!;
    const publicUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    // Every business-data read uses the caller's token and row-level security.
    const reader = createClient(internal, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization')! } },
      auth: { autoRefreshToken: false, persistSession: false },
    });
    let header; let details; let number; let date; let columns; let rows;
    if (kind === 'stock') {
      if (typeof body.customer_id !== 'string' || !uuid.test(body.customer_id)) throw { status: 400, message: 'customer_id must be a UUID' };
      const customer = await reader.from('customers').select('id,name').eq('id',body.customer_id).single();
      if (customer.error || !customer.data) throw { status: 404, message: 'Customer unavailable' };
      header = { ...customer.data, customer_name: customer.data.name };
      details = await reader.from('goodsreceived_trl').select('item_name,packaging,stock,rack,package_mark,goodsreceived!inner(gr_no,customer_id,deleted_at)',{count:'exact'})
        .eq('goodsreceived.customer_id',body.customer_id).is('goodsreceived.deleted_at',null).gt('stock',0).limit(1001);
      columns = ['Item','Packaging','Stock','Rack','Mark'];
      rows = details.data?.map(line => [line.item_name,line.packaging,line.stock,line.rack,line.package_mark]);
      number = 'Current stock'; date = new Date().toISOString();
    } else {
      const value = kind === 'grn' ? body.gr_no : kind === 'dispatch' ? body.disp_no : body.inv_no;
      if ((typeof value !== 'string' && typeof value !== 'number') || !/^[A-Za-z0-9-]{1,20}$/.test(String(value))) throw { status: 400, message: 'Invalid document number' };
      const table = kind === 'grn' ? 'goodsreceived' : kind;
      const key = kind === 'grn' ? 'gr_no' : kind === 'dispatch' ? 'disp_no' : 'inv_no';
      let query = reader.from(table).select('*').eq(key,value).is('deleted_at',null);
      if (kind === 'invoice') {
        if (!Number.isInteger(Number(body.fin_year)) || Number(body.fin_year)<2000 || Number(body.fin_year)>9999) throw { status: 400, message: 'Invalid financial year' };
        query = query.eq('inv_fin_year',body.fin_year);
      }
      const result = await query.single();
      if (result.error || !result.data) throw { status: 404, message: 'Document unavailable' };
      header = result.data; number = String(value); date = header.date || header.disp_date || header.inv_date;
      if (kind === 'grn') {
        details = await reader.from('goodsreceived_trl').select('item_name,packaging,qty,stock,weight,rack,package_mark',{count:'exact'}).eq('gr_id',header.id).limit(1001);
        columns = ['Item','Packaging','Quantity','Stock','Weight','Rack','Mark'];
        rows = details.data?.map(line => [line.item_name,line.packaging,line.qty,line.stock,line.weight,line.rack,line.package_mark]);
      } else if (kind === 'dispatch') {
        details = await reader.from('dispatch_trl').select('disp_qty,goodsreceived_trl(item_name,packaging,package_mark)',{count:'exact'}).eq('disp_id',header.id).limit(1001);
        columns = ['Item','Packaging','Quantity','Mark'];
        rows = details.data?.map(line => {
          const item = Array.isArray(line.goodsreceived_trl) ? line.goodsreceived_trl[0] : line.goodsreceived_trl;
          return [item?.item_name,item?.packaging,line.disp_qty,item?.package_mark];
        });
      } else {
        details = await reader.from('invoice_trl').select('duration,no_of_days,labour_rate,charge,tax,dispatch_trl(disp_qty,goodsreceived_trl(item_name))',{count:'exact'}).eq('invoice_id',header.id).limit(1001);
        columns = ['Item','Quantity','Duration','Days','Labour rate','Charge','Tax'];
        rows = details.data?.map(line => {
          const dispatch = Array.isArray(line.dispatch_trl) ? line.dispatch_trl[0] : line.dispatch_trl;
          const item = Array.isArray(dispatch?.goodsreceived_trl) ? dispatch.goodsreceived_trl[0] : dispatch?.goodsreceived_trl;
          return [item?.item_name,dispatch?.disp_qty,line.duration,line.no_of_days,line.labour_rate,line.charge,line.tax];
        });
      }
    }
    if (details.error || !rows) throw { status: 503, message: 'Document items unavailable' };
    if (rows.length > 1000 || (details.count || 0) > 1000) throw { status: 400, message: 'Document exceeds the starter limit of 1000 rows' };
    const metadata: Record<string,unknown> = { Number: number, Date: date, Customer: header.customer_name };
    if (kind === 'invoice') Object.assign(metadata, { 'Financial year': header.inv_fin_year, Labour: header.labour, Tax: header.tax_amount, Discount: header.discount, Total: header.total });
    const html = documentHtml(kind.toUpperCase(),Deno.env.get('COMPANY_NAME') || 'Warehouse Manager',metadata,columns,rows);
    const pdf = await htmlToPdf(html);
    // Only the upload uses server authority, after all document reads were authorized.
    const writer = createClient(internal,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { autoRefreshToken:false,persistSession:false } });
    const path = `${kind}/${header.id}/${crypto.randomUUID()}.pdf`;
    const upload = await writer.storage.from('documents').upload(path,pdf,{ contentType:'application/pdf',upsert:false });
    if (upload.error) throw { status:503,message:'Document storage unavailable' };
    const signed = await writer.storage.from('documents').createSignedUrl(path,3600);
    if (signed.error || !signed.data) throw { status:503,message:'Document link unavailable' };
    const signedUrl = new URL(signed.data.signedUrl);
    return new Response(JSON.stringify({ success:true,pdf_url:publicUrl+signedUrl.pathname+signedUrl.search,expires_in:3600,
      document:{type:kind,number,date,customer:header.customer_name,items_count:rows.length} }), {
      headers:{...corsHeaders,'Content-Type':'application/json','Cache-Control':'no-store'},
    });
  } catch(error) { return createAuthErrorResponse(error,corsHeaders); }
};
