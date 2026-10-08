import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, symlinkSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
for(const driverName of ['operator-api-auth-states.mjs','operator-api-otp-expiry.mjs']) {
const driver=resolve('tests',driverName);
for(const kind of ['missing binding','wrong mode','public binding','symlink binding','wrong state','wrong guard','wrong identity','public evidence']) {
 test(driverName+' refuses '+kind+' before fixture or SQL access',()=>{
  const root=mkdtempSync(join(tmpdir(),'warehouse-auth-refusal-'));chmodSync(root,0o700);
  try {
   const checkout=join(root,'checkout'),state=join(root,'state'),evidence=join(root,'evidence'),bin=join(root,'bin'),marker=join(root,'access-marker');
   for(const p of [checkout,join(checkout,'tests'),state,join(state,'public'),evidence,bin])mkdirSync(p,{mode:0o700});
   const guard=`import {writeFileSync} from 'node:fs';export function operatorFixture(){writeFileSync(${JSON.stringify(marker)},'fixture accessed');throw Error('fixture accessed');}`;
   writeFileSync(join(checkout,'tests/operator-fixture.mjs'),guard);
   writeFileSync(join(state,'public/instance.json'),JSON.stringify({instanceId:'fictional-owned-identity'}));
   writeFileSync(join(bin,'docker'),'#!/bin/sh\nprintf accessed > "'+marker+'"\nexit 99\n',{mode:0o700});
   const c={mode:'ordinary-final-backend-fixture',backendCheckout:checkout,backendState:state,instanceId:'fictional-owned-identity',fixtureGuardSHA256:createHash('sha256').update(guard).digest('hex'),evidenceRoot:evidence};
   if(kind==='wrong mode')c.mode='production';
   if(kind==='wrong guard')c.fixtureGuardSHA256='0'.repeat(64);
   if(kind==='wrong identity')c.instanceId='other-identity';
   if(kind==='public evidence')chmodSync(evidence,0o755);
   let binding=join(root,'binding.json');writeFileSync(binding,JSON.stringify(c),{mode:kind==='public binding'?0o644:0o600});
   // Set the deliberately unsafe mode explicitly: a private runner umask
   // must not silently turn this refusal fixture into an accepted binding.
   chmodSync(binding,kind==='public binding'?0o644:0o600);
   if(kind==='symlink binding'){symlinkSync(binding,join(root,'link.json'));binding=join(root,'link.json');}
   const args=[driver,...(kind==='missing binding'?[]:[binding])];
   const q=spawnSync(process.execPath,args,{encoding:'utf8',timeout:10000,env:{...process.env,WAREHOUSE_STATE_DIR:kind==='wrong state'?join(root,'other-state'):state,PATH:bin+':'+process.env.PATH}});
   assert.equal(q.signal,null);assert.notEqual(q.status,0);assert.match(q.stderr,/AssertionError/);assert.equal(existsSync(marker),false,'fixture and Docker must remain unaccessed');
  } finally {rmSync(root,{recursive:true,force:true});}
 });
}
}
