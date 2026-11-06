import test from 'node:test';
import assert from 'node:assert/strict';
import { restClient } from '../functions/_shared/supabase-rest.ts';
const { duplicateResponse, finishPrintJob, readRequestId, resetRequestIdColumnCache, startPrintJob } = await import('../functions/_shared/print-request.ts');
const { UNCONFIRMED_NOTE } = await import('../functions/_shared/print-transport.ts');
import { fakePrintJobs, withFetch } from './print-harness.mjs';

// WH-109 part 4: the duplicate-print guard of the three preprinted print functions. The real REST client runs against an in-memory
// print_jobs table that behaves like the database of migration 151 (unique (user_id, request_id)) or like one without it.
const REQUEST = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const OTHER = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const USER = '00000000-0000-4000-8000-0000000000aa';
const meta = (overrides = {}) => ({
  job_type: 'Invoice', document_range_start: '101', document_range_end: '103', document_count: 3, user_id: USER, user_name: 'Print Test User',
  content_size: 4096, printer_name: 'LQ1310_RAW', ...overrides,
});
const tracked = { kind: 'tracked', row: { cups_job_id: 41, status: 'printing' } };
const client = () => restClient('http://gateway.test', 'unit-service-key');
async function scenario(table, body) {
  resetRequestIdColumnCache();
  const warnings = [];
  const originalWarn = console.warn, originalError = console.error;
  console.warn = (...args) => warnings.push(args.join(' '));
  console.error = () => {};
  try { return await withFetch(table.route, calls => body(client(), calls, warnings)); } finally { console.warn = originalWarn; console.error = originalError; resetRequestIdColumnCache(); }
}

test('readRequestId: absent or null is none, a uuid is lowercased, anything else is a 400 INVALID_REQUEST_ID', async () => {
  assert.deepEqual(readRequestId(undefined), { ok: true, requestId: null });
  assert.deepEqual(readRequestId(null), { ok: true, requestId: null });
  assert.deepEqual(readRequestId(REQUEST.toUpperCase()), { ok: true, requestId: REQUEST });
  for (const bad of ['', 'not-a-uuid', 12, true, {}, [], `${REQUEST}0`, ` ${REQUEST}`, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaag']) {
    const result = readRequestId(bad);
    assert.equal(result.ok, false, JSON.stringify(bad));
    assert.equal(result.response.status, 400);
    const body = await result.response.json();
    assert.deepEqual([body.success, body.code, body.error], [false, 'INVALID_REQUEST_ID', 'request_id must be a uuid']);
  }
});

test('no request_id (an older app): no lookup, no queued row; the row is written after the send', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const started = await startPrintJob(rest, meta(), null);
    assert.deepEqual(started, { kind: 'late' });
    assert.equal(table.requests.length, 0);
    const id = await finishPrintJob(rest, started, meta(), tracked);
    assert.match(id, /^00000000-0000-4000-8000-/);
    assert.equal(table.rows.length, 1);
    assert.deepEqual([table.rows[0].status, table.rows[0].cups_job_id, table.rows[0].request_id, table.rows[0].document_range_start], ['printing', 41, null, '101']);
    // A failed send writes nothing in the old order.
    assert.equal(await finishPrintJob(rest, { kind: 'late' }, meta(), { kind: 'failed', error: 'nope' }), null);
    assert.equal(table.rows.length, 1);
  });
});

test('a new request_id: a queued row is inserted before the send and finished by the outcome', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const started = await startPrintJob(rest, meta(), REQUEST);
    assert.equal(started.kind, 'row');
    assert.equal(table.rows.length, 1);
    assert.deepEqual([table.rows[0].status, table.rows[0].request_id, table.rows[0].user_id], ['queued', REQUEST, USER]);
    assert.equal(table.rows[0].printer_name, 'LQ1310_RAW');
    assert.equal(await finishPrintJob(rest, started, meta(), tracked), started.id);
    assert.deepEqual([table.rows[0].status, table.rows[0].cups_job_id], ['printing', 41]);
    assert.equal(table.rows.length, 1, 'finishing updates the queued row, it adds none');
  });
});

test('the same request_id again: the existing row is answered and nothing new is written (duplicate)', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const first = await startPrintJob(rest, meta(), REQUEST);
    await finishPrintJob(rest, first, meta(), tracked);
    for (const status of ['printing', 'queued', 'completed', 'cancelled', 'unknown']) {
      table.rows[0].status = status;
      const again = await startPrintJob(rest, meta(), REQUEST);
      assert.equal(again.kind, 'duplicate', status);
      assert.equal(again.row.id, first.id);
      assert.equal(again.row.status, status);
    }
    assert.equal(table.rows.length, 1);
    // The same id from another user is not a duplicate; another id from the same user is not either.
    assert.equal((await startPrintJob(rest, meta({ user_id: '00000000-0000-4000-8000-0000000000bb' }), REQUEST)).kind, 'row');
    assert.equal((await startPrintJob(rest, meta(), OTHER)).kind, 'row');
    assert.equal(table.rows.length, 3);
  });
});

test('a twin that wins the unique index (23505 on insert): this request gets the winner\'s row and prints nothing', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    // The twin's row appears between this request's lookup and its insert.
    const original = table.route;
    let lookedUp = false;
    const route = async (call) => {
      const answer = await original(call);
      if (call.method === 'GET' && !lookedUp) {
        lookedUp = true;
        table.rows.push({ id: 'twin-row', user_id: USER, request_id: REQUEST, status: 'printing', cups_job_id: 9, error_message: null, document_count: 3 });
      }
      return answer;
    };
    const started = await withFetch(route, () => startPrintJob(rest, meta(), REQUEST));
    assert.equal(started.kind, 'duplicate');
    assert.equal(started.row.id, 'twin-row');
    assert.equal(table.rows.length, 1, 'no second row');
    assert.ok(table.requests.some(request => request.method === 'POST'), 'the insert was attempted and refused');
  });
});

test('a 23505 whose winner cannot be found again falls back to printing without a queued row', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const original = table.route;
    const route = async (call) => (call.method === 'POST'
      ? json409()
      : original(call));
    const json409 = () => new Response(JSON.stringify({ code: '23505', message: 'duplicate key' }), { status: 409 });
    const started = await withFetch(route, () => startPrintJob(rest, meta(), REQUEST));
    assert.deepEqual(started, { kind: 'late' });
  });
});

test('a failed row (nothing reached the printer) is claimed again by a retry with the same request_id; only one retry wins', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const first = await startPrintJob(rest, meta(), REQUEST);
    await finishPrintJob(rest, first, meta(), { kind: 'failed', error: 'The print bridge could not be reached' });
    assert.deepEqual([table.rows[0].status, table.rows[0].error_message], ['failed', 'The print bridge could not be reached']);
    const retry = await startPrintJob(rest, meta({ content_size: 5000 }), REQUEST);
    assert.deepEqual(retry, { kind: 'row', id: first.id });
    assert.deepEqual([table.rows[0].status, table.rows[0].error_message, table.rows[0].cups_job_id, table.rows[0].completed_at, table.rows[0].content_size], ['queued', null, null, null, 5000]);
    // The claim is conditional on status failed: a second retry meets a queued row and is a duplicate.
    const claim = table.requests.find(request => request.method === 'PATCH' && request.params.has('status'));
    assert.equal(claim.params.get('status'), 'eq.failed');
    const second = await startPrintJob(rest, meta(), REQUEST);
    assert.equal(second.kind, 'duplicate');
    assert.equal(second.row.status, 'queued');
    assert.equal(table.rows.length, 1);
  });
});

test('two retries of a failed row at once: the update that finds the row no longer failed loses and answers duplicate', async () => {
  const table = fakePrintJobs([{ id: 'row-1', user_id: USER, request_id: REQUEST, status: 'failed', cups_job_id: null, error_message: 'x', document_count: 3 }]);
  await scenario(table, async (rest) => {
    // The first claim runs; before the second one's update arrives the row is already queued.
    const [one, two] = await Promise.all([startPrintJob(rest, meta(), REQUEST), startPrintJob(rest, meta(), REQUEST)]);
    assert.deepEqual([one.kind, two.kind].sort(), ['duplicate', 'row']);
    assert.equal(table.rows[0].status, 'queued');
  });
});

test('a failure that did not reach the database ends the row failed with a note of at most 500 characters', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const started = await startPrintJob(rest, meta(), REQUEST);
    await finishPrintJob(rest, started, meta(), { kind: 'failed', error: 'x'.repeat(900) });
    assert.equal(table.rows[0].status, 'failed');
    assert.equal(table.rows[0].error_message.length, 500);
  });
});

test('unconfirmed and sent outcomes end the queued row as unknown with the note', async () => {
  for (const outcome of [
    { kind: 'unconfirmed', row: { cups_job_id: null, status: 'unknown', error_message: UNCONFIRMED_NOTE } },
    { kind: 'sent', row: { cups_job_id: null, status: 'unknown', error_message: 'Sent to the print bridge' } },
  ]) {
    const table = fakePrintJobs();
    await scenario(table, async (rest) => {
      const started = await startPrintJob(rest, meta(), REQUEST);
      await finishPrintJob(rest, started, meta(), outcome);
      assert.deepEqual([table.rows[0].status, table.rows[0].error_message], ['unknown', outcome.row.error_message], outcome.kind);
    });
  }
});

test('migration 151 not applied (missing column, 42703 on the lookup): the guard is off, one warning, rows are written after the send', async () => {
  const table = fakePrintJobs([], { columnMissing: true });
  await scenario(table, async (rest, _calls, warnings) => {
    const started = await startPrintJob(rest, meta(), REQUEST);
    assert.deepEqual(started, { kind: 'late' });
    assert.equal(warnings.length, 1);
    assert.match(warnings[0], /request_id does not exist \(migration 151 is not applied\)/);
    // What was learnt is remembered: later requests make no lookup at all, and the warning is not repeated.
    const before = table.requests.length;
    assert.deepEqual(await startPrintJob(rest, meta(), OTHER), { kind: 'late' });
    assert.equal(table.requests.length, before);
    assert.equal(warnings.length, 1);
    // The row is written the old way, without request_id (the column is not accepted).
    const id = await finishPrintJob(rest, started, meta(), tracked);
    assert.ok(id);
    assert.equal('request_id' in table.requests.at(-1).body, false);
  });
});

test('a missing column discovered by the insert (PGRST204 from the schema cache) also turns the guard off', async () => {
  const table = fakePrintJobs([], { columnMissing: true });
  await scenario(table, async (rest, _calls, warnings) => {
    // The lookup passes (a stale PostgREST cache answers it), the insert names the column and is refused.
    const original = table.route;
    const route = call => (call.method === 'GET' ? Promise.resolve(new Response('[]', { status: 200 })) : original(call));
    const started = await withFetch(route, () => startPrintJob(rest, meta(), REQUEST));
    assert.deepEqual(started, { kind: 'late' });
    assert.equal(warnings.length, 1);
    assert.equal(table.rows.length, 0);
  });
});

test('a lookup that fails for another reason throws (the caller answers 500; guessing "no duplicate" could print twice)', async () => {
  resetRequestIdColumnCache();
  const route = async () => new Response(JSON.stringify({ code: '57014', message: 'canceling statement due to statement timeout' }), { status: 500 });
  await withFetch(route, async () => {
    await assert.rejects(startPrintJob(client(), meta(), REQUEST), /print_jobs lookup failed: canceling statement/);
  });
  // A column error that does not name request_id is not taken for a missing column.
  await withFetch(async () => new Response(JSON.stringify({ code: '42703', message: 'column print_jobs.other does not exist' }), { status: 400 }), async () => {
    await assert.rejects(startPrintJob(client(), meta(), REQUEST), /print_jobs lookup failed/);
  });
});

test('an insert that fails for another reason prints without a queued row (as the functions always did when the log failed)', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const original = table.route;
    const route = call => (call.method === 'POST' ? Promise.resolve(new Response(JSON.stringify({ code: '57014', message: 'timeout' }), { status: 500 })) : original(call));
    assert.deepEqual(await withFetch(route, () => startPrintJob(rest, meta(), REQUEST)), { kind: 'late' });
  });
});

test('finishing a row whose update fails still returns the id (the print happened); a failed late insert returns null', async () => {
  const table = fakePrintJobs();
  await scenario(table, async (rest) => {
    const started = await startPrintJob(rest, meta(), REQUEST);
    table.failUpdates = 1;
    assert.equal(await finishPrintJob(rest, started, meta(), tracked), started.id);
    const failing = fakePrintJobs();
    failing.route = async () => new Response(JSON.stringify({ code: 'XX000', message: 'down' }), { status: 500 });
    const id = await withFetch(failing.route, () => finishPrintJob(rest, { kind: 'late' }, meta(), tracked));
    assert.equal(id, null);
  });
});

test('duplicateResponse: a handled request answers 200 with duplicate true and the stored job; an unconfirmed one repeats the 502', async () => {
  const row = { id: 'row-1', status: 'printing', cups_job_id: 41, error_message: null, document_count: 3 };
  const ok = duplicateResponse(row, { start: '101', end: '103' });
  assert.equal(ok.status, 200);
  const body = await ok.json();
  assert.equal(body.success, true);
  assert.equal(body.duplicate, true);
  assert.match(body.message, /nothing was printed again/);
  assert.deepEqual(body.range, { start: '101', end: '103', count: 3 });
  assert.deepEqual(body.print_job, { print_job_id: 'row-1', cups_job_id: 41, status: 'printing' });

  const unconfirmed = duplicateResponse({ ...row, status: 'unknown', cups_job_id: null, error_message: UNCONFIRMED_NOTE }, { start: '101', end: '103' });
  assert.equal(unconfirmed.status, 502);
  const failed = await unconfirmed.json();
  assert.deepEqual([failed.success, failed.code, failed.unconfirmed, failed.duplicate, failed.print_job_id], [false, 'PRINT_UNCONFIRMED', true, true, 'row-1']);
  // An unknown row with another note (a bridge send) is a success the first time and stays one.
  const sent = duplicateResponse({ ...row, status: 'unknown', cups_job_id: null, error_message: 'Sent to the print bridge' }, { start: '1', end: '2' });
  assert.equal(sent.status, 200);
});
