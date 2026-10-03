import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
const context = resolve('docker/postgres-meta');

test('metadata native copy preserves exact SQL/worker bytes, flat paths and repeated builds', async () => {
 const root = await mkdtemp(resolve(tmpdir(), 'warehouse-meta-copy-'));
 try {
  await mkdir(resolve(root,'src/lib/sql/nested'),{recursive:true});await mkdir(resolve(root,'src/server'),{recursive:true});
  await writeFile(resolve(root,'src/lib/sql/one.sql'),'select 1;\n');await writeFile(resolve(root,'src/lib/sql/ignore.txt'),'excluded');await writeFile(resolve(root,'src/lib/sql/nested/two.sql'),'not a top-level asset');await writeFile(resolve(root,'src/server/format-worker.js'),'export const fixture = 1;\n');
  const run=()=>{const q=spawnSync(process.execPath,[resolve(context,'copy-build-assets.mjs')],{cwd:root,encoding:'utf8',timeout:5000});assert.equal(q.status,0,q.stderr);};run();
  assert.equal(await readFile(resolve(root,'dist/lib/sql/one.sql'),'utf8'),'select 1;\n');assert.equal(await readFile(resolve(root,'dist/server/format-worker.js'),'utf8'),'export const fixture = 1;\n');
  await assert.rejects(readFile(resolve(root,'dist/lib/sql/ignore.txt')));await assert.rejects(readFile(resolve(root,'dist/lib/sql/two.sql')));
  await writeFile(resolve(root,'src/lib/sql/one.sql'),'select 2;\n');run();assert.equal(await readFile(resolve(root,'dist/lib/sql/one.sql'),'utf8'),'select 2;\n');
 } finally { await rm(root,{recursive:true,force:true}); }
});

test('metadata native watcher restarts nested source changes, ignores node_modules and stops its child', {timeout:15000}, async () => {
 const root=await mkdtemp(resolve(tmpdir(),'warehouse-meta-watch-'));let child;
 const waitFor=async(predicate)=>{const deadline=Date.now()+5000;while(!predicate()){assert.ok(Date.now()<deadline,'Bounded watcher observation');await new Promise(resolve=>setTimeout(resolve,25));}};
 try {
  await mkdir(resolve(root,'src/nested'),{recursive:true});await mkdir(resolve(root,'node_modules/fixture'),{recursive:true});await writeFile(resolve(root,'src/nested/value.json'),'1');
  await writeFile(resolve(root,'child.cjs'),"const fs=require('node:fs');console.log('START '+process.pid+' '+fs.readFileSync('src/nested/value.json','utf8'));process.on('SIGTERM',()=>{console.log('STOP '+process.pid);process.exit(0)});setInterval(()=>{},10000);\n");
  child=spawn(process.execPath,[resolve(context,'dev-watch.mjs'),'child.cjs'],{cwd:root,stdio:['ignore','pipe','pipe']});let output='',errors='';child.stdout.on('data',x=>{output+=x;});child.stderr.on('data',x=>{errors+=x;});
  await waitFor(()=>output.includes(' 1\n'));await writeFile(resolve(root,'node_modules/fixture/file.js'),'ignored');await new Promise(resolve=>setTimeout(resolve,400));assert.equal((output.match(/START /g)||[]).length,1,errors);
  await writeFile(resolve(root,'src/nested/value.json'),'2');await waitFor(()=>output.includes(' 2\n'));assert.match(output,/STOP \d+/);
  const starts=(output.match(/START /g)||[]).length;await mkdir(resolve(root,'src/new'),{recursive:true});await writeFile(resolve(root,'src/new/new.ts'),'export const fixture=1;');await waitFor(()=>(output.match(/START /g)||[]).length>starts);
  child.kill('SIGTERM');await waitFor(()=>child.exitCode!==null||child.signalCode!==null);assert.equal(child.exitCode,0,errors);assert.equal((output.match(/STOP /g)||[]).length,(output.match(/START /g)||[]).length,'No orphaned server process');
 } finally {if(child&&child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await rm(root,{recursive:true,force:true});}
});
