// Transport for guarded fictional bridges. Caller validates the fixed origin.
// No payloads, query strings, headers, credentials or challenge IDs are logged.
import { request as httpRequest } from 'node:http';
import {discoveryDelayMilliseconds,delayDiscoveryReply} from './fixture-discovery-delay.mjs';
import {ordersReadDelayMilliseconds} from './fixture-orders-delay.mjs';
import {bufferConcurrencyRequest} from './fixture-dispatch-concurrency-delay.mjs';
const observedPaths = new Set(['/rest/v1/rpc/get_orders_list', '/rest/v1/rpc/refresh_jwt_token', '/rest/v1/rpc/logout_session', '/functions/v1/get-public-config']);
export function proxyFixtureRequest(req, res, target, { timeoutMs = 15000, observe = () => {}, observeAuthenticationPresence = false, discoveryDelayMs = 0, ordersReadDelayMs = 0, dispatchConcurrency = {milliseconds:0} } = {}) {
  const discoveryDelay=discoveryDelayMilliseconds(req,target,discoveryDelayMs),ordersDelay=ordersReadDelayMilliseconds(req,target,ordersReadDelayMs);
  const delayed=discoveryDelay||ordersDelay;
  let upstream, reply, complete = false, cancelDelay=()=>{};
  const metadata = {
    method: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'].includes(req.method) ? req.method : 'OTHER',
    path: observedPaths.has(target.pathname) ? target.pathname : 'other',
    ...(observeAuthenticationPresence ? { authorizationPresent: typeof req.headers.authorization === 'string', credentialQueryPresent: ['access_token','token','apikey'].some(key => target.searchParams.has(key)) } : {}),
  };
  const finish = (event, status) => {
    if (complete) return false;
    complete = true; clearTimeout(deadline);cancelDelay();
    // Observers cannot throw back into the HTTP server.
    try { observe({ atUTC: new Date().toISOString(), event, ...metadata, status }); } catch { /* Safe diagnostic only. */ }
    return true;
  };
  const fail = (event, status) => {
    if (!finish(event, status)) return;
    upstream?.destroy(); reply?.destroy();
    if (res.destroyed) return;
    if (res.headersSent) res.destroy();
    else {
      res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify({ success: false, message: status === 504 ? 'Fixture upstream timed out' : 'Fixture upstream unavailable' }));
    }
  };
  const deadline = setTimeout(() => fail('upstream-timeout', 504), timeoutMs);
  const start = (buffer=null) => {
  if(complete)return;
  upstream = httpRequest(target, { method: req.method, headers: req.headers }, response => {
    reply = response;
    response.on('error', () => fail('upstream-response-error', 502));
    response.on('aborted', () => fail('upstream-response-aborted', 502));
    if(delayed&&(!ordersDelay||response.statusCode===200))cancelDelay=delayDiscoveryReply(response,res,delayed,fail,event=>{try{observe({atUTC:new Date().toISOString(),...metadata,...event});}catch{/* Safe diagnostic only. */}},ordersDelay?'orders':'discovery');
    else {res.writeHead(response.statusCode, response.headers);response.pipe(res);}
  });
  upstream.on('error', () => fail('upstream-unavailable', 502));
  if(buffer===null)req.pipe(upstream);else upstream.end(buffer);
  };
  // Completion/abort handlers must exist while an eligible request is held.
  res.on('finish', () => finish('complete', res.statusCode));
  req.on('error', () => fail('client-request-error', 499));
  req.on('aborted', () => fail('client-request-aborted', 499));
  res.on('close', () => {if(!res.writableFinished)fail('client-response-closed',499);});
  const hold=bufferConcurrencyRequest(req,target,dispatchConcurrency,{forward:start,fail,observe:event=>{try{observe({atUTC:new Date().toISOString(),...metadata,...event});}catch{/* Safe diagnostic only. */}}});
  cancelDelay=hold||(()=>{});
  if(!hold)start();
}

export function proxyFixtureUpgrade(req, client, head, target, { timeoutMs = 15000, observe = () => {}, observeAuthenticationPresence = false } = {}) {
  let socket;
  if (observeAuthenticationPresence) {
    try { observe({ atUTC:new Date().toISOString(), event:'upgrade-request', path:target.pathname === '/realtime/v1/websocket' ? 'realtime' : 'other', authorizationPresent:typeof req.headers.authorization === 'string', credentialQueryPresent:['access_token','token','apikey'].some(key => target.searchParams.has(key)) }); } catch { /* Safe diagnostic only. */ }
  }
  const upstream = httpRequest(target, { headers: req.headers });
  const fail = () => { clearTimeout(deadline); upstream.destroy(); socket?.destroy(); client.destroy(); };
  const deadline = setTimeout(fail, timeoutMs);
  client.on('error', fail);
  client.on('close', () => { clearTimeout(deadline); upstream.destroy(); socket?.destroy(); });
  upstream.on('error', fail);
  upstream.on('response', response => {
    clearTimeout(deadline);
    // A rejected upgrade is a rejection, never an invented successful socket.
    client.end(`HTTP/1.1 ${response.statusCode} ${response.statusMessage}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    response.destroy();
  });
  upstream.on('upgrade', (reply, connected, upstreamHead) => {
    clearTimeout(deadline); socket = connected;
    socket.on('error', fail); socket.on('close', () => client.destroy());
    client.write(`HTTP/1.1 ${reply.statusCode} ${reply.statusMessage}\r\n`);
    for (let i = 0; i < reply.rawHeaders.length; i += 2) client.write(`${reply.rawHeaders[i]}: ${reply.rawHeaders[i + 1]}\r\n`);
    client.write('\r\n');
    if (upstreamHead.length) client.write(upstreamHead);
    if (head.length) socket.write(head);
    client.pipe(socket); socket.pipe(client);
  });
  upstream.end();
}
