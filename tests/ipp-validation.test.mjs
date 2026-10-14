import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  IPPJobState, IPPPrinterState, ippSucceeded, submittedJob, printerStatusFromReply, mapPrinterStateToStatus,
  mapIPPStateToStatus, isTerminalState, jobObservation,
} from '../functions/_shared/ipp-validate.ts';

// PRINT4 (review 2026-10-13): printer status took a missing attribute block as {},
// a missing accepting flag as true and any unknown state as "online"; the print
// handlers answered success with a job id of undefined or 'unknown'. Replies are
// now checked before anything is reported.
const read = path => readFileSync(new URL(`../functions/${path}`, import.meta.url), 'utf8');
const INCOMPLETE = { status: 'error', message: 'Printer status unknown: incomplete reply' };
const printer = attributes => ({ statusCode: 'successful-ok', 'printer-attributes-tag': attributes });

test('an IPP reply succeeded only with a successful status code', () => {
  for (const reply of [{ statusCode: 'successful-ok' }, { statusCode: 'successful-ok-ignored-or-substituted-attributes' }, { statusCode: 0 }, { statusCode: 0x00ff }]) {
    assert.equal(ippSucceeded(reply), true, JSON.stringify(reply));
  }
  for (const reply of [{ statusCode: 'client-error-not-found' }, { statusCode: 'server-error-busy' }, { statusCode: 0x0400 }, { statusCode: -1 },
    { statusCode: 1.5 }, { statusCode: 'ok' }, {}, null, undefined, 'successful-ok']) {
    assert.equal(ippSucceeded(reply), false, JSON.stringify(reply));
  }
});

test('a print is submitted only with a positive integer job id', () => {
  assert.deepEqual(submittedJob({ statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 12, 'job-uri': 'ipp://cups:631/jobs/12' } }),
    { ok: true, jobId: 12, jobUri: 'ipp://cups:631/jobs/12' });
  assert.deepEqual(submittedJob({ statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 7 } }), { ok: true, jobId: 7, jobUri: '' });
  for (const reply of [
    {}, null, undefined, { statusCode: 'successful-ok' }, { statusCode: 'successful-ok', 'job-attributes-tag': {} },
    { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 0 } },
    { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 'unknown' } },
    { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': '12' } },
    { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': -4 } },
    { statusCode: 'successful-ok', 'job-attributes-tag': { 'job-id': 3.5 } },
    { statusCode: 'client-error-not-possible', 'job-attributes-tag': { 'job-id': 12 } },
  ]) {
    const answer = submittedJob(reply);
    assert.equal(answer.ok, false, JSON.stringify(reply));
    assert.equal(answer.jobId, undefined);
  }
});

test('a printer status needs the attribute block, a known state and the accepting flag', () => {
  assert.deepEqual(printerStatusFromReply({}), INCOMPLETE, 'empty reply');
  assert.deepEqual(printerStatusFromReply(null), INCOMPLETE);
  assert.deepEqual(printerStatusFromReply({ statusCode: 'successful-ok' }), INCOMPLETE, 'no attribute block');
  assert.deepEqual(printerStatusFromReply(printer({ 'printer-is-accepting-jobs': true })), INCOMPLETE, 'missing state');
  assert.deepEqual(printerStatusFromReply(printer({ 'printer-state': 9, 'printer-is-accepting-jobs': true })), INCOMPLETE, 'unknown state');
  assert.deepEqual(printerStatusFromReply(printer({ 'printer-state': 'idle' })), INCOMPLETE, 'missing accepting flag');
  assert.deepEqual(printerStatusFromReply(printer({ 'printer-state': 3, 'printer-is-accepting-jobs': 'yes' })), INCOMPLETE, 'flag not a boolean');
  assert.deepEqual(printerStatusFromReply({ statusCode: 'client-error-not-found', 'printer-attributes-tag': { 'printer-state': 3, 'printer-is-accepting-jobs': true } }), INCOMPLETE);

  const idle = printerStatusFromReply(printer({ 'printer-state': 'idle', 'printer-is-accepting-jobs': true, 'queued-job-count': 2 }));
  assert.equal(idle.status, 'online');
  assert.equal(idle.printerState, IPPPrinterState.IDLE);
  assert.equal(idle.stateName, 'idle');
  assert.deepEqual(idle.stateReasons, ['none']);
  assert.equal(idle.queuedJobCount, 2);
  const stopped = printerStatusFromReply(printer({ 'printer-state': 'stopped', 'printer-state-reasons': 'media-needed', 'printer-is-accepting-jobs': true }));
  assert.deepEqual([stopped.status, stopped.message, stopped.printerState], ['error', 'Out of paper', 5], "the 'stopped' keyword");
  assert.equal(printerStatusFromReply(printer({ 'printer-state': 4, 'printer-is-accepting-jobs': true })).status, 'busy');
  assert.equal(printerStatusFromReply(printer({ 'printer-state': 3, 'printer-is-accepting-jobs': false })).status, 'offline');
});

test('only an idle printer is online', () => {
  assert.deepEqual(mapPrinterStateToStatus(IPPPrinterState.IDLE, ['none'], true), { status: 'online', message: 'Printer is ready' });
  for (const state of [undefined, null, 0, 6, 99, 'idle']) {
    assert.notEqual(mapPrinterStateToStatus(state, ['none'], true).status, 'online', String(state));
  }
  assert.equal(mapPrinterStateToStatus(IPPPrinterState.STOPPED, ['paused'], true).status, 'offline');
});

test('job states map as before, without an enum', () => {
  assert.equal(IPPJobState.COMPLETED, 9);
  assert.equal(mapIPPStateToStatus(9), 'completed');
  assert.equal(mapIPPStateToStatus('aborted'), 'failed');
  assert.equal(mapIPPStateToStatus(5), 'printing');
  assert.equal(mapIPPStateToStatus(42), null);
  assert.equal(isTerminalState(7), true);
  assert.equal(isTerminalState(6), false);
});

test("a job query reply says whether CUPS still lists the job", () => {
  assert.deepEqual(jobObservation({ statusCode: 'client-error-not-found' }), { kind: 'missing' });
  assert.deepEqual(jobObservation({ statusCode: 0x0406 }), { kind: 'missing' });
  assert.deepEqual(jobObservation({ statusCode: 'successful-ok', 'job-attributes-tag': { 'job-state': 9 } }), { kind: 'state', state: 9 });
  assert.deepEqual(jobObservation({ statusCode: 'successful-ok', 'job-attributes-tag': { 'job-state': 'processing' } }), { kind: 'state', state: 'processing' });
  for (const reply of [{}, null, { statusCode: 'successful-ok' }, { statusCode: 'successful-ok', 'job-attributes-tag': {} }, { statusCode: 'server-error-busy' }]) {
    assert.equal(jobObservation(reply).kind, 'error', JSON.stringify(reply));
  }
});

test('all six places that read an IPP reply validate it', () => {
  const status = read('get-printer-status/index.ts');
  assert.match(status, /printerStatusFromReply\(result\)/);
  assert.ok(!status.includes("?.[\"printer-attributes-tag\"] || {}") && !status.includes('?? true'), 'no default for a missing block or flag');
  assert.ok(!status.includes('PRINTER_STATE_MESSAGES'), 'the state names live in the shared module');
  const viaIpp = read('print-via-ipp/index.ts');
  assert.match(viaIpp, /submittedJob\(result\)/);
  assert.match(viaIpp, /The printer did not confirm the job/);
  assert.match(viaIpp, /status: 502/);
  for (const path of ['print-grn-preprinted/index.ts', 'print-dispatch-preprinted/index.ts', 'print-invoice-preprinted/index.ts']) {
    const source = read(path);
    assert.match(source, /submittedJob\(result\)/, path);
    assert.ok(!source.includes("|| 'unknown'"), `${path}: no stand-in job id`);
    assert.match(source, /status: 'unknown'/, `${path}: an unconfirmed job is recorded as unknown`);
    assert.match(source, /The printer did not confirm the job/, path);
    assert.match(source, /status: 502/, path);
  }
  const monitor = read('_shared/print-status-monitor.ts');
  assert.match(monitor, /jobObservation\(/, 'the monitor reads job replies through the validator');
  const types = read('_shared/ipp-types.ts');
  assert.doesNotMatch(types, /\benum\b/, 'no enum: node cannot strip it');
  assert.match(types, /from '\.\/ipp-validate\.ts'/);
});

test('every "printer did not confirm" 502 says unconfirmed: true, also when the job could not be logged (print_job_id null)', () => {
  for (const path of ['print-grn-preprinted/index.ts', 'print-dispatch-preprinted/index.ts', 'print-invoice-preprinted/index.ts']) {
    const source = read(path);
    const bodies = [...source.matchAll(/error: 'The printer did not confirm the job',([\s\S]*?)status: 502/g)];
    assert.equal(bodies.length, 1, path);
    assert.match(bodies[0][1], /unconfirmed: true,/, path);
    assert.match(bodies[0][1], /print_job_id: printJobRecord\?\.id \|\| null/, `${path}: existing field kept`);
  }
  assert.match(read('print-via-ipp/index.ts'), /error: 'The printer did not confirm the job', unconfirmed: true \}/);
});
