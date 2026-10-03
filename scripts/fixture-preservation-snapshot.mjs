import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, lstatSync, realpathSync, readdirSync } from 'node:fs';
import { resolve, basename } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
const hash = value => createHash('sha256').update(value).digest('hex');
const [configPath, outputPath] = process.argv.slice(2);
assert.ok(configPath && outputPath);
function privateFile(path) { const s=lstatSync(path);assert.ok(s.isFile()&&!s.isSymbolicLink()&&s.uid===process.getuid()&&(s.mode&0o077)===0);return readFileSync(path); }
const c=JSON.parse(privateFile(configPath));
assert.equal(c.mode,'read-only-preservation');
assert.match(basename(c.backendState),/^core-backend-test-[0-9]+$/);
assert.equal(realpathSync(c.evidenceRoot),resolve(c.evidenceRoot));
const es=lstatSync(c.evidenceRoot);assert.ok(es.isDirectory()&&es.uid===process.getuid()&&(es.mode&0o077)===0);
assert.equal(resolve(outputPath),resolve(c.evidenceRoot,basename(outputPath)));
const guard=resolve(c.backendCheckout,'tests/operator-fixture.mjs');assert.equal(hash(readFileSync(guard)),c.fixtureGuardSHA256);
process.env.WAREHOUSE_STATE_DIR=c.backendState;
const { operatorFixture }=await import(pathToFileURL(guard));operatorFixture();
const manifest=JSON.parse(readFileSync(resolve(c.backendState,'public/instance.json')));assert.equal(manifest.instanceId,c.instanceId);
function sql(query) {
 const q=spawnSync('bash',[resolve(c.backendCheckout,'scripts/compose.sh'),'exec','-T','db','psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],{input:query,encoding:'utf8',timeout:30000,maxBuffer:2*1024*1024});
 assert.equal(q.status,0,'Read-only SQL failed; sensitive stderr is not serialized');return q.stdout.trim();
}
const tables=JSON.parse(sql("BEGIN READ ONLY; SET LOCAL statement_timeout='15s'; SELECT coalesce(json_agg(json_build_object('schema',schemaname,'name',tablename) ORDER BY schemaname,tablename),'[]') FROM pg_tables WHERE schemaname IN ('public','warehouse_security') OR (schemaname='storage' AND tablename IN ('buckets','objects')) OR (schemaname='auth' AND tablename IN ('users','identities')); COMMIT;"));
assert.ok(tables.length>0&&tables.length<192);
const quote=value=>'"'+value.replaceAll('"','""')+'"';
const queries=tables.map(t=>{
 assert.match(t.schema,/^[a-z_][a-z0-9_]*$/i);assert.match(t.name,/^[a-z_][a-z0-9_]*$/i);
 const table=quote(t.schema)+'.'+quote(t.name),name=t.schema+'.'+t.name;
 const digest=expr=>`encode(extensions.digest(coalesce(string_agg((${expr})::text,E'\\n' ORDER BY (${expr})::text),''),'sha256'),'hex')`;
 const stable=name==='public.sms_config'?"to_jsonb(t)-'updated_at'":'to_jsonb(t)';
 return `SELECT json_build_object('table','${name}','count',count(*),'rowHash',${digest('to_jsonb(t)')},'stableHash',${digest(stable)}) FROM ${table} t`;
});
const rows=sql("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET LOCAL statement_timeout='15s'; "+queries.join(';')+'; COMMIT;').split('\n').filter(Boolean).map(x=>JSON.parse(x));
assert.equal(rows.length,tables.length);assert.ok(rows.every(x=>x.count<=100000&&/^[a-f0-9]{64}$/.test(x.rowHash)&&/^[a-f0-9]{64}$/.test(x.stableHash)));
const files={};let total=0;const storage=resolve(c.backendState,'data/storage');
assert.equal(realpathSync(storage),storage);
function walk(dir) { for(const name of readdirSync(dir).sort()) { const path=resolve(dir,name),s=lstatSync(path);assert.ok(!s.isSymbolicLink());if(s.isDirectory())walk(path);else{assert.ok(s.isFile()&&s.size<=52*1024*1024&&Object.keys(files).length<2048);total+=s.size;assert.ok(total<=256*1024*1024);files[path.slice(storage.length+1)]={size:s.size,sha256:hash(readFileSync(path))};} } }
walk(storage);
const out={status:'PASS',scope:'read-only-actual-database-and-stored-byte-snapshot',instanceId:c.instanceId,configurationSHA256:hash(privateFile(resolve(c.backendState,'config/compose.env'))),manifestSHA256:hash(readFileSync(resolve(c.backendState,'public/instance.json'))),databaseTables:rows,files,storageHash:hash(JSON.stringify(files)),declaredTimestampException:'public.sms_config.updated_at; full and stable hashes both retained',rawCredentialsOrTokensRecorded:false};
writeFileSync(outputPath,JSON.stringify(out,null,2)+'\n',{flag:'wx',mode:0o400});console.log(JSON.stringify({status:'PASS',tables:rows.length,files:Object.keys(files).length,scope:out.scope}));
