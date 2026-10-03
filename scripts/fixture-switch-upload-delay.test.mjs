import test from 'node:test';
import assert from 'node:assert/strict';
import {PassThrough} from 'node:stream';
import {setTimeout as wait} from 'node:timers/promises';
import {createSwitchUploadHold} from './fixture-switch-upload-delay.mjs';
const config={scope:'isolated-fictional-native-switch-upload',milliseconds:500,grnId:'11111111-1111-4111-8111-111111111111',fileName:'FXS993-switch-upload.webp',fileSize:1234};
const target=new URL('http://127.0.0.1:18080/rest/v1/rpc/register_grn_image_upload');
const request=()=>Object.assign(new PassThrough(),{method:'POST',headers:{host:'backend-core.example.test',authorization:'private-test-credential'}});
const body=()=>({p_grn_id:config.grnId,p_image_type:'header',p_grn_item_id:null,p_file_name:config.fileName,p_file_size:config.fileSize,p_mime_type:'image/webp'});
test('native compression permits only a declared positive size up to one MiB and keeps all other matching constraints',async()=>{
 const {fileSize,...base}=config;
 for(const change of [{maxFileSize:1048577},{maxFileSize:0},{maxFileSize:'1234'},{maxFileSize:1234,fileSize:1234},{}])assert.throws(()=>createSwitchUploadHold({...base,...change}));
 for(const size of [0,1048577,1.5,'1234']){
  const r=request(),raw=Buffer.from(JSON.stringify({...body(),p_file_size:size}));let forwarded;const events=[];
  createSwitchUploadHold({...base,maxFileSize:1048576}).buffer(r,target,{forward:b=>forwarded=b,fail:()=>assert.fail(),observe:e=>events.push(e)});r.end(raw);await wait(5);assert.deepEqual(forwarded,raw);assert.deepEqual(events,[]);
 }
 const r=request();let forwarded;const raw=Buffer.from(JSON.stringify(body()));
 createSwitchUploadHold({...base,maxFileSize:1048576}).buffer(r,target,{forward:b=>forwarded=b,fail:()=>assert.fail()});r.end(raw);await wait(20);assert.equal(forwarded,undefined);await wait(550);assert.deepEqual(forwarded,raw);
});
test('disabled by default; invalid configuration and unrelated transport refused',()=>{
 assert.equal(createSwitchUploadHold().buffer(request(),target,{}),null);
 for(const change of[{milliseconds:30001},{scope:'production'},{grnId:'other'},{fileName:'other.webp'},{fileSize:0}])assert.throws(()=>createSwitchUploadHold({...config,...change}));
 for(const url of['http://127.0.0.1:18080/rest/v1/rpc/save_grn','http://127.0.0.1:18590/rest/v1/rpc/register_grn_image_upload',target+'?token=private'])assert.equal(createSwitchUploadHold(config).buffer(request(),new URL(url),{}),null);
 const r=request();r.headers.host='backend-switch.example.test';assert.equal(createSwitchUploadHold(config).buffer(r,target,{}),null);
});
test('exact upload held once, unchanged; metadata cannot reveal request or credentials',async()=>{
 const hold=createSwitchUploadHold(config),r=request(),events=[];let forwarded=[];
 hold.buffer(r,target,{forward:raw=>forwarded.push(raw),fail:()=>assert.fail(),observe:e=>events.push(e)});
 const raw=Buffer.from(JSON.stringify(body()));r.end(raw);await wait(30);assert.equal(forwarded.length,0);await wait(550);
 assert.deepEqual(forwarded,[raw]);assert.deepEqual(events.map(e=>e.event),['switch-upload-delay-start','switch-upload-delay-release']);
 assert.ok(events[1].monotonicMs-events[0].monotonicMs>=490);
 assert.ok(!JSON.stringify(events).includes(config.grnId));assert.ok(!JSON.stringify(events).includes(config.fileName));
 assert.equal(hold.buffer(request(),target,{}),null);
});
test('cancellation executes nothing and cannot rearm; observer errors cannot alter transport',async()=>{
 const hold=createSwitchUploadHold(config),r=request();let count=0;
 const cancel=hold.buffer(r,target,{forward:()=>count++,fail:()=>assert.fail(),observe:()=>{throw Error('observer');}});
 r.end(JSON.stringify(body()));await wait(20);cancel();await wait(550);assert.equal(count,0);assert.equal(hold.buffer(request(),target,{}),null);
});
test('wrong payload forwarded unchanged; buffering bounded; config copied before use',async()=>{
 for(const change of[{p_grn_id:'other'},{p_file_size:1235},{p_image_type:'item'},{p_grn_item_id:config.grnId},{p_mime_type:'image/png'},{extra:'sensitive'}]){
  const r=request(),raw=Buffer.from(JSON.stringify({...body(),...change}));let forwarded;
  createSwitchUploadHold(config).buffer(r,target,{forward:b=>forwarded=b,fail:()=>assert.fail()});r.end(raw);await wait(5);assert.deepEqual(forwarded,raw);
 }
 const r=request();let failure;createSwitchUploadHold(config).buffer(r,target,{forward:()=>assert.fail(),fail:(event,status)=>failure={event,status}});r.end(Buffer.alloc(65537));await wait(5);assert.deepEqual(failure,{event:'switch-upload-body-bound',status:413});
 const mutable={...config},hold=createSwitchUploadHold(mutable);mutable.milliseconds=0;assert.equal(typeof hold.buffer(request(),target,{forward:()=>{},fail:()=>{}}),'function');
});
