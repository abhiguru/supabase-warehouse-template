import test from 'node:test';import assert from 'node:assert/strict';import {Readable} from 'node:stream';
import {ordersReadDelayMilliseconds} from '../scripts/fixture-orders-delay.mjs';
import {delayDiscoveryReply} from '../scripts/fixture-discovery-delay.mjs';
import {serviceSpec} from '../scripts/fixture-service-supervisor.mjs';
const request=()=>({method:'POST',headers:{host:'backend-core.example.test',authorization:'Bearer never-record-this'}}),target=()=>new URL('http://127.0.0.1:18080/rest/v1/rpc/get_orders_list');
test('Orders delay refuses writes, authentication, foreign routes and unbounded settings',()=>{
 assert.equal(ordersReadDelayMilliseconds(request(),target(),3000),3000);
 for(const patch of [{method:'GET'},{headers:{host:'backend-core.example.test'}},{headers:{host:'production.invalid',authorization:'Bearer never-record-this'}}])assert.equal(ordersReadDelayMilliseconds({...request(),...patch},target(),3000),0);
 for(const url of ['http://127.0.0.1:18080/rest/v1/rpc/save_grn','http://127.0.0.1:18080/rest/v1/rpc/create_dispatch_with_stock_check','http://127.0.0.1:18080/rest/v1/rpc/refresh_jwt_token','http://127.0.0.1:18690/rest/v1/rpc/get_orders_list','http://foreign.invalid:18080/rest/v1/rpc/get_orders_list','http://127.0.0.1:18080/rest/v1/rpc/get_orders_list?apikey=private'])assert.equal(ordersReadDelayMilliseconds(request(),new URL(url),3000),0);
 for(const ms of [-1,1,499,5001,Infinity,'3000',3.5])assert.throws(()=>ordersReadDelayMilliseconds(request(),target(),ms));
});
test('delayed Orders bytes remain genuine and observations contain no credentials or payload',async()=>{
 const body=Buffer.from('{"orders":[{"id":"private-order-body"}]}'),response=Readable.from([body]);response.statusCode=200;response.headers={'content-type':'application/json'};const events=[],start=Date.now();
 await new Promise((resolve,reject)=>delayDiscoveryReply(response,{destroyed:false,writeHead:(s,h)=>{assert.equal(s,200);assert.deepEqual(h,response.headers);},end:bytes=>{assert.deepEqual(bytes,body);assert.ok(Date.now()-start>=490);resolve();}},500,()=>reject(Error('unexpected failure')),e=>events.push(e),'orders'));
 assert.deepEqual(events,[{event:'orders-delay-start',status:200,delayMs:500}]);assert.doesNotMatch(JSON.stringify(events),/private-order-body|never-record-this/);
});
test('Orders buffering is bounded and cancellation prevents late delivery',async()=>{
 let written=false;const res={destroyed:false,writeHead:()=>{written=true;},end:()=>{written=true;}};
 await new Promise(resolve=>{const response=Readable.from([Buffer.alloc(65537)]);delayDiscoveryReply(response,res,500,(event,status)=>{assert.equal(event,'orders-response-too-large');assert.equal(status,502);resolve();},()=>{},'orders');});assert.equal(written,false);
 const cancel=delayDiscoveryReply(Readable.from(['genuine']),res,500,()=>assert.fail(),()=>{},'orders');cancel();await new Promise(r=>setTimeout(r,550));assert.equal(written,false);
});
test('only a bounded core helper can request an Orders delay',()=>{
 const c={scope:'isolated-fictional-fixture',runId:'orders01',node:'/private/node',logDir:'/private/log'},s={kind:'core',checkout:'/private/source',state:'/private/state',tlsDir:'/private/tls',socketPath:'/private/ipc',ordersReadDelayMs:3000};
 assert.match(serviceSpec(c,s).content,/WAREHOUSE_FIXTURE_ORDERS_READ_DELAY_MS=3000/);
 for(const edit of [{kind:'switch'},{kind:'fault'},{replacementAuthentication:true},{ordersReadDelayMs:5001},{ordersReadDelayMs:'3000'}])assert.throws(()=>serviceSpec(c,{...s,...edit}));
});
