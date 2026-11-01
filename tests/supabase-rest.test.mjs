import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { restClient, Builder, StorageBucket, RestClient } from '../functions/_shared/supabase-rest.ts';

// Replaces fetch with a recorder that answers from a queue.
function mockFetch(...answers) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    const answer = answers.shift();
    if (answer instanceof Error) throw answer;
    if (typeof answer === 'function') return answer(init);
    if (answer.response) return answer.response;
    return new Response(answer.body === undefined ? null : typeof answer.body === 'string' ? answer.body : JSON.stringify(answer.body),
      { status: answer.status ?? 200, headers: answer.headers ?? {} });
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}

test('a table read sends the filters, the key headers and the caller token', async () => {
  const mock = mockFetch({ body: [{ id: 'c1', name: 'A' }] });
  try {
    const client = restClient('http://gateway:8000/', 'anon-key', { authorization: 'Bearer caller' });
    const result = await client.from('customers').select('id,name').eq('id', 'c1').is('deleted_at', null).limit(5);
    assert.deepEqual(result, { data: [{ id: 'c1', name: 'A' }], error: null, count: null });
    const { url, init } = mock.calls[0];
    assert.equal(url, 'http://gateway:8000/rest/v1/customers?select=id%2Cname&id=eq.c1&deleted_at=is.null&limit=5');
    assert.equal(init.method, 'GET');
    assert.equal(init.headers.apikey, 'anon-key');
    assert.equal(init.headers.Authorization, 'Bearer caller');
    assert.equal(init.redirect, 'error');
    assert.ok(init.signal);
  } finally { mock.restore(); }
});

test('without a caller token the key is also the bearer token', async () => {
  const mock = mockFetch({ body: [] });
  try {
    await restClient('http://gateway:8000', 'service-key').from('system_settings').select('value');
    assert.equal(mock.calls[0].init.headers.Authorization, 'Bearer service-key');
  } finally { mock.restore(); }
});

test('single asks for one object and reports an error when PostgREST refuses', async () => {
  const mock = mockFetch({ body: { id: 'c1' } }, { status: 406, body: { code: 'PGRST116', message: 'no rows', details: 'd', hint: null } });
  try {
    const client = restClient('http://gateway:8000', 'k');
    const ok = await client.from('customers').select('id').eq('id', 'c1').single();
    assert.deepEqual(ok.data, { id: 'c1' });
    assert.equal(mock.calls[0].init.headers.Accept, 'application/vnd.pgrst.object+json');
    const missing = await client.from('customers').select('id').eq('id', 'x').single();
    assert.equal(missing.data, null);
    assert.equal(missing.error.code, 'PGRST116');
    assert.equal(missing.error.message, 'no rows');
  } finally { mock.restore(); }
});

test('maybeSingle gives null for no row, the row for one and an error for several', async () => {
  const mock = mockFetch({ body: [] }, { body: [{ id: 1 }] }, { body: [{ id: 1 }, { id: 2 }] });
  try {
    const client = restClient('http://gateway:8000', 'k');
    assert.deepEqual(await client.from('t').select('id').maybeSingle(), { data: null, error: null, count: null });
    assert.deepEqual((await client.from('t').select('id').maybeSingle()).data, { id: 1 });
    const many = await client.from('t').select('id').maybeSingle();
    assert.equal(many.data, null);
    assert.equal(many.error.code, 'PGRST116');
  } finally { mock.restore(); }
});

test('an exact count is read from Content-Range; embedded filters and gt are passed', async () => {
  const mock = mockFetch({ body: [{ a: 1 }], headers: { 'content-range': '0-0/1234' } });
  try {
    const result = await restClient('http://gateway:8000', 'k').from('goodsreceived_trl')
      .select('item_name,goodsreceived!inner(gr_no)', { count: 'exact' }).eq('goodsreceived.customer_id', 'u').gt('stock', 0).limit(1001);
    assert.equal(result.count, 1234);
    assert.equal(mock.calls[0].init.headers.Prefer, 'count=exact');
    assert.match(mock.calls[0].url, /goodsreceived\.customer_id=eq\.u&stock=gt\.0&limit=1001$/);
  } finally { mock.restore(); }
});

test('insert with select and single returns the new row; update filters by id', async () => {
  const mock = mockFetch({ status: 201, body: { id: 'job1' } }, { status: 204 });
  try {
    const client = restClient('http://gateway:8000', 'k');
    const added = await client.from('print_jobs').insert({ status: 'printing' }).select().single();
    assert.deepEqual(added.data, { id: 'job1' });
    assert.equal(mock.calls[0].init.method, 'POST');
    assert.equal(mock.calls[0].init.body, '{"status":"printing"}');
    assert.equal(mock.calls[0].init.headers.Prefer, 'return=representation');
    assert.equal(mock.calls[0].init.headers['Content-Type'], 'application/json');
    const changed = await client.from('print_jobs').update({ status: 'completed' }).eq('id', 'job1');
    assert.deepEqual(changed, { data: null, error: null, count: null });
    assert.equal(mock.calls[1].init.method, 'PATCH');
    assert.match(mock.calls[1].url, /\/rest\/v1\/print_jobs\?id=eq\.job1$/);
  } finally { mock.restore(); }
});

test('rpc posts the arguments and returns the JSON answer or the error code', async () => {
  const mock = mockFetch({ body: { success: true } }, { status: 403, body: { code: '42501', message: 'denied' } }, new TypeError('connection refused'));
  try {
    const client = restClient('http://gateway:8000', 'k', { authorization: 'Bearer t' });
    const ok = await client.rpc('get_report', { from: '2026-01-01' });
    assert.deepEqual(ok.data, { success: true });
    assert.equal(mock.calls[0].url, 'http://gateway:8000/rest/v1/rpc/get_report');
    assert.equal(mock.calls[0].init.body, '{"from":"2026-01-01"}');
    const refused = await client.rpc('get_report');
    assert.equal(refused.error.code, '42501');
    const down = await client.rpc('get_report');
    assert.equal(down.data, null);
    assert.match(down.error.message, /connection refused/);
  } finally { mock.restore(); }
});

test('with the direct service addresses set, calls skip the gateway prefixes and send only the key headers', async () => {
  const environment = { SUPABASE_REST_URL: 'http://rest:3000/', SUPABASE_STORAGE_URL: 'http://storage:5000' };
  globalThis.Deno = { env: { get: name => environment[name] } };
  const mock = mockFetch({ body: [{ id: 'c1' }] }, { body: { ok: true } }, { body: { Key: 'k' } }, { body: { signedURL: '/object/sign/documents/a.pdf?token=t' } });
  try {
    const client = restClient('http://gateway:8000', 'anon', { authorization: 'Bearer caller' });
    await client.from('customers').select('id').eq('id', 'c1');
    await client.rpc('get_report', { a: 1 });
    const bucket = client.storage.from('documents');
    await bucket.upload('a.pdf', new Uint8Array([1]));
    const signed = await bucket.createSignedUrl('a.pdf', 60);
    assert.deepEqual(mock.calls.map(call => call.url), [
      'http://rest:3000/customers?select=id&id=eq.c1',
      'http://rest:3000/rpc/get_report',
      'http://storage:5000/object/documents/a.pdf',
      'http://storage:5000/object/sign/documents/a.pdf',
    ]);
    // Nothing but the key headers is sent: no client address header reaches Storage.
    for (const call of mock.calls) {
      assert.deepEqual(Object.keys(call.init.headers).map(name => name.toLowerCase()).filter(name => /ip|forwarded/.test(name)), []);
      assert.equal(call.init.headers.apikey, 'anon');
    }
    // The signed URL keeps the public gateway path, which is where the app uses it.
    assert.equal(signed.data.signedUrl, 'http://gateway:8000/storage/v1/object/sign/documents/a.pdf?token=t');
    // One address without the other: everything keeps going through the gateway.
  } finally { mock.restore(); delete globalThis.Deno; }
  const half = mockFetch({ body: [] });
  globalThis.Deno = { env: { get: name => ({ SUPABASE_REST_URL: 'http://rest:3000' })[name] } };
  try {
    await restClient('http://gateway:8000', 'k').from('t').select('id');
    assert.equal(half.calls[0].url, 'http://gateway:8000/rest/v1/t?select=id');
  } finally { half.restore(); delete globalThis.Deno; }
});

test('storage upload and signed url use the object endpoints', async () => {
  const mock = mockFetch({ body: { Key: 'documents/grn/1/a.pdf' } }, { body: { signedURL: '/object/sign/documents/grn/1/a.pdf?token=abc' } }, { status: 400, body: { message: 'Duplicate', error: 'Duplicate' } });
  try {
    const bucket = restClient('http://gateway:8000', 'service').storage.from('documents');
    const pdf = new Uint8Array([37, 80, 68, 70]);
    const upload = await bucket.upload('grn/1/a.pdf', pdf, { contentType: 'application/pdf', upsert: false });
    assert.equal(upload.error, null);
    assert.equal(mock.calls[0].url, 'http://gateway:8000/storage/v1/object/documents/grn/1/a.pdf');
    assert.equal(mock.calls[0].init.method, 'POST');
    assert.equal(mock.calls[0].init.headers['Content-Type'], 'application/pdf');
    assert.equal(mock.calls[0].init.headers['x-upsert'], 'false');
    assert.equal(mock.calls[0].init.headers.apikey, 'service');
    assert.equal(mock.calls[0].init.body, pdf);
    const signed = await bucket.createSignedUrl('grn/1/a.pdf', 3600);
    assert.equal(signed.data.signedUrl, 'http://gateway:8000/storage/v1/object/sign/documents/grn/1/a.pdf?token=abc');
    assert.equal(mock.calls[1].init.body, '{"expiresIn":3600}');
    const duplicate = await bucket.upload('grn/1/a.pdf', pdf, { contentType: 'application/pdf' });
    assert.equal(duplicate.error.message, 'Duplicate');
  } finally { mock.restore(); }
});

test('order follows postgrest-js: direction, nulls placement, several calls joined', async () => {
  const mock = mockFetch({ body: { provider: 'log' } }, { body: [] });
  try {
    const client = restClient('http://gateway:8000', 'k');
    const one = await client.from('sms_config').select('production_mode,provider').order('id', { ascending: false }).limit(1).single();
    assert.deepEqual(one.data, { provider: 'log' });
    assert.equal(mock.calls[0].url, 'http://gateway:8000/rest/v1/sms_config?select=production_mode%2Cprovider&order=id.desc&limit=1');
    assert.equal(mock.calls[0].init.headers.Accept, 'application/vnd.pgrst.object+json');
    await client.from('t').select('*').order('a').order('b', { ascending: false, nullsFirst: true }).order('c', { nullsFirst: false });
    assert.match(mock.calls[1].url, /\?select=\*&order=a\.asc%2Cb\.desc\.nullsfirst%2Cc\.asc\.nullslast$/);
  } finally { mock.restore(); }
});

test('filter values with a comma, space, quote, null and true are encoded', async () => {
  const mock = mockFetch({ body: [] });
  try {
    await restClient('http://gateway:8000', 'k').from('t').select('id').eq('a', 'x,y z').eq('b', "it's \"q\"").eq('c', null).is('d', true).is('e', null);
    const params = new URL(mock.calls[0].url).searchParams;
    assert.equal(params.get('a'), 'eq.x,y z');
    assert.equal(params.get('b'), 'eq.it\'s "q"');
    assert.equal(params.get('c'), 'eq.null');
    assert.equal(params.get('d'), 'is.true');
    assert.equal(params.get('e'), 'is.null');
    assert.ok(!mock.calls[0].url.includes(' ') && !mock.calls[0].url.includes('"'));
  } finally { mock.restore(); }
});

test('a non-JSON error body (an HTML 502 from the gateway) becomes error.message', async () => {
  const mock = mockFetch({ status: 502, body: '<html>Bad Gateway</html>' }, { status: 503 });
  try {
    const client = restClient('http://gateway:8000', 'k');
    const html = await client.from('t').select('id');
    assert.equal(html.data, null);
    assert.equal(html.error.message, '<html>Bad Gateway</html>');
    const empty = await client.rpc('x');
    assert.equal(empty.error.message, 'HTTP 503');
  } finally { mock.restore(); }
});

test('a non-JSON 2xx body gives data null plus an error', async () => {
  const mock = mockFetch({ body: 'oops' }, { body: 'oops' });
  try {
    const client = restClient('http://gateway:8000', 'k');
    const table = await client.from('t').select('id');
    assert.equal(table.data, null);
    assert.ok(table.error);
    const rpc = await client.rpc('x');
    assert.equal(rpc.data, null);
    assert.ok(rpc.error);
  } finally { mock.restore(); }
});

test('a timeout becomes an error, not a throw', async () => {
  const hang = (init) => new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(init.signal.reason)));
  const mock = mockFetch(hang, hang, hang);
  const keepAlive = setInterval(() => {}, 1000); // AbortSignal.timeout does not keep the process alive
  try {
    const client = restClient('http://gateway:8000', 'k', { timeoutMs: 20 });
    const table = await client.from('t').select('id');
    assert.equal(table.data, null);
    assert.match(table.error.message, /Timeout|Abort/);
    assert.ok((await client.rpc('x')).error);
    assert.ok((await client.storage.from('b').upload('p', new Uint8Array([1]))).error);
  } finally { clearInterval(keepAlive); mock.restore(); }
});

test('a failed body read is an error result, not a rejection', async () => {
  const broken = () => new Response(new ReadableStream({ start(controller) { controller.error(new Error('stream broke')); } }), { status: 200 });
  const brokenFailure = () => new Response(new ReadableStream({ start(controller) { controller.error(new Error('stream broke')); } }), { status: 500 });
  const mock = mockFetch({ response: broken() }, { response: broken() }, { response: brokenFailure() });
  try {
    const client = restClient('http://gateway:8000', 'k');
    const table = await client.from('t').select('id');
    assert.equal(table.data, null);
    assert.match(table.error.message, /stream broke/);
    assert.match((await client.rpc('x')).error.message, /stream broke/);
    const failed = await client.from('t').select('id');
    assert.equal(failed.data, null);
    assert.ok(failed.error);
  } finally { mock.restore(); }
});

test('201 and 204 with an empty body give data null and no error', async () => {
  const mock = mockFetch({ status: 201 }, { status: 204 }, { status: 204 });
  try {
    const client = restClient('http://gateway:8000', 'k');
    assert.deepEqual(await client.from('t').insert({ a: 1 }), { data: null, error: null, count: null });
    assert.deepEqual(await client.from('t').update({ a: 1 }).eq('id', 1), { data: null, error: null, count: null });
    assert.deepEqual(await client.rpc('x'), { data: null, error: null, count: null });
  } finally { mock.restore(); }
});

test('insert().select() with count exact sends both Prefer values', async () => {
  const mock = mockFetch({ status: 201, body: [{ id: 1 }], headers: { 'content-range': '0-0/1' } });
  try {
    const result = await restClient('http://gateway:8000', 'k').from('t').insert({ a: 1 }).select('id', { count: 'exact' });
    assert.equal(mock.calls[0].init.headers.Prefer, 'return=representation,count=exact');
    assert.equal(result.count, 1);
  } finally { mock.restore(); }
});

test('content-range with an unknown total gives count null', async () => {
  const mock = mockFetch({ body: [{ a: 1 }], headers: { 'content-range': '0-0/*' } });
  try {
    const result = await restClient('http://gateway:8000', 'k').from('t').select('a', { count: 'exact' });
    assert.equal(result.count, null);
  } finally { mock.restore(); }
});

test('maybeSingle sends Accept application/json; several rows give count null', async () => {
  const mock = mockFetch({ body: [{ id: 1 }, { id: 2 }], headers: { 'content-range': '0-1/2' } });
  try {
    const result = await restClient('http://gateway:8000', 'k').from('t').select('id', { count: 'exact' }).maybeSingle();
    assert.equal(mock.calls[0].init.headers.Accept, 'application/json');
    assert.equal(result.error.code, 'PGRST116');
    assert.equal(result.count, null);
  } finally { mock.restore(); }
});

test('storage: network error, default content type, signed url failures', async () => {
  const mock = mockFetch(new TypeError('connection refused'), { body: {} }, { status: 404, body: { message: 'Object not found' } }, { body: {} }, new TypeError('down'));
  try {
    const bucket = restClient('http://gateway:8000', 'k').storage.from('documents');
    const down = await bucket.upload('a/b.pdf', new Uint8Array([1]));
    assert.equal(down.data, null);
    assert.match(down.error.message, /connection refused/);
    const ok = await bucket.upload('a/b.pdf', new Uint8Array([1]));
    assert.equal(ok.error, null);
    assert.equal(mock.calls[1].init.headers['Content-Type'], 'application/octet-stream');
    assert.equal(mock.calls[1].init.headers['x-upsert'], 'false');
    const missing = await bucket.createSignedUrl('a/b.pdf', 60);
    assert.equal(missing.error.message, 'Object not found');
    const noUrl = await bucket.createSignedUrl('a/b.pdf', 60);
    assert.equal(noUrl.data, null);
    assert.ok(noUrl.error);
    assert.match((await bucket.createSignedUrl('a/b.pdf', 60)).error.message, /down/);
  } finally { mock.restore(); }
});

// Guard: every builder or storage method a function calls must exist in the helper,
// or the call throws a TypeError at run time (get-config once used .order()).
test('every query method the functions call exists in the helper', () => {
  const root = new URL('../functions/', import.meta.url).pathname;
  const files = [];
  (function walk(dir) {
    for (const name of readdirSync(dir)) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) { if (name !== 'vendor') walk(path); }
      else if (name.endsWith('.ts') && path !== join(root, '_shared/supabase-rest.ts')) files.push(path);
    }
  })(root);
  const methods = (proto) => new Set(Object.getOwnPropertyNames(proto).filter((n) => !['constructor', 'run', 'execute', 'then'].includes(n)));
  const builder = methods(Builder.prototype);
  const bucket = methods(StorageBucket.prototype);
  const client = methods(RestClient.prototype);
  let chains = 0;
  for (const file of files) {
    const source = readFileSync(file, 'utf8');
    if (!source.includes('supabase-rest.ts')) continue;
    for (const match of source.matchAll(/(?:\b(?:supabase|client|reader|writer)\s*|\n\s*)\.from\(/g)) {
      const statement = source.slice(match.index, source.indexOf(';', match.index));
      for (const [, name] of statement.slice(match[0].length).matchAll(/\)\s*\.(\w+)\(/g)) {
        chains++;
        assert.ok(builder.has(name), `${file}: .${name}() is not implemented by the helper's Builder`);
      }
    }
    for (const match of source.matchAll(/\.storage\.from\([^)]*\)\s*\.(\w+)\(/g)) {
      chains++;
      assert.ok(bucket.has(match[1]), `${file}: storage .${match[1]}() is not implemented`);
    }
    for (const match of source.matchAll(/\b(?:supabase|client|reader|writer)\s*\.(\w+)\(/g)) {
      assert.ok(client.has(match[1]), `${file}: client .${match[1]}() is not implemented`);
    }
  }
  assert.ok(chains > 20, 'the guard found the caller chains');
});
