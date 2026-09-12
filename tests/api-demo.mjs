// Mutates only an explicitly configured local demo, after matching its generated anon key.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const envText=readFileSync(new URL('../docker/.env',import.meta.url),'utf8');
const env=key=>envText.match(new RegExp(`^${key}=([^#\\r\\n]*)`,'m'))?.[1].trim();
assert.equal(env('AUTH_MODE'),'demo'); assert.equal(env('BIND_ADDRESS'),'127.0.0.1');
const base=`http://127.0.0.1:${env('KONG_HTTP_PORT')}`;
const anon=env('ANON_KEY');
const configResponse=await fetch(`${base}/functions/v1/get-public-config`,{signal:AbortSignal.timeout(30000)});
assert.equal(configResponse.status,200,'public configuration');
const config=await configResponse.json();
// Boolean comparison prevents assertion errors from printing credential values.
assert.ok(config.data?.anonKey===anon,'Must match THIS demo installation before any writes');
assert.equal(config.success,true);

async function api(path,token=anon,body,method=body===undefined?'GET':'POST') {
  const response=await fetch(`${base}${path}`,{method,headers:{apikey:anon,Authorization:`Bearer ${token}`,'Content-Type':'application/json'},
    body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(60000)});
  const text=await response.text();
  let data; try {data=JSON.parse(text);} catch {data=null;}
  return {status:response.status,ok:response.ok,data};
}
async function rpc(name,token,args={}) {
  const result=await api(`/rest/v1/rpc/${name}`,token,args);
  assert.ok(result.ok,`${name}: HTTP ${result.status}, ${result.data?.code || ''}`);
  return result.data;
}
function success(data,label) {
  assert.equal(data?.success,true,`${label}: ${typeof data?.error==='string'?data.error:data?.message || 'unsuccessful response'}`);
}
async function login(phone) {
  success(await rpc('send_otp',anon,{p_phone_number:phone}),'send OTP');
  const data=await rpc('verify_otp_or_register',anon,{p_phone_number:phone,p_otp_code:'123456'});
  success(data,'verify OTP'); return data.data.session;
}
const admin=await login('0000000001'); const customer=await login('0000000002');
const adminToken=admin.access_token; const customerToken=customer.access_token;
console.log('Public bootstrap and admin/customer OTP login passed.');
assert.ok(!(await api('/rest/v1/customers')).ok,'anonymous business read denied');
const customerRows=await api('/rest/v1/customers?select=id',customerToken);
assert.equal(customerRows.data.length,1,'customer assignment RLS');
const customerId='22222222-0000-4000-8000-000000000001';
const otherId='22222222-0000-4000-8000-000000000002';
assert.equal(customerRows.data[0].id,customerId);
assert.ok(!(await api('/rest/v1/user_profiles',customerToken,{role:'admin'},'PATCH')).ok,'self-promotion denied');
const denied=await api('/rest/v1/rpc/get_customer_stock_summary',customerToken,{p_customer_uuid:otherId});
assert.ok(!denied.ok || denied.data?.success===false,'cross-customer RPC denied');
assert.equal((await api('/functions/v1/generate-customer-stock-pdf',customerToken,{customer_id:otherId})).status,404);
assert.equal((await api('/functions/v1/generate-customer-stock-pdf',anon,{customer_id:customerId})).status,401);
console.log('Anonymous, role-escalation, cross-customer RPC and PDF denials passed.');

const number='T'+Date.now().toString(36).slice(-7).toUpperCase();
const grn=await rpc('save_grn',adminToken,{p_gr_no:number,p_date:new Date().toISOString(),p_customer_id:customerId,
  p_customer_name:'Example Customer A',p_pricing_mode:'MONTHLY',p_items:[{
    item_id:'33333333-0000-4000-8000-000000000001',item_name:'Example Potatoes',packaging:'Bag',qty:100,weight:10,rack:'DEMO',package_mark:'TEST',
  }]});
success(grn,'create GRN');
const headers=await api(`/rest/v1/goodsreceived?gr_no=eq.${number}&select=id`,adminToken);
assert.equal(headers.data?.length,1,'created GRN visible');
const grnId=headers.data[0].id;
const trailers=await api(`/rest/v1/goodsreceived_trl?gr_id=eq.${grnId}&select=id,stock`,adminToken);
assert.equal(trailers.data[0].stock,100);
const grnItem=trailers.data[0].id;
success(await rpc('get_grn_details',customerToken,{p_grn_id:grnId}),'customer GRN details');
const available=await rpc('get_customer_items_for_order_selection',customerToken,{p_customer_id:customerId,p_grn_no_filter:number});
success(available,'order-item lookup'); assert.equal(available.data.length,1);
const dispatchArgs={p_dispatch_data:{disp_no:number,disp_date:new Date().toISOString(),customer_id:customerId,customer_name:'Example Customer A',
    supervisor_id:'11111111-0000-4000-8000-000000000001',supervisor_name:'Demo Admin'},
  p_dispatch_items:[{gr_trl_id:grnItem,disp_qty:20}],p_generate_invoice:false};
success(await rpc('create_dispatch_with_stock_check',adminToken,dispatchArgs),'create dispatch');
const after=await api(`/rest/v1/goodsreceived_trl?id=eq.${grnItem}&select=stock`,adminToken);
assert.equal(after.data[0].stock,80,'dispatch updates stock exactly once');
const oversell=await rpc('create_dispatch_with_stock_check',adminToken,{...dispatchArgs,p_dispatch_items:[{gr_trl_id:grnItem,disp_qty:999}]});
assert.equal(oversell.success,false,'overselling denied');
const dispatch=await api(`/rest/v1/dispatch?disp_no=eq.${number}&select=id`,adminToken);
const dispatchId=dispatch.data[0].id;
success(await rpc('get_dispatch_details',customerToken,{p_dispatch_id:dispatchId}),'customer dispatch details');
const dispatchItems=await api(`/rest/v1/dispatch_trl?disp_id=eq.${dispatchId}&select=id`,adminToken);
const invoiceNumber=Date.now()%1000000000;
const financialYear=new Date().getUTCFullYear();
success(await rpc('save_invoice',adminToken,{p_invoice_data:{inv_no:invoiceNumber,inv_fin_year:financialYear,
  gr_id:grnId,gr_no:number,customer_id:customerId,customer_name:'Example Customer A',inv_date:new Date().toISOString(),total:100,
  items:[{disp_trl_id:dispatchItems.data[0].id,charge:5,tax:0,labour_rate:0}]}}),'save invoice');
console.log('GRN, customer item lookup, dispatch stock update, oversell denial, and invoice save passed.');

for(const [name,body] of [
  ['generate-grn-pdf',{gr_no:number}],['generate-dispatch-pdf',{disp_no:number}],
  ['generate-invoice-pdf',{inv_no:invoiceNumber,fin_year:financialYear}],['generate-customer-stock-pdf',{customer_id:customerId}],
]) {
  const pdf=await api(`/functions/v1/${name}`,customerToken,body);
  assert.equal(pdf.status,200,`${name}: HTTP ${pdf.status}`); success(pdf.data,name);
  const url=new URL(pdf.data.pdf_url); const configured=new URL(config.data.supabaseUrl);
  assert.equal(url.origin,configured.origin,'public PDF origin');
  const download=await fetch(base+url.pathname+url.search,{signal:AbortSignal.timeout(30000)});
  assert.equal(download.status,200,`${name} signed download`);
  const bytes=new Uint8Array(await download.arrayBuffer());
  assert.equal(new TextDecoder().decode(bytes.slice(0,5)),'%PDF-');
  const privateRead=await api('/storage/v1/object/documents/'+decodeURIComponent(url.pathname.split('/documents/')[1]),customerToken);
  assert.ok(!privateRead.ok,'PDF bucket cannot be read directly without signed capability');
  console.log(`${name}: generated and downloaded valid PDF.`);
}
const renewed=await rpc('refresh_jwt_token',anon,{p_refresh_token:customer.refresh_token}); success(renewed,'refresh');
assert.equal((await rpc('refresh_jwt_token',anon,{p_refresh_token:customer.refresh_token})).success,false,'refresh replay denied');
await rpc('logout_session',anon,{p_refresh_token:renewed.refresh_token});
assert.ok(!(await api('/rest/v1/customers',renewed.access_token)).ok,'logout revokes REST access');
assert.equal((await api('/functions/v1/get-config',renewed.access_token)).status,403,'logout revokes Edge access');
await rpc('logout_session',anon,{p_refresh_token:admin.refresh_token});
console.log('Refresh replay protection and REST/Edge logout revocation passed. Demo fixtures remain available in the new demo only.');
