import test from 'node:test';
import assert from 'node:assert/strict';
const { monitorPrintJobStatus } = await import('../functions/_shared/print-status-monitor.ts');
import { fakeCups, fakePrintJobs, installDeno, withFetch } from './print-harness.mjs';

// WH-109 part 4: the status monitor never overwrites a final state (a job the user cancelled, or the sweeper settled), and an error
// after the row was written 'printing' ends the row 'unknown'. The real monitor runs against a fake CUPS (real IPP on 127.0.0.1) and
// an in-memory print_jobs table; the first poll is after the monitor's own 2 s delay.
const JOB = '22222222-2222-4222-8222-222222222222';
const jobRow = (status, extra = {}) => ({ id: JOB, status, user_id: 'u', cups_job_id: 41, error_message: null, completed_at: null, ...extra });
const quiet = async (body) => {
  const log = console.log, warn = console.warn, error = console.error;
  console.log = console.warn = console.error = () => {};
  try { return await body(); } finally { console.log = log; console.warn = warn; console.error = error; }
};
const jobState = state => ({ statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 41, 'job-state': state } });

async function monitor(table, cupsAnswer) {
  installDeno({ PRINT_TRANSPORT: 'cups', PRINTER_NAME: 'LQ1310_RAW' });
  const cups = await fakeCups(cupsAnswer);
  try {
    await quiet(() => withFetch(table.route, () => monitorPrintJobStatus(JOB, 41, 'http://gateway.test', 'unit-service-key')));
    return cups;
  } finally { await cups.close(); }
}

test('a job CUPS reports completed is recorded completed, with a completion time, while it is still open', async () => {
  const table = fakePrintJobs([jobRow('printing')]);
  const cups = await monitor(table, () => jobState('completed'));
  assert.equal(cups.requests[0].operation, 'Get-Job-Attributes');
  assert.equal(cups.requests[0].path, '/printers/LQ1310_RAW', 'asked on the queue the job was submitted to');
  assert.equal(cups.requests[0].attributes['job-id'], 41);
  assert.equal(table.rows[0].status, 'completed');
  assert.match(table.rows[0].completed_at, /^\d{4}-\d\d-\d\dT/);
  const update = table.requests.find(request => request.method === 'PATCH');
  assert.equal(update.params.get('id'), `eq.${JOB}`);
  assert.equal(update.params.get('status'), 'in.(queued,printing)', 'only a job still open is updated');
});

test('a row the user cancelled is never overwritten by completed (the guard matches no row; no error)', async () => {
  const cancelledAt = '2026-11-07T09:59:00.000Z';
  const table = fakePrintJobs([jobRow('cancelled', { completed_at: cancelledAt })]);
  await monitor(table, () => jobState('completed'));
  assert.equal(table.rows[0].status, 'cancelled');
  assert.equal(table.rows[0].completed_at, cancelledAt);
  assert.equal(table.requests.filter(request => request.method === 'PATCH').length, 1, 'one guarded update, no fallback write');
});

test('a row the sweeper settled (unknown) or that already ended is not overwritten either', async () => {
  for (const status of ['unknown', 'failed', 'completed']) {
    const table = fakePrintJobs([jobRow(status, { error_message: 'kept' })]);
    await monitor(table, () => jobState('canceled'));
    assert.deepEqual([table.rows[0].status, table.rows[0].error_message], [status, 'kept'], status);
  }
});

test('a queued row is followed too (CUPS state completed finishes it)', async () => {
  const table = fakePrintJobs([jobRow('queued')]);
  await monitor(table, () => jobState('completed'));
  assert.equal(table.rows[0].status, 'completed');
});

test('an error after the insert (the update of the final state fails): the row ends unknown with a note, no completion time', async () => {
  const table = fakePrintJobs([jobRow('printing')]);
  table.failUpdates = 1; // the first update (completed) fails; the next one (unknown) goes through
  await monitor(table, () => jobState('completed'));
  assert.equal(table.rows[0].status, 'unknown');
  assert.equal(table.rows[0].error_message, 'The printer could not be followed. Check the printer.');
  assert.equal(table.rows[0].completed_at, null);
  const patches = table.requests.filter(request => request.method === 'PATCH');
  assert.equal(patches.length, 2);
  assert.equal(patches[1].params.get('status'), 'in.(queued,printing)', 'the fallback is guarded the same way');
});

test('when even the unknown note cannot be written the monitor still ends without throwing (the sweeper settles the row later)', async () => {
  const table = fakePrintJobs([jobRow('printing')]);
  table.failUpdates = 5;
  await assert.doesNotReject(monitor(table, () => jobState('completed')));
  assert.equal(table.rows[0].status, 'printing');
});
