import test from 'node:test';
import assert from 'node:assert/strict';
import { baseEnvironment, fakePrintJobs, loadFunction, signToken, withFetch } from './print-harness.mjs';

// WH-109 part 4: sweep-print-jobs settles a job nothing follows any more. A row still queued or printing more than 5 minutes after it
// was created becomes 'unknown' with a note, never 'completed'. Service-role key only. The real handler and REST client run against an
// in-memory print_jobs table that applies the filters the way PostgREST does.
const NOW = Date.parse('2026-11-07T10:00:00.000Z');
const minutesAgo = (minutes, seconds = 0) => new Date(NOW - (minutes * 60 + seconds) * 1000).toISOString();
const row = (id, status, created_at, extra = {}) => ({ id, status, created_at, user_id: 'u', error_message: null, completed_at: null, updated_at: created_at, ...extra });
const NOTE = 'The job did not report an end. Check the printer.';

async function sweep({ rows = [], token, environment = baseEnvironment(), route } = {}) {
  const table = fakePrintJobs(rows);
  const handler = await loadFunction('sweep-print-jobs', environment);
  const realNow = Date.now;
  Date.now = () => NOW;
  try {
    return await withFetch(route ?? table.route, async (calls) => {
      const headers = {};
      if (token !== null) headers.Authorization = `Bearer ${token ?? await signToken('service_role')}`;
      const response = await handler(new Request('http://edge.test/sweep-print-jobs', { method: 'POST', headers }));
      return { response, answer: await response.json(), table, calls };
    });
  } finally { Date.now = realNow; }
}
const byId = (table, id) => table.rows.find(r => r.id === id);

test('the 5-minute boundary: older than 5 minutes is settled; exactly 5 minutes and younger are left alone', async () => {
  const { response, answer, table } = await sweep({ rows: [
    row('young', 'printing', minutesAgo(0, 30)),
    row('four-fifty-nine', 'queued', minutesAgo(4, 59)),
    row('exactly-five', 'printing', minutesAgo(5)),
    row('five-and-a-second', 'printing', minutesAgo(5, 1)),
    row('old-queued', 'queued', minutesAgo(90)),
  ] });
  assert.equal(response.status, 200);
  assert.deepEqual(answer, { success: true, settled: 2 });
  assert.deepEqual(['young', 'four-fifty-nine', 'exactly-five'].map(id => byId(table, id).status), ['printing', 'queued', 'printing']);
  assert.deepEqual(['five-and-a-second', 'old-queued'].map(id => byId(table, id).status), ['unknown', 'unknown']);
});

test('a settled row is unknown with the note, never completed, with no completed_at', async () => {
  const { table, calls } = await sweep({ rows: [row('old', 'printing', minutesAgo(10), { cups_job_id: 41 })] });
  const settled = byId(table, 'old');
  assert.equal(settled.status, 'unknown');
  assert.equal(settled.error_message, NOTE);
  assert.equal(settled.completed_at, null);
  assert.equal(settled.cups_job_id, 41, 'the job id is kept');
  assert.equal(settled.updated_at, new Date(NOW).toISOString());
  const patch = JSON.parse(calls.find(c => c.method === 'PATCH').body);
  assert.deepEqual(Object.keys(patch).sort(), ['error_message', 'status', 'updated_at']);
  assert.equal(patch.status === 'completed', false);
});

test('only queued and printing rows are touched: every final state stays as it is, however old', async () => {
  const finals = ['completed', 'cancelled', 'failed', 'unknown'].map(status => row(status, status, minutesAgo(600), { error_message: `keep ${status}` }));
  const { answer, table } = await sweep({ rows: finals });
  assert.deepEqual(answer, { success: true, settled: 0 });
  for (const final of finals) assert.deepEqual([byId(table, final.id).status, byId(table, final.id).error_message], [final.status, `keep ${final.status}`]);
});

test('the request filters on both the status and the age, so a row settled in between by the monitor or a cancel is left alone', async () => {
  const { calls } = await sweep({ rows: [] });
  const patch = calls.find(c => c.method === 'PATCH');
  const params = new URL(patch.url).searchParams;
  assert.equal(params.get('status'), 'in.(queued,printing)');
  assert.equal(params.get('created_at'), `lt.${minutesAgo(5)}`, 'strictly older than 5 minutes');
  assert.equal(params.get('select'), 'id');
});

test('a user token is refused (403), the anon key is refused, no token is 401; nothing is written', async () => {
  for (const [role, status] of [['authenticated', 403], ['anon', 403]]) {
    const { response, answer, calls } = await sweep({ rows: [row('old', 'printing', minutesAgo(10))], token: await signToken(role) });
    assert.equal(response.status, status, role);
    assert.deepEqual(answer, { success: false, error: 'Service access required' });
    assert.equal(calls.length, 0, 'the database was not called');
  }
  const none = await sweep({ rows: [row('old', 'printing', minutesAgo(10))], token: null });
  assert.equal(none.response.status, 401);
  assert.equal(none.calls.length, 0);
  assert.equal(byId(none.table, 'old').status, 'printing');
  const forged = await sweep({ token: 'not.a.token' });
  assert.equal(forged.response.status, 401);
});

test('a database failure is 503 "The sweep failed" without the database text; missing configuration is 500', async () => {
  const failing = await sweep({ route: async () => new Response(JSON.stringify({ code: '57P03', message: 'the database system is starting up' }), { status: 503 }) });
  assert.equal(failing.response.status, 503);
  assert.deepEqual(failing.answer, { success: false, error: 'The sweep failed' });
  const unconfigured = await sweep({ environment: baseEnvironment({ SUPABASE_URL: '' }) });
  assert.equal(unconfigured.response.status, 500);
  assert.deepEqual(unconfigured.answer, { success: false, error: 'Server configuration missing' });
});
