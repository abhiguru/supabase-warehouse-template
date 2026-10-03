const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const hash=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const manifest=(root,nativeOnly)=>{const files={};let count=0;const walk=dir=>{for(const name of fs.readdirSync(dir).sort()){assert.ok(++count<=100000);const p=path.join(dir,name),s=fs.lstatSync(p);if(s.isSymbolicLink())continue;if(s.isDirectory())walk(p);else if(s.isFile()&&(!nativeOnly||p.endsWith('.node'))){assert.ok(s.size<=67108864);files[p.slice(root.length+1)]={size:s.size,sha256:hash(p)};}}};walk(root);return files;};
async function main(){
 const info={status:'PASS',scope:'isolated-image-node-dependency-and-precompiled-byte-smoke-only',node:process.version,busboy:JSON.parse(fs.readFileSync('/app/node_modules/@fastify/busboy/package.json')).version,rootLockSHA256:hash('/app/package-lock.json'),compiled:manifest('/app/dist',false),nativeModules:manifest('/app/node_modules',true),npmPresent:fs.existsSync('/usr/local/bin/npm')};
 require('/app/node_modules/fs-xattr');info.nativeXattrModuleLoads=true;
 if(process.argv[2]==='candidate'){
  assert.equal(info.busboy,'3.2.2');assert.equal(info.npmPresent,false);
  const Busboy=require('/app/node_modules/@fastify/busboy');info.parserCases=[];
  for(const mode of ['ordinary','oversized-boundary','prototype-header']){
   const boundary=mode==='oversized-boundary'?'A'.repeat(252):'fictional-test-boundary',extra=mode==='prototype-header'?'constructor: fixture\r\n':'';
   const data=Buffer.from('--'+boundary+'\r\n'+extra+'Content-Disposition: form-data; name="item"\r\n\r\nfictional\r\n--'+boundary+'--\r\n');
   await new Promise((done,reject)=>{const fields=[];let completed=false;const pass=rejected=>{if(completed)return;completed=true;info.parserCases.push({mode,status:'PASS',rejected});done();};try{const parser=new Busboy({headers:{'content-type':'multipart/form-data; boundary='+boundary}});parser.on('field',(n,v)=>fields.push([n,v]));parser.on('error',e=>{try{assert.equal(mode,'oversized-boundary');assert.ok(e instanceof Error);pass(true);}catch(err){reject(err);}});parser.on('finish',()=>{try{if(!completed){assert.deepEqual(fields,[['item','fictional']]);pass(false);}}catch(e){reject(e);}});parser.end(data);}catch(e){try{assert.equal(mode,'oversized-boundary');assert.ok(e instanceof Error);pass(true);}catch(err){reject(err);}}});
  }
  const app=require('/app/node_modules/fastify')();await app.register(require('/app/node_modules/@fastify/multipart'),{limits:{files:1,fileSize:1024}});
  app.post('/fixture-multipart',async req=>{const file=await req.file();const bytes=await file.toBuffer();assert.equal(file.filename,'fixture.txt');assert.equal(bytes.toString(),'fictional-image');return {length:bytes.length};});
  const boundary='fictional-image-boundary',payload=Buffer.from('--'+boundary+'\r\nContent-Disposition: form-data; name="file"; filename="fixture.txt"\r\nContent-Type: text/plain\r\n\r\nfictional-image\r\n--'+boundary+'--\r\n');const response=await app.inject({method:'POST',url:'/fixture-multipart',headers:{'content-type':'multipart/form-data; boundary='+boundary},payload});assert.equal(response.statusCode,200);assert.deepEqual(response.json(),{length:15});await app.close();info.fastifyMultipartIntegration='PASS';
 }
 process.stdout.write(JSON.stringify(info)+'\n');
}
main().catch(error=>{process.stderr.write(JSON.stringify({status:'FAIL',category:'ISOLATED_STORAGE_IMAGE_SMOKE',exceptionType:error.name})+'\n');process.exitCode=1;});
