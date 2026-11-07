// Shared set-up of the WH-109 print tests (not a test file itself).
//  * fakeCups(): a real HTTP server on 127.0.0.1 that speaks IPP (the vendored ipp library parses each request and serializes the
//    answer). While it is installed, the library's http.request is routed so that the host `cups` (and nothing else) reaches it; any
//    other host is refused, so a test can never print or reach a real printer.
//  * loadFunction(): imports an edge function's index.ts with a Deno stand-in and returns the handler it registered.
//  * the signed-in token and the profile lookup answer of the other tests (access.test.mjs).
import http from 'node:http';
import { register } from 'node:module';
import { SignJWT } from 'jose';
import ipp from '../functions/vendor/ipp.mjs';

// Before any .ts file of the functions is loaded (the tests import them dynamically, after this module): see ts-transform-hooks.mjs.
register('./ts-transform-hooks.mjs', import.meta.url);

export const SECRET = 'isolated-print-test-secret-never-used-in-a-deployment';
export const USER_ID = '00000000-0000-4000-8000-000000000001';
const key = new TextEncoder().encode(SECRET);
export const signToken = (role = 'authenticated', sub = USER_ID) => new SignJWT({ role, sub })
  .setProtectedHeader({ alg: 'HS256' }).setIssuer('supabase').setExpirationTime('5m').sign(key);

/** Answers an IPP request as the reply object `{ statusCode, ...attribute groups }`; the request is parsed for the handler. */
export async function fakeCups(answer) {
  const requests = [];
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', chunk => chunks.push(chunk));
    request.on('end', () => {
      const message = ipp.parse(Buffer.concat(chunks));
      requests.push({ path: request.url, operation: message.operation, attributes: message['operation-attributes-tag'], data: message.data });
      const reply = answer(message, requests.length);
      if (reply === 'hang') return;
      if (reply === 'http-500') { response.writeHead(500); response.end(); return; }
      response.writeHead(200, { 'Content-Type': 'application/ipp' });
      response.end(ipp.serialize({
        version: '2.0', id: message.id, 'operation-attributes-tag': { 'attributes-charset': 'utf-8', 'attributes-natural-language': 'en-us' }, ...reply,
      }));
    });
  });
  const sockets = new Set();
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  const original = http.request;
  const refused = [];
  http.request = (options, callback) => {
    const host = options.hostname ?? options.host;
    if (host !== 'cups') { refused.push(String(host)); throw new Error(`print test: refusing a request to ${host}`); }
    return original({ ...options, hostname: '127.0.0.1', host: '127.0.0.1', port }, callback);
  };
  return {
    requests,
    refused,
    close: () => new Promise(resolve => { http.request = original; for (const socket of sockets) socket.destroy(); server.close(resolve); }),
  };
}

/**
 * Loads functions/<name>/index.ts and returns its handler. `environment` is read live (change it between calls). fetch is the global
 * one, replaced by the caller (see withFetch).
 */
let loads = 0;
export async function loadFunction(name, environment) {
  let handler;
  globalThis.Deno = {
    env: { get: key => environment[key] },
    serve: fn => { handler = fn; },
    readTextFile: async () => { throw new Error('no file'); },
  };
  await import(`../functions/${name}/index.ts?load=${++loads}`);
  if (typeof handler !== 'function') throw new Error(`${name} registered no handler`);
  return handler;
}

export const baseEnvironment = (extra = {}) => ({
  JWT_SECRET: SECRET, SUPABASE_URL: 'http://gateway.test', SUPABASE_SERVICE_ROLE_KEY: 'unit-service-key', ...extra,
});

/** Replaces fetch for the duration of `body`; `route(url, init)` returns a Response. Every call is recorded. */
export async function withFetch(route, body) {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const call = { url: String(url), method: init.method ?? 'GET', headers: init.headers ?? {}, body: init.body };
    calls.push(call);
    return await route(call);
  };
  try { return await body(calls); } finally { globalThis.fetch = original; }
}

export const profileAnswer = (role, active = true) => new Response(JSON.stringify([{ id: USER_ID, auth_user_id: USER_ID, name: 'Print Test User', display_name: 'Print Test User', mobile: '919766600100', role, active }]));
export const json = (status, value) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });

/** Installs only the Deno environment (for modules that read it at call time). */
export function installDeno(environment) {
  globalThis.Deno = { env: { get: key => environment[key] } };
}

/**
 * An in-memory print_jobs table behind PostgREST-shaped answers, for the real REST client (functions/_shared/supabase-rest.ts):
 * eq., in.(a,b) and lt. filters, select (an object for Accept: application/vnd.pgrst.object+json), insert with the unique index on
 * (user_id, request_id) when request_id is not null (409 23505), update, and `Prefer: return=representation`. `columnMissing`
 * answers the way a database without migration 151 does. `hooks.beforeUpdate(row, patch)` can veto (return false).
 */
export function fakePrintJobs(rows = [], { columnMissing = false } = {}) {
  const table = { rows, requests: [], columnMissing, failUpdates: 0, nextId: 1 };
  const filtersOf = params => [...params].filter(([name]) => !['select', 'order', 'limit'].includes(name)).map(([column, spec]) => {
    const dot = spec.indexOf('.');
    return { column, op: spec.slice(0, dot), value: spec.slice(dot + 1) };
  });
  const matches = (row, filters) => filters.every(({ column, op, value }) => {
    const actual = row[column];
    if (op === 'eq') return String(actual) === value;
    if (op === 'in') return value.slice(1, -1).split(',').includes(String(actual));
    if (op === 'lt') return actual !== null && actual !== undefined && new Date(actual).getTime() < new Date(value).getTime();
    throw new Error(`fakePrintJobs: operator ${op} is not implemented`);
  });
  const pick = (row, columns) => (columns === '*' || !columns ? { ...row } : Object.fromEntries(columns.split(',').map(column => [column, row[column] ?? null])));
  table.route = async ({ url, method, headers, body }) => {
    const parsed = new URL(url);
    if (!parsed.pathname.endsWith('/print_jobs')) throw new Error(`fakePrintJobs: unexpected path ${parsed.pathname}`);
    table.requests.push({ method, url, params: parsed.searchParams, body: body === undefined ? undefined : JSON.parse(body) });
    const params = parsed.searchParams;
    const filters = filtersOf(params);
    const wantsObject = (headers.Accept ?? '').includes('vnd.pgrst.object');
    const asked = (headers.Prefer ?? '').includes('return=representation');
    const answer = (list, status = 200) => {
      if (wantsObject) {
        return list.length === 1 ? json(status, list[0]) : json(406, { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned' });
      }
      return json(status, list);
    };
    if (table.columnMissing && (filters.some(f => f.column === 'request_id') || (params.get('select') ?? '').includes('request_id'))) {
      return json(400, { code: '42703', message: 'column print_jobs.request_id does not exist' });
    }
    if (method === 'GET') return answer(table.rows.filter(row => matches(row, filters)).map(row => pick(row, params.get('select'))));
    if (method === 'POST') {
      const values = JSON.parse(body);
      if (table.columnMissing && 'request_id' in values) {
        return json(400, { code: 'PGRST204', message: "Could not find the 'request_id' column of 'print_jobs' in the schema cache" });
      }
      if (values.request_id != null && table.rows.some(row => row.user_id === values.user_id && row.request_id === values.request_id)) {
        return json(409, { code: '23505', message: 'duplicate key value violates unique constraint "print_jobs_user_request_id_key"' });
      }
      const row = { id: `00000000-0000-4000-8000-${String(table.nextId++).padStart(12, '0')}`, status: 'queued', error_message: null, cups_job_id: null,
        completed_at: null, created_at: new Date().toISOString(), updated_at: new Date().toISOString(), request_id: null, ...values };
      table.rows.push(row);
      return asked ? answer([pick(row, params.get('select'))], 201) : new Response(null, { status: 201 });
    }
    if (method === 'PATCH') {
      if (table.failUpdates > 0) { table.failUpdates--; return json(500, { code: 'XX000', message: 'update failed' }); }
      const patch = JSON.parse(body);
      const changed = table.rows.filter(row => matches(row, filters));
      for (const row of changed) Object.assign(row, patch);
      return asked ? answer(changed.map(row => pick(row, params.get('select'))), 200) : new Response(null, { status: 204 });
    }
    throw new Error(`fakePrintJobs: method ${method}`);
  };
  return table;
}
