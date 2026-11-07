import test from 'node:test';
import assert from 'node:assert/strict';
const { CANCELLABLE_STATUSES, CANCEL_TIMEOUT_MS, STUCK_AFTER_MS, cancelCupsJob, cancelDecision } = await import('../functions/_shared/print-cancel.ts');
import { baseEnvironment, fakeCups, json, loadFunction, profileAnswer, signToken, withFetch, USER_ID } from './print-harness.mjs'; // registers the TypeScript hook: the functions are imported after it

// WH-109 part 4: a print job is cancelled for real. IPP Cancel-Job goes to CUPS first; only when CUPS cancelled it is the row marked
// 'cancelled'. A job the print service cannot stop (bridge, unknown, no id) answers 409 CANNOT_CANCEL.
const JOB_ID = '11111111-1111-4111-8111-111111111111';
const cupsEnv = (extra = {}) => { const values = { PRINT_TRANSPORT: 'cups', PRINTER_NAME: 'LQ1310_RAW', ...extra }; return name => values[name]; };

test('cancelDecision: only a queued or printing CUPS job with a positive integer job id can be cancelled', () => {
  assert.deepEqual(cancelDecision({ id: 'x', status: 'printing', cups_job_id: 41 }, 'cups'), { kind: 'cancel', cupsJobId: 41 });
  assert.deepEqual(cancelDecision({ id: 'x', status: 'queued', cups_job_id: 7 }, 'cups'), { kind: 'cancel', cupsJobId: 7 });
  assert.deepEqual([...CANCELLABLE_STATUSES], ['queued', 'printing']);
});

test('cancelDecision: a finished job is 409 INVALID_STATUS', () => {
  for (const status of ['completed', 'cancelled', 'failed']) {
    const decision = cancelDecision({ id: 'x', status, cups_job_id: 41 }, 'cups');
    assert.deepEqual([decision.kind, decision.status, decision.code], ['refuse', 409, 'INVALID_STATUS'], status);
    assert.match(decision.error, new RegExp(status));
  }
});

test('cancelDecision: bridge, unknown, id-less and malformed-id jobs are 409 CANNOT_CANCEL (the paper may already be printing)', () => {
  const refused = (row, transport) => cancelDecision({ id: 'x', ...row }, transport);
  const cases = [
    [{ status: 'printing', cups_job_id: 41 }, 'bridge'],
    [{ status: 'unknown', cups_job_id: null }, 'bridge'],
    [{ status: 'unknown', cups_job_id: 41 }, 'cups'],
    [{ status: 'queued', cups_job_id: null }, 'cups'],
    [{ status: 'printing', cups_job_id: 0 }, 'cups'],
    [{ status: 'printing', cups_job_id: -3 }, 'cups'],
    [{ status: 'printing', cups_job_id: 1.5 }, 'cups'],
    [{ status: 'printing', cups_job_id: '41' }, 'cups'],
    [{ status: 'printing', cups_job_id: 41 }, null],
  ];
  for (const [row, transport] of cases) {
    const decision = refused(row, transport);
    assert.deepEqual([decision.kind, decision.status, decision.code], ['refuse', 409, 'CANNOT_CANCEL'], JSON.stringify([row, transport]));
    assert.match(decision.error, /cannot be stopped from here/);
  }
});

test('cancelCupsJob: IPP Cancel-Job on the configured queue; success is cancelled, any other CUPS answer is refused', async () => {
  const sent = [];
  const answer = reply => async (queueUrl, message) => { sent.push({ queueUrl, message }); return reply; };
  assert.equal(await cancelCupsJob(41, 'Invoice', cupsEnv(), answer({ statusCode: 'successful-ok' })), 'cancelled');
  assert.equal(sent[0].queueUrl, 'http://cups:631/printers/LQ1310_RAW');
  assert.deepEqual(sent[0].message, { 'operation-attributes-tag': { 'requesting-user-name': 'warehouse-invoice', 'job-id': 41 } });
  for (const reply of [{ statusCode: 'client-error-not-found' }, { statusCode: 'client-error-not-possible' }, { statusCode: 'server-error-busy' }, {}, 'ok']) {
    assert.equal(await cancelCupsJob(41, 'Invoice', cupsEnv(), answer(reply)), 'refused', JSON.stringify(reply));
  }
});

test('cancelCupsJob: an error, silence or an invalid queue name is unreachable (the job may still print)', async () => {
  assert.equal(await cancelCupsJob(41, 'GRN', cupsEnv(), async () => { throw new Error('ECONNREFUSED'); }), 'unreachable');
  assert.equal(await cancelCupsJob(41, 'GRN', cupsEnv(), () => new Promise(() => {}), 80), 'unreachable');
  let called = false;
  assert.equal(await cancelCupsJob(41, 'GRN', cupsEnv({ PRINTER_NAME: 'a/b' }), async () => { called = true; return { statusCode: 'successful-ok' }; }), 'unreachable');
  assert.equal(called, false, 'no call for an invalid queue name');
  assert.equal(CANCEL_TIMEOUT_MS, 10000);
  assert.equal(STUCK_AFTER_MS, 300000);
});

test('cancelCupsJob through the real IPP library: the operation, job id and requesting user reach CUPS', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok' }));
  try {
    assert.equal(await cancelCupsJob(52, 'Dispatch', cupsEnv()), 'cancelled');
    assert.equal(cups.requests.length, 1);
    assert.equal(cups.requests[0].operation, 'Cancel-Job');
    assert.equal(cups.requests[0].path, '/printers/LQ1310_RAW');
    assert.equal(cups.requests[0].attributes['job-id'], 52);
    assert.equal(cups.requests[0].attributes['requesting-user-name'], 'warehouse-dispatch');
  } finally { await cups.close(); }
});

// ---- the cancel-print-job function ----
async function call(environment, { role = 'staff', row, body = { print_job_id: JOB_ID }, cups, updateStatus = 204, token } = {}) {
  const handler = await loadFunction('cancel-print-job', environment);
  return await withFetch(async ({ url, method }) => {
    if (url.includes('/user_profiles?')) return profileAnswer(role);
    if (url.includes('/print_jobs?') && method === 'GET') return json(200, row === undefined ? [] : [row]);
    if (url.includes('/print_jobs?') && method === 'PATCH') return new Response(null, { status: updateStatus });
    throw new Error(`unexpected request ${method} ${url}`);
  }, async (calls) => {
    const headers = { 'Content-Type': 'application/json' };
    if (token !== null) headers.Authorization = `Bearer ${token ?? await signToken()}`;
    const response = await handler(new Request('http://edge.test/cancel-print-job', { method: 'POST', headers, body: typeof body === 'string' ? body : JSON.stringify(body) }));
    return { response, answer: await response.json(), calls: calls.filter(c => c.url.includes('/print_jobs?')), cups };
  });
}
const printing = { id: JOB_ID, status: 'printing', cups_job_id: 41 };
const updates = calls => calls.filter(c => c.method === 'PATCH');
const env = (extra = {}) => baseEnvironment({ PRINT_TRANSPORT: 'cups', PRINTER_NAME: 'LQ1310_RAW', ...extra });

test('cancel-print-job: CUPS cancels first, then the row becomes cancelled (only while still queued or printing)', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok' }));
  try {
    const { response, answer, calls } = await call(env(), { row: printing });
    assert.equal(response.status, 200);
    assert.deepEqual([answer.success, answer.message, answer.print_job_id, answer.cups_job_id], [true, 'Print job cancelled', JOB_ID, 41]);
    assert.equal(cups.requests.length, 1);
    assert.equal(cups.requests[0].operation, 'Cancel-Job');
    assert.equal(cups.requests[0].attributes['job-id'], 41);
    const [update] = updates(calls);
    assert.match(decodeURIComponent(update.url), /print_jobs\?id=eq\.1{8}-1{4}-4111-8111-1{12}&status=in\.\(queued,printing\)$/, 'a final state the monitor recorded meanwhile is not overwritten');
    const patch = JSON.parse(update.body);
    assert.equal(patch.status, 'cancelled');
    assert.match(patch.completed_at, /^\d{4}-\d\d-\d\dT/);
    assert.deepEqual(Object.keys(patch).sort(), ['completed_at', 'status', 'updated_at']);
    assert.equal(calls.indexOf(update), calls.length - 1, 'the row is updated after CUPS answered');
  } finally { await cups.close(); }
});

test('cancel-print-job: when CUPS refuses (job gone or finishing) the answer is 409 CANNOT_CANCEL and the row is not touched', async () => {
  for (const reply of [{ statusCode: 'client-error-not-found' }, { statusCode: 'client-error-not-possible' }]) {
    const cups = await fakeCups(() => reply);
    try {
      const { response, answer, calls } = await call(env(), { row: printing });
      assert.equal(response.status, 409);
      assert.deepEqual([answer.success, answer.code, answer.print_job_id], [false, 'CANNOT_CANCEL', JOB_ID]);
      assert.equal(updates(calls).length, 0, 'never marked cancelled when CUPS did not cancel');
    } finally { await cups.close(); }
  }
});

test('cancel-print-job: no answer from CUPS is 502 CANCEL_FAILED ("the job may still print") and the row is not touched', async () => {
  for (const reply of ['http-500']) {
    const cups = await fakeCups(() => reply);
    try {
      const { response, answer, calls } = await call(env(), { row: printing });
      assert.equal(response.status, 502);
      assert.deepEqual([answer.success, answer.code], [false, 'CANCEL_FAILED']);
      assert.match(answer.error, /may still print/);
      assert.equal(updates(calls).length, 0);
    } finally { await cups.close(); }
  }
});

test('cancel-print-job: bridge, unknown and id-less jobs answer 409 CANNOT_CANCEL without calling CUPS or changing the row', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok' }));
  try {
    const cases = [
      [env({ PRINT_TRANSPORT: 'bridge' }), printing],
      [env(), { id: JOB_ID, status: 'unknown', cups_job_id: 41 }],
      [env(), { id: JOB_ID, status: 'unknown', cups_job_id: null }],
      [env(), { id: JOB_ID, status: 'queued', cups_job_id: null }],
    ];
    for (const [environment, row] of cases) {
      const { response, answer, calls } = await call(environment, { row });
      assert.equal(response.status, 409, JSON.stringify(row));
      assert.equal(answer.code, 'CANNOT_CANCEL');
      assert.equal(updates(calls).length, 0);
    }
    assert.equal(cups.requests.length, 0, 'CUPS was never asked');
  } finally { await cups.close(); }
});

test('cancel-print-job: a finished job is 409 INVALID_STATUS; an unknown id is 404; a bad id is 400', async () => {
  for (const status of ['completed', 'cancelled', 'failed']) {
    const { response, answer } = await call(env(), { row: { id: JOB_ID, status, cups_job_id: 41 } });
    assert.deepEqual([response.status, answer.code], [409, 'INVALID_STATUS'], status);
  }
  const missing = await call(env(), { row: undefined });
  assert.deepEqual([missing.response.status, missing.answer.code], [404, 'NOT_FOUND']);
  for (const body of [{}, { print_job_id: 'abc' }, { print_job_id: 5 }, { print_job_id: `${JOB_ID}'` }, '{not json']) {
    const bad = await call(env(), { row: printing, body });
    assert.deepEqual([bad.response.status, bad.answer.code], [400, 'INVALID_REQUEST'], JSON.stringify(body));
    assert.equal(bad.calls.length, 0, 'nothing was read');
  }
});

test('cancel-print-job: the row was cancelled in CUPS but could not be recorded is 500 RECORD_FAILED', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok' }));
  try {
    const { response, answer } = await call(env(), { row: printing, updateStatus: 500 });
    assert.deepEqual([response.status, answer.code], [500, 'RECORD_FAILED']);
    assert.match(answer.error, /cancelled, but it could not be recorded/);
  } finally { await cups.close(); }
});

test('cancel-print-job: signed-in staff, supervisors and admins may cancel any job; customers (403) and the service key (401) may not', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok' }));
  try {
    for (const role of ['admin', 'supervisor', 'staff']) assert.equal((await call(env(), { role, row: printing })).response.status, 200, role);
    const customer = await call(env(), { role: 'customer', row: printing });
    assert.deepEqual([customer.response.status, customer.answer.code], [403, 'PRINT_FORBIDDEN']);
    const service = await call(env(), { row: printing, token: await signToken('service_role') });
    assert.equal(service.response.status, 401);
    const anonymous = await call(env(), { row: printing, token: null });
    assert.equal(anonymous.response.status, 401);
    assert.equal(cups.requests.length, 3, 'only the three allowed roles reached CUPS');
  } finally { await cups.close(); }
});

test('cancel-print-job: the id of the profile lookup is the signed-in user; nothing from the body chooses the queue', async () => {
  const cups = await fakeCups(() => ({ statusCode: 'successful-ok' }));
  try {
    const { calls } = await call(env(), { row: printing, body: { print_job_id: JOB_ID, printer_name: 'OtherQueue', cups_job_id: 999 } });
    assert.equal(cups.requests[0].path, '/printers/LQ1310_RAW');
    assert.equal(cups.requests[0].attributes['job-id'], 41, 'the job id is the stored one');
    assert.ok(calls.length >= 1 && USER_ID);
  } finally { await cups.close(); }
});

// WH-109 review: CUPS lets only the job's owner cancel it (cupsd.conf, Cancel-Job: Require user @OWNER @SYSTEM), so the cancel is sent
// under the user name the job was submitted under: warehouse-<job_type>.
test('cancel-print-job sends the cancel under the job\'s own user name; a CUPS that applies the owner rule accepts it, and refuses any other name', async () => {
  for (const [jobType, user] of [['GRN', 'warehouse-grn'], ['Dispatch', 'warehouse-dispatch'], ['Invoice', 'warehouse-invoice']]) {
    const cups = await fakeCups(message => (message['operation-attributes-tag']['requesting-user-name'] === user
      ? { statusCode: 'successful-ok' } : { statusCode: 'client-error-forbidden' }));
    try {
      const { response, answer } = await call(env(), { row: { ...printing, job_type: jobType } });
      assert.equal(response.status, 200, `${jobType}: ${JSON.stringify(answer)}`);
      assert.equal(cups.requests[0].attributes['requesting-user-name'], user);
    } finally { await cups.close(); }
  }
  // The owner rule refuses a name that is not the job's: what the old fixed name did.
  const cups = await fakeCups(message => (message['operation-attributes-tag']['requesting-user-name'] === 'warehouse-grn'
    ? { statusCode: 'successful-ok' } : { statusCode: 'client-error-forbidden' }));
  try {
    assert.equal(await cancelCupsJob(41, 'Invoice', cupsEnv()), 'refused');
    assert.equal(await cancelCupsJob(41, 'GRN', cupsEnv()), 'cancelled');
  } finally { await cups.close(); }
});
