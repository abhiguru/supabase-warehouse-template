// Bounded ordinary-authentication regression in an explicitly selected fictional
// disposable warehouse. Never imports its fixture or invokes SQL before binding
// ownership, identity, source and the unchanged no-delivery guard are verified.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, lstatSync, realpathSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
const [bindingPath, outputPath] = process.argv.slice(2);
assert.ok(bindingPath && outputPath, 'explicit private binding and output required');
const privatePath = path => {
  assert.equal(realpathSync(path), resolve(path));
  const s=lstatSync(path); assert.ok(!s.isSymbolicLink() && s.uid===process.getuid() && (s.mode&0o077)===0);
  return s;
};
assert.ok(privatePath(bindingPath).isFile());
const c=JSON.parse(readFileSync(bindingPath));
assert.equal(c.mode,'ordinary-staff-document-fixture');
assert.equal(realpathSync(c.backendCheckout),resolve(c.backendCheckout));
assert.equal(process.env.WAREHOUSE_STATE_DIR,c.backendState);
assert.ok(privatePath(c.evidenceRoot).isDirectory());
assert.equal(dirname(resolve(outputPath)),resolve(c.evidenceRoot));
const deadline=Date.parse(c.deadlineUTC);
assert.ok(Number.isFinite(deadline) && deadline>Date.now() && deadline-Date.now()<=600000);
const guard=resolve(c.backendCheckout,'tests/operator-fixture.mjs');
assert.equal(createHash('sha256').update(readFileSync(guard)).digest('hex'),c.fixtureGuardSHA256);
assert.equal(JSON.parse(readFileSync(resolve(c.backendState,'public/instance.json'))).instanceId,c.instanceId);
const source=spawnSync('git',['rev-parse','HEAD'],{cwd:c.backendCheckout,encoding:'utf8',timeout:10000});
assert.equal(source.status,0); assert.equal(source.stdout.trim(),c.backendApplication);
const {operatorFixture}=await import(pathToFileURL(guard));
const {env,base,anon}=operatorFixture();
const checkDeadline=()=>assert.ok(Date.now()<deadline,'fixture deadline reached');
const quote=value=>`'${String(value).replaceAll("'","''")}'`;
const sql=expression=>{
  checkDeadline();
  const q=spawnSync('bash',[resolve(c.backendCheckout,'scripts/compose.sh'),'exec','-T','db','psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],
    {env:process.env,input:`SELECT (${expression})::text;\n`,encoding:'utf8',timeout:30000});
  assert.equal(q.status,0,'fixture SQL failed; sensitive stderr omitted');
  return JSON.parse(q.stdout.trim());
};
async function login(phone,name){
  let challenge=sql(`public.operator_prepare_otp(${quote(phone)})`);
  if(challenge.code==='resend_cooldown'){
    const wait=Date.parse(challenge.retry_at)-Date.now()+1000;
    assert.ok(Number.isFinite(wait)&&wait>0&&wait<=65000);
    await new Promise(resolve=>setTimeout(resolve,wait));
    challenge=sql(`public.operator_prepare_otp(${quote(phone)})`);
  }
  assert.equal(challenge.success,true,'ordinary challenge');
  assert.equal(sql(`public.operator_finish_otp(${quote(challenge.data.request_id)}::uuid,true,'mock-provider-only')`).success,true);
  const verified=sql(`public.operator_verify_otp(${quote(phone)},${quote(challenge.data.otp_code)},${quote(name)})`);
  assert.equal(verified.success,true,'ordinary verification');
  return verified.data;
}
async function api(path,token,body){
  checkDeadline();
  const q=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{apikey:anon,Authorization:`Bearer ${token}`,'Content-Type':'application/json'},
    body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(30000),redirect:'error'});
  return {status:q.status,ok:q.ok,data:await q.json()};
}
const rpc=(name,token,body={})=>api('/rest/v1/rpc/'+name,token,body);
const good=(r,label)=>{assert.ok(r.ok,label+' HTTP '+r.status);assert.equal(r.data?.success,true,label);return r.data;};
const admin=await login('919888888871','Core Demo Administrator');assert.equal(admin.action,'login');
const token=admin.session.access_token;
const customers=await api('/rest/v1/customers?select=id,name',token);assert.equal(customers.status,200);
const a=customers.data.find(x=>x.name==='Backend Test Customer A')?.id;
const b=customers.data.find(x=>x.name==='Backend Test Customer B')?.id;assert.ok(a&&b&&a!==b);
assert.equal(sql("NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE mobile='919888888874')"),true,'fresh reserved staff account required');
assert.equal(sql("NOT EXISTS(SELECT 1 FROM public.goodsreceived WHERE gr_no='SDA01') AND NOT EXISTS(SELECT 1 FROM public.dispatch WHERE disp_no IN ('SDD01','SDD02')) AND NOT EXISTS(SELECT 1 FROM public.invoice WHERE inv_no=20261005)"),true,'fresh fictional document numbers required');
const pending=await login('919888888874','Document Workflow Staff');assert.equal(pending.action,'pending');assert.ok(!pending.session);
const staffId=sql("(SELECT to_jsonb(id) FROM public.user_profiles WHERE mobile='919888888874')");
good(await rpc('operator_review_enrollment',token,{p_user_id:staffId,p_decision:'approved',p_customer_ids:[b]}),'approve fictional staff enrollment');
good(await rpc('update_user_role',token,{p_user_id:staffId,p_new_role:'staff'}),'normal administrator staff role preparation');
const staff=await login('919888888874','Document Workflow Staff');assert.equal(staff.action,'login');assert.equal(staff.user.role,'staff');
const st=staff.session.access_token;
assert.equal(sql(`NOT EXISTS(SELECT 1 FROM public.users_customers_new WHERE user_profile_id=${quote(staffId)}::uuid AND customer_id=${quote(a)}::uuid AND active)`),true,'A is genuinely unassigned to staff');
const item=sql("(SELECT to_jsonb(id) FROM public.items WHERE name='Backend Test Potatoes')");assert.ok(item);
good(await rpc('save_grn',st,{p_gr_no:'SDA01',p_date:'2026-04-01T12:00:00Z',p_customer_id:a,p_customer_name:'Backend Test Customer A',p_pricing_mode:'MONTHLY',p_idempotency_key:'staff-doc-receipt-0505',p_items:[{item_id:item,item_name:'Backend Test Potatoes',packaging:'Bag',qty:10,weight:10}]}),'staff receipt');
const grn=sql("(SELECT to_jsonb(id) FROM public.goodsreceived WHERE gr_no='SDA01')");
const lot=sql(`(SELECT to_jsonb(id) FROM public.goodsreceived_trl WHERE gr_id=${quote(grn)}::uuid)`);
const stock=()=>sql(`(SELECT stock FROM public.goodsreceived_trl WHERE id=${quote(lot)}::uuid)`);
const data={disp_no:'SDD01',disp_date:'2026-05-02T12:00:00Z',customer_id:a,customer_name:'Backend Test Customer A',supervisor_id:admin.user.id,supervisor_name:'Core Demo Administrator'};
const first={p_dispatch_data:data,p_dispatch_items:[{gr_trl_id:lot,disp_qty:3}],p_generate_invoice:false,p_idempotency_key:'staff-doc-partial-0505'};
assert.equal(stock(),10);good(await rpc('create_dispatch_with_stock_check',st,first),'staff partial dispatch');assert.equal(stock(),7);
good(await rpc('create_dispatch_with_stock_check',st,first),'reconciled unchanged retry');assert.equal(stock(),7);
good(await rpc('create_dispatch_with_stock_check',st,{...first,p_dispatch_data:{...data,disp_no:'SDD02'},p_dispatch_items:[{gr_trl_id:lot,disp_qty:7}],p_idempotency_key:'staff-doc-final-0505'}),'staff final dispatch');assert.equal(stock(),0);
good(await rpc('get_dispatch_list',st),'staff dispatch list');
const lines=sql("(SELECT jsonb_agg(jsonb_build_object('disp_trl_id',t.id,'charge',5,'tax',5,'labour_rate',2)) FROM public.dispatch_trl t JOIN public.dispatch d ON d.id=t.disp_id WHERE d.disp_no IN ('SDD01','SDD02'))");assert.equal(lines.length,2);
const preview=good(await rpc('generate_invoice_data_for_grn_with_pricing',st,{p_gr_id:grn,p_duration_mode:'legacy'}),'staff invoice preview');
const saved=good(await rpc('save_invoice',st,{p_invoice_data:{inv_no:20261005,inv_fin_year:2026,gr_id:grn,gr_no:'SDA01',customer_id:a,customer_name:'Backend Test Customer A',inv_date:'2026-05-02T12:00:00Z',total:preview.totals.grand_total,tax_amount:preview.totals.tax,discount:0,duration_mode:'legacy',items:lines}}),'staff invoice save');
good(await rpc('get_invoice_data',st,{p_invoice_id:saved.invoice_id}),'staff invoice read');
assert.equal((await api(`/rest/v1/invoice?id=eq.${saved.invoice_id}&select=id`,st)).data.length,1,'caller-RLS staff invoice read');
assert.equal((await api('/rest/v1/item_storage_prices?select=id',st)).data.length,0,'no direct pricing grant');
const pdfHashes=[];
for(const [kind,body] of [['dispatch',{disp_no:'SDD01'}],['invoice',{inv_no:20261005,fin_year:2026}]]){
 const document=good(await api('/functions/v1/generate-'+kind+'-pdf',st,body),'staff '+kind+' PDF');
 const url=new URL(document.pdf_url);assert.equal(url.origin,'https://backend-core.example.test');
 const download=await fetch(base+url.pathname+url.search,{signal:AbortSignal.timeout(30000),redirect:'error'});assert.equal(download.status,200);
 const bytes=Buffer.from(await download.arrayBuffer());assert.equal(bytes.subarray(0,5).toString(),'%PDF-');assert.ok(bytes.length<52*1024*1024);
 pdfHashes.push({kind,size:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')});
}
const customerB=await login('919888888873','Customer B');assert.equal(customerB.action,'login');
assert.equal((await api('/functions/v1/generate-invoice-pdf',customerB.session.access_token,{inv_no:20261005,fin_year:2026})).status,404,'B denied unassigned staff-created A invoice PDF');
const denied=await rpc('delete_invoice',st,{p_invoice_id:saved.invoice_id});assert.notEqual(denied.data?.success,true,'staff deletion denied');
assert.equal(sql(`(SELECT count(*) FROM public.invoice WHERE id=${quote(saved.invoice_id)}::uuid)`),1,'denial preserves invoice');
const proof={status:'PASS',scope:'fresh fictional staff HTTP dispatch/invoice/PDF regression; no native acceptance',backendApplication:c.backendApplication,instanceId:c.instanceId,staffProfile:staffId,unassignedCustomer:a,grn,lot,invoice:saved.invoice_id,stockSequence:[10,7,7,0],pdfHashes,noExternalProvider:true,noCountersReset:true,successfulRecordsPreserved:true};
writeFileSync(outputPath,JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o400});console.log(JSON.stringify({status:'PASS',scope:proof.scope,pdfCount:pdfHashes.length}));
