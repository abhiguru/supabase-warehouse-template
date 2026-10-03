import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {confirmedOrdersReadDelayMilliseconds as delay} from '../scripts/fixture-confirmed-orders-delay.mjs';
import {delayDiscoveryReply} from '../scripts/fixture-discovery-delay.mjs';
import {serviceSpec} from '../scripts/fixture-service-supervisor.mjs';
const req={method:'POST',headers:{host:'backend-core.example.test',authorization:'Bearer synthetic-never-log'}};
const target=new URL('http://127.0.0.1:18080/rest/v1/rpc/get_orders_list');
test('confirmed hold matches only exact authenticated original fictional read',()=>{
 assert.equal(delay(req,target),0);assert.equal(delay(req,target,30000),30000);
 for(const ms of [5000,29999,30001,'30000',Infinity,-1])assert.throws(()=>delay(req,target,ms));
 for(const url of ['http://127.0.0.1:18080/rest/v1/rpc/save_grn','http://127.0.0.1:18080/rest/v1/rpc/create_dispatch_with_stock_check','http://127.0.0.1:18080/rest/v1/rpc/refresh_jwt_token','http://127.0.0.1:18080/functions/v1/get-public-config','http://127.0.0.1:18690/rest/v1/rpc/get_orders_list','http://foreign.invalid:18080/rest/v1/rpc/get_orders_list','http://127.0.0.1:18080/rest/v1/rpc/get_orders_list?token=synthetic'])assert.equal(delay(req,new URL(url),30000),0);
 for(const patch of [{method:'GET'},{headers:{host:'backend-core.example.test'}},{headers:{host:'production.invalid',authorization:'synthetic'}}])assert.equal(delay({...req,...patch},target,30000),0);
});
test('actual response buffer holds genuine bytes for exactly thirty seconds and supports cancellation',t=>{
 t.mock.timers.enable({apis:['setTimeout']});
 const response=new EventEmitter();response.statusCode=200;response.headers={'content-type':'application/json'};const sent=[],events=[];const res={destroyed:false,writeHead:(...x)=>sent.push(x),end:bytes=>sent.push(bytes.toString())};
 const cancel=delayDiscoveryReply(response,res,30000,()=>assert.fail('unexpected fault'),e=>events.push(e),'confirmed-orders');
 response.emit('data',Buffer.from('{"data":"synthetic"}'));response.emit('end');assert.deepEqual(events,[{event:'confirmed-orders-delay-start',status:200,delayMs:30000}]);t.mock.timers.tick(29999);assert.equal(sent.length,0);t.mock.timers.tick(1);assert.equal(sent.length,2);assert.equal(sent[1],'{"data":"synthetic"}');cancel();
 const pending=new EventEmitter();pending.statusCode=200;pending.headers={};const stop=delayDiscoveryReply(pending,res,30000,()=>assert.fail('unexpected fault'),()=>{},'confirmed-orders');pending.emit('data',Buffer.from('discarded'));pending.emit('end');stop();t.mock.timers.tick(30000);assert.equal(sent.length,2);
 assert.throws(()=>delayDiscoveryReply(pending,res,30000,()=>{},()=>{},'orders'));
});
test('supervision requires a separate observed core helper and retains twelve-hour cap',()=>{
 const c={scope:'isolated-fictional-fixture',runId:'confirmedread01',node:'/private/node',logDir:'/private/log'},s={kind:'core',checkout:'/private/source',state:'/private/state',tlsDir:'/private/tls',socketPath:'/private/ipc',observeAuthenticationPresence:true,confirmedOrdersReadDelayMs:30000};
 const spec=serviceSpec(c,s);assert.match(JSON.stringify(spec),/WAREHOUSE_FIXTURE_CONFIRMED_ORDERS_READ_DELAY_MS=30000/);assert.match(JSON.stringify(spec),/RuntimeMaxSec=43200/);
 for(const patch of [{kind:'switch'},{kind:'fault'},{observeAuthenticationPresence:false},{replacementAuthentication:true},{ordersReadDelayMs:5000},{dispatchConcurrency:{milliseconds:5000}},{discoveryDelayMs:5000},{confirmedOrdersReadDelayMs:30001}])assert.throws(()=>serviceSpec(c,{...s,...patch}));
});
