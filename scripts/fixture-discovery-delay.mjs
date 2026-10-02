// Optional fictional switching-discovery transport only; genuine bytes, never fake identity.
import assert from 'node:assert/strict';
export function discoveryDelayMilliseconds(req,target,configured=0){
 assert.ok(Number.isInteger(configured)&&configured>=0&&configured<=5000&&(configured===0||configured>=500),'BOUNDED_FIXTURE_DISCOVERY_DELAY_REQUIRED');
 if(!configured)return 0;
 return req.method==='GET'&&target.protocol==='http:'&&target.hostname==='127.0.0.1'&&target.port==='18590'&&target.pathname==='/functions/v1/get-public-config'&&target.search===''&&req.headers.host==='backend-switch.example.test'&&req.headers.authorization===undefined?configured:0;
}
export function delayDiscoveryReply(response,res,milliseconds,fail,observe=()=>{},kind='discovery'){
 assert.ok(['discovery','orders'].includes(kind));
 assert.ok(Number.isInteger(milliseconds)&&milliseconds>=500&&milliseconds<=5000);
 let bytes=0,chunks=[],timer,stopped=false;
 const cancel=()=>{stopped=true;clearTimeout(timer);chunks=[];};
 response.on('data',chunk=>{if(stopped)return;bytes+=chunk.length;if(bytes>65536){cancel();fail(kind+'-response-too-large',502);}else chunks.push(chunk);});
 response.on('end',()=>{
  if(stopped)return;
  try{observe({event:kind+'-delay-start',status:response.statusCode,delayMs:milliseconds});}catch{/* No observer can affect transport. */}
  timer=setTimeout(()=>{if(stopped||res.destroyed)return cancel();res.writeHead(response.statusCode,response.headers);res.end(Buffer.concat(chunks));cancel();},milliseconds);
 });
 return cancel;
}
