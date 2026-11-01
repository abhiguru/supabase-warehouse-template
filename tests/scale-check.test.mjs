import assert from 'node:assert/strict';
import { test } from 'node:test';
import { evaluate, percentile, settings, summarise, workload } from './scale-check.mjs';
import { scaleCounts, scaleSeedSql } from './seed/make-seed.mjs';

test('percentile takes the nearest rank of a sorted list', () => {
  const hundred = Array.from({ length: 100 }, (_, i) => i + 1);
  assert.equal(percentile(hundred, 0.5), 50);
  assert.equal(percentile(hundred, 0.95), 95);
  assert.equal(percentile(hundred, 1), 100);
  assert.equal(percentile([7], 0.95), 7);
  assert.equal(percentile([], 0.95), null);
  assert.equal(percentile([1, 2, 3, 4], 0.95), 4, 'the rank rounds up, so a small sample reports its slowest call');
});

test('summarise gives p50, p95 and max per RPC, sorts its input and counts errors as calls', () => {
  const summary = summarise({ a: { durations: [300, 100, 200, 400], errors: 1 }, b: { durations: [], errors: 3 } });
  assert.deepEqual(summary.a, { calls: 5, errors: 1, p50: 200, p95: 400, max: 400 });
  assert.deepEqual(summary.b, { calls: 3, errors: 3, p50: null, p95: null, max: null });
});

test('evaluate: a p95 above the limit is a warning unless enforced; an error or no answer always fails; the limit itself passes', () => {
  const summary = { fast: { calls: 10, errors: 0, p50: 10, p95: 300, max: 400 }, slow: { calls: 10, errors: 0, p50: 100, p95: 300.1, max: 900 } };
  assert.deepEqual(evaluate(summary, { limitMs: 300, enforce: false }), { failures: [], warnings: ['slow: p95 300.1 ms is above 300 ms'] });
  assert.deepEqual(evaluate(summary, { limitMs: 300, enforce: true }), { failures: ['slow: p95 300.1 ms is above 300 ms'], warnings: [] });
  const broken = { gone: { calls: 4, errors: 4, p50: null, p95: null, max: null }, some: { calls: 10, errors: 1, p50: 5, p95: 6, max: 7 } };
  for (const enforce of [false, true]) {
    const verdict = evaluate(broken, { limitMs: 300, enforce });
    assert.equal(verdict.failures.length, 2);
    assert.match(verdict.failures[0], /^gone: 4 of 4 calls failed/);
    assert.match(verdict.failures[1], /^some: 1 of 10 calls failed/);
  }
});

test('settings: the defaults are 60 s, 20 workers, 300 ms, not enforced; bad values are refused', () => {
  assert.deepEqual(settings({}), { seconds: 60, workers: 20, limitMs: 300, enforce: false, adminPhone: '919888888871', output: 'scale-check.json' });
  assert.equal(settings({ SCALE_ENFORCE: '1', SCALE_P95_MS: '150' }).enforce, true);
  assert.equal(settings({ SCALE_P95_MS: '150' }).limitMs, 150);
  assert.throws(() => settings({ SCALE_ENFORCE: 'yes' }), /SCALE_ENFORCE/);
  assert.throws(() => settings({ SCALE_P95_MS: '0' }), /SCALE_P95_MS/);
  assert.throws(() => settings({ SCALE_WORKERS: 'many' }), /SCALE_WORKERS/);
});

test('workload: staff and administrators run the six app calls with limit 20; a customer only its own orders and summary', () => {
  const calls = workload('staff', { big: 'C', sinceIso: 'T' });
  assert.deepEqual(calls.map(call => call[0]), ['get_orders_list', 'get_dispatch_list_with_items', 'get_grn_list', 'get_invoices_list', 'get_sensor_polling_data', 'get_customer_invoice_summary']);
  assert.equal(calls[0][1].p_limit, 20);
  assert.deepEqual(calls[1][1], { p_page: 1, p_limit: 20 });
  assert.equal(calls[3][1].p_limit, 20);
  assert.equal(calls[4][1].p_since_timestamp, 'T');
  assert.equal(calls[5][1].p_customer_uuid, 'C');
  assert.deepEqual(workload('admin', { big: 'C', sinceIso: 'T' }), calls);
  assert.deepEqual(workload('customer', { big: 'C', sinceIso: 'T' }).map(call => [call[0], call[1].p_customer_id ?? call[1].p_customer_uuid]), [['get_orders_list', 'C'], ['get_customer_invoice_summary', 'C']]);
});

test('the scale seed: counts for five years, a bounded size, and the default seed untouched', () => {
  const five = scaleCounts(5);
  assert.deepEqual(five, { years: 5, customers: 200, items: 1500, receipts: 60000, receiptLines: 180000, dispatches: 45000, dispatchLines: 135000,
    invoices: 12000, invoiceLines: 36000, orderLines: 9000, sensorReadings: 17280 });
  assert.throws(() => scaleCounts(0), RangeError);
  assert.throws(() => scaleCounts(1.5), RangeError);
  const sql = scaleSeedSql({ years: 5 });
  assert.match(sql, /generate_series\(1, 60000\)/);
  assert.match(sql, /generate_series\(1, 45000\)/);
  assert.match(sql, /SET LOCAL session_replication_role = replica;/);
  assert.match(sql, /\nANALYZE;\n$/, 'statistics are gathered after the load');
  assert.ok(sql.length < 20000, 'the SQL is generated from series, not written row by row');
  // Every dispatch takes 5 bags from a line of 100, so stock never goes below 0; the invoices are over dispatched lines.
  assert.match(sql, /CASE WHEN d\.d IS NULL THEN 100 ELSE 95 END/);
  assert.match(sql, /disp_qty\)\n SELECT [^\n]*, 5\n/);
});
