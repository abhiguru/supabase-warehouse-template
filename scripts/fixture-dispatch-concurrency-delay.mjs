// Disabled-by-default matcher for one declared fictional concurrency request.
// Request data is inspected in memory only; this module never logs or sends it.
import assert from 'node:assert/strict';
export function dispatchConcurrencyDelayMilliseconds(req,target,body,config={milliseconds:0}){
 assert.ok(Number.isInteger(config.milliseconds)&&(config.milliseconds===0||config.milliseconds>=500&&config.milliseconds<=5000),'BOUNDED_CONCURRENCY_DELAY_REQUIRED');
 if(config.milliseconds===0)return 0;
 assert.equal(config.scope,'isolated-fictional-native-dispatch-concurrency');assert.equal(config.record,'FXQ994');assert.match(config.lotId,/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/);
 if(!(req.method==='POST'&&target.protocol==='http:'&&target.hostname==='127.0.0.1'&&target.port==='18080'&&target.pathname==='/rest/v1/rpc/create_dispatch_with_stock_check'&&target.search===''&&req.headers.host==='backend-core.example.test'&&typeof req.headers.authorization==='string'&&req.headers.authorization.length>0))return 0;
 if(!body||typeof body!=='object'||Array.isArray(body))return 0;
 const h=body.p_dispatch_data,items=body.p_dispatch_items;
 if(!h||h.disp_no!==config.record||h.customer_id!=='a823809c-bdb6-11f1-b1be-47a66d90b06d'||h.supervisor_id!=='947136fa-997b-4a83-819d-1b8bd3ecba68'||h.source_order_id!==null)return 0;
 if(!Array.isArray(items)||items.length!==1||items[0]?.gr_trl_id!==config.lotId||items[0]?.disp_qty!==2)return 0;
 if(body.p_generate_invoice!==true||body.p_retry_count!==0||typeof body.p_idempotency_key!=='string'||body.p_idempotency_key.length<16||body.p_idempotency_key.length>200)return 0;
 return config.milliseconds;
}

export function bufferConcurrencyRequest(req,target,config,{forward,fail,observe=()=>{}}){
 // Validate optional configuration before attaching any request handlers.
 dispatchConcurrencyDelayMilliseconds(req,target,null,config);
 if(!config.milliseconds||req.method!=='POST'||target.protocol!=='http:'||target.hostname!=='127.0.0.1'||target.port!=='18080'||target.pathname!=='/rest/v1/rpc/create_dispatch_with_stock_check'||target.search!==''||req.headers.host!=='backend-core.example.test'||typeof req.headers.authorization!=='string'||!req.headers.authorization)return null;
 let chunks=[],bytes=0,timer,stopped=false;
 const cancel=()=>{stopped=true;clearTimeout(timer);chunks=[];req.removeListener('data',data);req.removeListener('end',end);};
 const data=chunk=>{if(stopped)return;bytes+=chunk.length;if(bytes>65536){cancel();fail('concurrency-body-bound',413);req.resume();return;}chunks.push(Buffer.from(chunk));};
 const end=()=>{if(stopped)return;const raw=Buffer.concat(chunks);chunks=[];req.removeListener('data',data);req.removeListener('end',end);let body;try{body=JSON.parse(raw.toString('utf8'));}catch{/* Forward malformed input unchanged for ordinary backend rejection. */}
  const milliseconds=dispatchConcurrencyDelayMilliseconds(req,target,body,config);
  if(!milliseconds){stopped=true;forward(raw);return;}
  try{observe({event:'dispatch-request-delay-start',delayMs:milliseconds,monotonicMs:performance.now()});}catch{/* Observers cannot alter transport. */}
  timer=setTimeout(()=>{if(stopped)return;stopped=true;try{observe({event:'dispatch-request-delay-release',delayMs:milliseconds,monotonicMs:performance.now()});}catch{/* Safe metadata only. */}forward(raw);},milliseconds);
 };
 req.on('data',data);req.on('end',end);return cancel;
}
