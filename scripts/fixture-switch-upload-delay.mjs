// Fixture-only, one-shot pre-execution hold. No request contents are observed.
import assert from 'node:assert/strict';
const uuid=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
export function createSwitchUploadHold(config={milliseconds:0}) {
  assert.ok(Number.isInteger(config.milliseconds)&&(config.milliseconds===0||config.milliseconds>=500&&config.milliseconds<=30000),'BOUNDED_UPLOAD_HOLD_REQUIRED');
  if(config.milliseconds){
    assert.equal(config.scope,'isolated-fictional-native-switch-upload');
    assert.match(config.grnId,uuid);
    assert.equal(config.fileName,'FXS993-switch-upload.webp');
    assert.ok(Number.isInteger(config.fileSize)&&config.fileSize>0&&config.fileSize<=10485760);
  }
  const bound=Object.freeze({...config});
  let consumed=false;
  const eligible=(req,target)=>bound.milliseconds&&!consumed&&req.method==='POST'&&target.protocol==='http:'&&target.hostname==='127.0.0.1'&&target.port==='18080'&&target.pathname==='/rest/v1/rpc/register_grn_image_upload'&&target.search===''&&req.headers.host==='backend-core.example.test'&&typeof req.headers.authorization==='string'&&req.headers.authorization.length>0;
  return {buffer(req,target,{forward,fail,observe=()=>{}}){
    if(!eligible(req,target))return null;
    let chunks=[],bytes=0,timer,stopped=false;
    const cancel=()=>{stopped=true;clearTimeout(timer);chunks=[];req.removeListener('data',data);req.removeListener('end',end);};
    const data=chunk=>{if(stopped)return;bytes+=chunk.length;if(bytes>65536){cancel();fail('switch-upload-body-bound',413);req.resume();return;}chunks.push(Buffer.from(chunk));};
    const end=()=>{
      if(stopped)return;
      const raw=Buffer.concat(chunks);chunks=[];req.removeListener('data',data);req.removeListener('end',end);
      let body;try{body=JSON.parse(raw.toString('utf8'));}catch{/* Ordinary backend rejection. */}
      const keys=['p_file_name','p_file_size','p_grn_id','p_grn_item_id','p_image_type','p_mime_type'];
      const match=!consumed&&body&&typeof body==='object'&&!Array.isArray(body)&&JSON.stringify(Object.keys(body).sort())===JSON.stringify(keys)&&body.p_grn_id===bound.grnId&&body.p_image_type==='header'&&body.p_grn_item_id===null&&body.p_file_name===bound.fileName&&body.p_file_size===bound.fileSize&&body.p_mime_type==='image/webp';
      if(!match){stopped=true;forward(raw);return;}
      // Consume before notifying; cancellation never rearms a write.
      consumed=true;
      // CLOCK_MONOTONIC shares an origin with the native driver's host clock.
      const event=name=>{try{observe({event:name,delayMs:bound.milliseconds,monotonicMs:Number(process.hrtime.bigint())/1e6});}catch{/* Observers cannot change transport. */}};
      event('switch-upload-delay-start');
      timer=setTimeout(()=>{if(stopped)return;stopped=true;event('switch-upload-delay-release');forward(raw);},bound.milliseconds);
    };
    req.on('data',data);req.on('end',end);return cancel;
  }};
}
