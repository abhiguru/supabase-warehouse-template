import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { proxyFixtureRequest, proxyFixtureUpgrade } from '../scripts/fixture-http-proxy.mjs';
import { WebSocket, WebSocketServer } from 'ws';

async function listen(server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}
async function close(server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
// Ephemeral servers exercise proxy plumbing; the fixed-origin matcher is tested
// separately without ever binding the campaign's occupied warehouse port.
function testUploadHold(events){return {buffer(req,_target,{forward,observe}){
 let timer,stopped=false;const chunks=[];
 req.on('data',chunk=>chunks.push(chunk));req.on('end',()=>{
  observe({event:'switch-upload-delay-start',delayMs:100,monotonicMs:performance.now()});
  timer=setTimeout(()=>{if(stopped)return;events.push('release');forward(Buffer.concat(chunks));},100);
 });return ()=>{stopped=true;clearTimeout(timer);};
}};}
test('held HTTP body executes once after release; ordinary timeout does not expire during hold',async()=>{
 let calls=0,received;const events=[];
 const upstream=createServer((req,res)=>{calls++;const chunks=[];req.on('data',b=>chunks.push(b));req.on('end',()=>{received=Buffer.concat(chunks);res.end('committed');});});
 const base=await listen(upstream);
 const bridge=createServer((req,res)=>proxyFixtureRequest(req,res,new URL('/upload',base),{timeoutMs:50,switchUploadHold:testUploadHold(events)}));
 const url=await listen(bridge),raw=Buffer.from('{"private":"not observed"}');
 try{
  const result=await new Promise((resolve,reject)=>{const q=request(url,{method:'POST',headers:{'content-length':raw.length}},res=>{const parts=[];res.on('data',b=>parts.push(b));res.on('end',()=>resolve({status:res.statusCode,body:Buffer.concat(parts).toString()}));});q.on('error',reject);q.end(raw);});
  assert.deepEqual(result,{status:200,body:'committed'});assert.equal(calls,1);assert.deepEqual(received,raw);assert.deepEqual(events,['release']);
 }finally{await close(bridge);await close(upstream);}
});
test('HTTP client disconnect while upload held prevents upstream execution',async()=>{
 let calls=0;const events=[];let held;
 const started=new Promise(resolve=>held=resolve);
 const upstream=createServer((_req,res)=>{calls++;res.end('unexpected');}),base=await listen(upstream);
 const bridge=createServer((req,res)=>proxyFixtureRequest(req,res,new URL('/upload',base),{switchUploadHold:testUploadHold(events),observe:e=>{if(e.event==='switch-upload-delay-start')held();}}));
 const url=await listen(bridge);
 try{
  const q=request(url,{method:'POST'});q.on('error',()=>{});q.end('private');await started;q.destroy();
  await new Promise(resolve=>setTimeout(resolve,150));assert.equal(calls,0);assert.deepEqual(events,[]);
 }finally{await close(bridge);await close(upstream);}
});
function fetchResult(url) {
  return new Promise((resolve, reject) => {
    const q = request(url, response => {
      const parts = [];
      response.on('data', part => parts.push(part));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(parts).toString() }));
      response.on('error', reject); response.on('aborted', () => reject(new Error('aborted response')));
    });
    q.on('error', reject); q.end();
  });
}
test('forwarding remains bounded for a stalled response and records no private query values', async () => {
  const upstream = createServer((_q, _s) => {}), observed = [];
  const base = await listen(upstream);
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/rest/v1/rpc/get_orders_list?apikey=private-token', base),
    { timeoutMs: 80, observe: x => observed.push(x) }));
  const url = await listen(bridge);
  try {
    const response = await fetchResult(url);
    assert.equal(response.status, 504);
    assert.equal(observed.length, 1);
    assert.equal(observed[0].event, 'upstream-timeout');
    assert.ok(!JSON.stringify(observed).includes('private-token'));
  } finally { await close(bridge); await close(upstream); }
});
test('connection refusal returns an explicit unavailable response and bridge stays alive', async () => {
  const upstream = createServer(); const base = await listen(upstream); await close(upstream);
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/private-document', base)));
  const url = await listen(bridge);
  try { for (let n = 0; n < 2; n++) assert.equal((await fetchResult(url)).status, 502); }
  finally { await close(bridge); }
});
test('a truncated upstream response fails without an unhandled process error; later request succeeds', async () => {
  let broken = true; const observed = [];
  const upstream = createServer((_q, res) => {
    if (broken) { res.writeHead(200, { 'content-length': 99 }); res.write('partial'); setTimeout(() => res.destroy(), 10); }
    else res.end('complete');
  });
  const base = await listen(upstream);
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/rest/v1/rpc/get_orders_list', base), { observe: x => observed.push(x) }));
  const url = await listen(bridge);
  try {
    await assert.rejects(fetchResult(url));
    broken = false;
    assert.equal((await fetchResult(url)).body, 'complete');
    assert.ok(observed.some(x => x.event === 'upstream-response-aborted' || x.event === 'upstream-response-error'));
  } finally { await close(bridge); await close(upstream); }
});
test('client cancellation releases a stalled upstream without killing the bridge', async () => {
  const upstream = createServer((_q, _s) => {}); const base = await listen(upstream); const observed = [];
  const bridge = createServer((req, res) => proxyFixtureRequest(req, res, new URL('/rest/v1/rpc/get_orders_list', base), { timeoutMs: 200, observe: x => observed.push(x) }));
  const url = await listen(bridge);
  try {
    await new Promise(resolve => {
      const q = request(url); q.on('error', resolve); q.end(); setTimeout(() => q.destroy(), 40);
    });
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.ok(observed.some(x => x.event === 'client-response-closed' || x.event === 'client-request-aborted'));
    assert.equal(bridge.listening, true);
  } finally { await close(bridge); await close(upstream); }
});

test('WebSocket forwarding survives client disconnect and carries a genuine upstream reply', async () => {
  const upstream = createServer(); const ws = new WebSocketServer({ server: upstream });
  ws.on('connection', socket => socket.on('message', data => socket.send(data)));
  const base = await listen(upstream); const bridge = createServer();
  bridge.on('upgrade', (req, client, head) => proxyFixtureUpgrade(req, client, head, new URL('/realtime/v1/websocket', base)));
  const url = (await listen(bridge)).replace('http:', 'ws:');
  try {
    for (let n = 0; n < 2; n++) {
      const client = new WebSocket(url);
      await new Promise((resolve, reject) => { client.once('open', resolve); client.once('error', reject); });
      const reply = new Promise((resolve, reject) => { client.once('message', data => resolve(data.toString())); client.once('error', reject); });
      client.send('fictional-message'); assert.equal(await reply, 'fictional-message');
      const closed = new Promise(resolve => client.once('close', resolve)); client.close(); await closed;
    }
  } finally { await new Promise(resolve => ws.close(resolve)); await close(bridge); await close(upstream); }
});
test('rejected and stalled upgrades fail instead of hanging or fabricating 101', async () => {
  for (const stalled of [false, true]) {
    const upstream = createServer((_q, res) => { if (!stalled) { res.writeHead(401); res.end(); } });
    const base = await listen(upstream); const bridge = createServer();
    bridge.on('upgrade', (req, client, head) => proxyFixtureUpgrade(req, client, head, new URL('/realtime/v1/websocket', base), { timeoutMs: 80 }));
    const url = (await listen(bridge)).replace('http:', 'ws:');
    try {
      const client = new WebSocket(url); let opened = false; client.on('open', () => { opened = true; });
      await new Promise(resolve => { client.once('error', resolve); });
      assert.equal(opened, false); assert.equal(bridge.listening, true);
    } finally { await close(bridge); await close(upstream); }
  }
});

test('optional replacement observation records only credential presence, never values', async () => {
  const observed=[];const upstream=createServer((_req,res)=>{res.writeHead(200);res.end('ok');});const base=await listen(upstream);
  const bridge=createServer((req,res)=>proxyFixtureRequest(req,res,new URL('/functions/v1/get-public-config?token=fictional-secret',base),{observeAuthenticationPresence:true,observe:event=>observed.push(event)}));const url=await listen(bridge);
  try {
    await new Promise((resolve,reject)=>{const q=request(url,{headers:{authorization:'Bearer fictional-private-value'}},res=>{res.resume();res.on('end',resolve);});q.on('error',reject);q.end();});
    assert.equal(observed.length,1);assert.equal(observed[0].authorizationPresent,true);assert.equal(observed[0].credentialQueryPresent,true);
    const text=JSON.stringify(observed);assert.ok(!text.includes('fictional-secret')&&!text.includes('fictional-private-value'));assert.equal(observed[0].path,'/functions/v1/get-public-config');
  } finally {await close(bridge);await close(upstream);}
});

test('optional upgrade observation exposes booleans only and forwarding remains genuine', async () => {
  const observed = [], upstream = createServer(), ws = new WebSocketServer({ server: upstream });
  ws.on('connection', socket => socket.on('message', data => socket.send(data)));
  const base = await listen(upstream), bridge = createServer();
  bridge.on('upgrade', (req, client, head) => proxyFixtureUpgrade(req, client, head,
    new URL('/realtime/v1/websocket?access_token=fictional-query-value', base),
    { observeAuthenticationPresence: true, observe: event => observed.push(event) }));
  const url = (await listen(bridge)).replace('http:', 'ws:');
  try {
    const client = new WebSocket(url, { headers: { authorization: 'Bearer fictional-header-value' } });
    await new Promise((resolve, reject) => { client.once('open', resolve); client.once('error', reject); });
    const reply = new Promise((resolve, reject) => { client.once('message', data => resolve(data.toString())); client.once('error', reject); });
    client.send('test-message'); assert.equal(await reply, 'test-message');
    const closed = new Promise(resolve => client.once('close', resolve)); client.close(); await closed;
    assert.equal(observed.length, 1);
    assert.equal(observed[0].event, 'upgrade-request'); assert.equal(observed[0].path, 'realtime');
    assert.equal(observed[0].authorizationPresent, true); assert.equal(observed[0].credentialQueryPresent, true);
    assert.ok(!JSON.stringify(observed).includes('fictional-query-value'));
    assert.ok(!JSON.stringify(observed).includes('fictional-header-value'));
  } finally { await new Promise(resolve => ws.close(resolve)); await close(bridge); await close(upstream); }
});

test('ordinary logout is independently identified without exposing body or credential values',async()=>{
 const observed=[];let upstreamBody='';const upstream=createServer((req,res)=>{req.on('data',part=>{upstreamBody+=part});req.on('end',()=>res.end('true'));});const base=await listen(upstream);
 const bridge=createServer((req,res)=>proxyFixtureRequest(req,res,new URL('/rest/v1/rpc/logout_session',base),{observeAuthenticationPresence:true,observe:event=>observed.push(event)}));const url=await listen(bridge);
 try{
  const body=JSON.stringify({p_refresh_token:'fictional-body-secret'});
  await new Promise((resolve,reject)=>{const q=request(url,{method:'POST',headers:{authorization:'Bearer fictional-header-secret','content-type':'application/json'}},res=>{res.resume();res.on('end',resolve)});q.on('error',reject);q.end(body)});
  assert.equal(upstreamBody,body);assert.equal(observed.length,1);assert.equal(observed[0].path,'/rest/v1/rpc/logout_session');assert.equal(observed[0].method,'POST');assert.equal(observed[0].status,200);assert.equal(observed[0].authorizationPresent,true);assert.equal(observed[0].credentialQueryPresent,false);assert.ok(!JSON.stringify(observed).includes('secret'));
 }finally{await close(bridge);await close(upstream)}
});
