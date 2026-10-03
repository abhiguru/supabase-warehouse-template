import test from 'node:test';import assert from 'node:assert/strict';import{Readable}from'node:stream';
import{discoveryDelayMilliseconds,delayDiscoveryReply}from'../scripts/fixture-discovery-delay.mjs';
const target=()=>new URL('http://127.0.0.1:18590/functions/v1/get-public-config');
const req=()=>({method:'GET',headers:{host:'backend-switch.example.test'}});
test('only unauthenticated exact fictional switching discovery can be delayed',()=>{
 assert.equal(discoveryDelayMilliseconds(req(),target(),3000),3000);
 for(const r of [{...req(),method:'POST'},{...req(),headers:{host:'backend-core.example.test'}},{...req(),headers:{...req().headers,authorization:'Bearer private'}}])assert.equal(discoveryDelayMilliseconds(r,target(),3000),0);
 for(const url of ['http://127.0.0.1:18080/functions/v1/get-public-config','http://foreign.example:18590/functions/v1/get-public-config','http://127.0.0.1:18590/rest/v1/rpc/save_dispatch','http://127.0.0.1:18590/functions/v1/get-public-config?token=private'])assert.equal(discoveryDelayMilliseconds(req(),new URL(url),3000),0);
 for(const ms of [-1,1,499,5001,Infinity,'3000',3.5])assert.throws(()=>discoveryDelayMilliseconds(req(),target(),ms));
});
test('delay preserves genuine response bytes and status, without logging the response',async()=>{
 const body=Buffer.from('{"data":{"instanceId":"genuine-fixture-identity"}}');const response=Readable.from([body]);response.statusCode=200;response.headers={'content-type':'application/json'};
 const events=[],started=Date.now();await new Promise((resolve,reject)=>{const res={destroyed:false,writeHead:(status,headers)=>{assert.equal(status,200);assert.deepEqual(headers,response.headers);},end:bytes=>{assert.deepEqual(bytes,body);assert.ok(Date.now()-started>=490);resolve();}};delayDiscoveryReply(response,res,500,()=>reject(new Error('unexpected failure')),e=>events.push(e));});assert.deepEqual(events,[{event:'discovery-delay-start',status:200,delayMs:500}]);assert.doesNotMatch(JSON.stringify(events),/genuine-fixture-identity/);
});
test('oversized discovery refuses forwarding; canceled response never delivers late bytes',async()=>{
 let written=false;const res={destroyed:false,writeHead:()=>{written=true;},end:()=>{written=true;}};
 await new Promise(resolve=>{const response=Readable.from([Buffer.alloc(65537)]);delayDiscoveryReply(response,res,500,(event,status)=>{assert.equal(event,'discovery-response-too-large');assert.equal(status,502);resolve();});});assert.equal(written,false);
 const response=Readable.from(['small']);const cancel=delayDiscoveryReply(response,res,500,()=>assert.fail());cancel();await new Promise(resolve=>setTimeout(resolve,550));assert.equal(written,false);
});
