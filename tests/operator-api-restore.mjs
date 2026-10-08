// Post-restore acceptance against the restored fictional installation. Run after
// scripts/restore.sh with the backup directory as the argument: a customer approved
// before the backup logs in, a receipt saved before the backup renders a document,
// and a document stored before the backup downloads again from restored storage.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { operatorFixture } from './operator-fixture.mjs';

const backup = process.argv[2] || process.env.WAREHOUSE_BACKUP_DIR;
assert.ok(backup, 'Usage: node tests/operator-api-restore.mjs BACKUP_DIR');
const stamp = readFileSync(`${backup}/metadata.txt`, 'utf8').match(/^created_at_utc=(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/m);
assert.ok(stamp, 'backup metadata records created_at_utc');
const cutoff = `${stamp[1]}-${stamp[2]}-${stamp[3]}T${stamp[4]}:${stamp[5]}:${stamp[6]}Z`;

const { env, base, anon } = operatorFixture();
const sql = query => {
  const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`,
    `${env.WAREHOUSE_PROJECT_NAME}-db-1`, 'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1'], { input: query + '\n', encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, `private fixture SQL failed: ${result.stderr?.slice(-400)}`);
  return result.stdout.trim();
};
const quote = value => `'${String(value).replaceAll("'", "''")}'`;
const queryJson = query => JSON.parse(sql(`SELECT (${query})::text;`));
async function api(path, token = anon, body, method = body === undefined ? 'GET' : 'POST') {
  const response = await fetch(base + path, { method, headers: {
    apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json',
  }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(30000) });
  const raw = await response.text();
  let data; try { data = JSON.parse(raw); } catch { data = null; }
  return { status: response.status, ok: response.ok, data };
}
function good(result, label) {
  assert.ok(result.ok, `${label}: HTTP ${result.status}`);
  assert.equal(result.data?.success, true, `${label}: ${result.data?.code || result.data?.message || 'failed'}`);
  return result.data;
}
function login(phone, name) {
  const prepared = queryJson(`public.operator_prepare_otp(${quote(phone)})`);
  assert.equal(prepared.success, true, 'fictional challenge prepared');
  const finished = queryJson(`public.operator_finish_otp(${quote(prepared.data.request_id)}::uuid,true,'mock-provider-only')`);
  assert.equal(finished.success, true, 'mock provider accepted');
  const verified = queryJson(`public.operator_verify_otp(${quote(phone)},${quote(prepared.data.otp_code)},${quote(name)})`);
  assert.equal(verified.success, true, 'fictional login verified');
  return verified.data;
}
async function pdf(url, label) {
  const download = await fetch(url, { signal: AbortSignal.timeout(30000) });
  assert.equal(download.status, 200, `${label}: HTTP ${download.status}`);
  const bytes = new Uint8Array(await download.arrayBuffer());
  assert.equal(new TextDecoder().decode(bytes.slice(0, 5)), '%PDF-', `${label}: valid PDF bytes`);
}

// 1. Identity restored: the customer approved by the core run still logs in.
const session = login('919888888872', 'Customer A').session;
assert.ok(session?.access_token, 'restored customer receives a session');
const token = session.access_token;

// 2. Business data restored: the receipt saved before the backup renders again.
const generated = good(await api('/functions/v1/generate-grn-pdf', token, { gr_no: 'BAA01' }), 'generate-grn-pdf after restore');
const signed = new URL(generated.pdf_url);
assert.equal(signed.origin, env.SUPABASE_PUBLIC_URL, 'document uses configured origin');
await pdf(base + signed.pathname + signed.search, 'document generated after restore');

// 3. Object bytes restored: the oldest document stored before the backup is served
//    from the restored storage directory through a signed URL.
const name = sql(`SELECT name FROM storage.objects WHERE bucket_id='documents' AND created_at < ${quote(cutoff)}::timestamptz ORDER BY created_at, name LIMIT 1`);
assert.ok(name, 'a document stored before the backup exists in the restored catalog');
const path = name.split('/').map(encodeURIComponent).join('/');
const sign = await fetch(`${base}/storage/v1/object/sign/documents/${path}`, { method: 'POST', headers: {
  apikey: anon, Authorization: `Bearer ${env.SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json',
}, body: JSON.stringify({ expiresIn: 60 }), signal: AbortSignal.timeout(30000) });
assert.equal(sign.status, 200, `service role signs the pre-backup document: HTTP ${sign.status}`);
const { signedURL } = await sign.json();
assert.ok(typeof signedURL === 'string' && signedURL.startsWith('/object/sign/documents/'), 'signed URL shape');
await pdf(`${base}/storage/v1${signedURL}`, 'pre-backup document after restore');
for (const reader of [anon, token]) assert.ok(!(await api(`/storage/v1/object/documents/${path}`, reader)).ok, 'private PDF bucket still denies direct reads');
console.log(`Restored instance passed: pre-backup customer login, document generation for BAA01 and download of ${name}.`);
