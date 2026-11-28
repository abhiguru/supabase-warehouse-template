import assert from 'node:assert/strict';
import { test } from 'node:test';
import { canonicalDecimal, compareSnapshots, comparePerCustomer, rowFromCustomerResponse, snapshotFromResponse } from './dues-figures-snapshot.mjs';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const row = (id, invoices, left, store) => `{"customer_id": "${id}", "name": "Seed Customer", "active": true, "invoices_amount": ${invoices}, "not_invoiced_left": ${left}, "not_invoiced_in_store": ${store}, "lots_without_rate": 0, "unlinked_paid_amount": null}`;
const response = rows => `{"success": true, "totals": {"invoices_amount": 1.00}, "customers": [${rows.join(', ')}]}`;

test('canonicalDecimal: equal values share one text; a paisa changes it; junk is refused', () => {
  assert.equal(canonicalDecimal('10.50'), '10.5');
  assert.equal(canonicalDecimal('0010.500'), '10.5');
  assert.equal(canonicalDecimal('7.00'), '7');
  assert.equal(canonicalDecimal('-0.00'), '0');
  assert.equal(canonicalDecimal('-3.10'), '-3.1');
  assert.notEqual(canonicalDecimal('10.50'), canonicalDecimal('10.51'));
  assert.throws(() => canonicalDecimal('1e3'), RangeError);
  assert.throws(() => canonicalDecimal(''), RangeError);
});

test('snapshotFromResponse: sorted by customer id, figures kept exact beyond float precision', () => {
  const rows = snapshotFromResponse(response([row(B, '90071992547409.93', '0.10', '5.00'), row(A, '12.50', '0', '3.07')]));
  assert.deepEqual(rows, [
    { customer_id: A, invoices_amount: '12.5', not_invoiced_left: '0', not_invoiced_in_store: '3.07' },
    { customer_id: B, invoices_amount: '90071992547409.93', not_invoiced_left: '0.1', not_invoiced_in_store: '5' },
  ]);
});

test('snapshotFromResponse refuses a failed answer, a repeated customer and a figure that is not a number', () => {
  assert.throws(() => snapshotFromResponse('{"success": false, "customers": []}'), assert.AssertionError);
  assert.throws(() => snapshotFromResponse(response([row(A, '1.00', '0', '0'), row(A, '1.00', '0', '0')])), /listed once/);
  assert.throws(() => snapshotFromResponse(response([row(A, 'null', '0', '0')])), /plain decimal/);
});

test('compareSnapshots: the same figures written differently are equal', () => {
  const before = snapshotFromResponse(response([row(A, '12.50', '0.00', '3.07'), row(B, '1', '2', '3')]));
  const after = snapshotFromResponse(response([row(B, '1.00', '2.0', '3'), row(A, '12.5', '0', '3.070')]));
  assert.deepEqual(compareSnapshots(before, after), []);
});

test('compareSnapshots: one paisa in any of the three figures is a difference', () => {
  const before = snapshotFromResponse(response([row(A, '12.50', '4.00', '3.07')]));
  for (const [figure, changed] of [['invoices_amount', row(A, '12.51', '4.00', '3.07')], ['not_invoiced_left', row(A, '12.50', '3.99', '3.07')],
    ['not_invoiced_in_store', row(A, '12.50', '4.00', '3.08')]]) {
    const differences = compareSnapshots(before, snapshotFromResponse(response([changed])));
    assert.equal(differences.length, 1, figure);
    assert.match(differences[0], new RegExp(`^${A}: ${figure} `));
  }
});

test('compareSnapshots: a customer missing after, or extra after, is a difference', () => {
  const both = snapshotFromResponse(response([row(A, '1', '0', '0'), row(B, '2', '0', '0')]));
  const onlyA = snapshotFromResponse(response([row(A, '1', '0', '0')]));
  assert.deepEqual(compareSnapshots(both, onlyA), [`${B}: missing after`]);
  assert.deepEqual(compareSnapshots(onlyA, both), [`${B}: extra after`]);
});

const single = (id, invoices, left, store, listed = true) => `{"success": true, "listed": ${listed}, "customer": {"customer_id": "${id}", "invoices_amount": ${invoices}, "not_invoiced_left": ${left}, "not_invoiced_in_store": ${store}}}`;

test('rowFromCustomerResponse: one customer\'s answer gives the list\'s row shape, exact beyond float precision', () => {
  assert.deepEqual(rowFromCustomerResponse(single(B, '90071992547409.93', '0.10', '5.00')),
    { row: { customer_id: B, invoices_amount: '90071992547409.93', not_invoiced_left: '0.1', not_invoiced_in_store: '5' }, listed: true });
  assert.throws(() => rowFromCustomerResponse('{"success": false, "error": "Customer not found"}'), /Customer not found/);
});

test('comparePerCustomer: each customer\'s own answer equal to its list entry (written differently) is no difference', () => {
  const list = snapshotFromResponse(response([row(A, '12.50', '0.00', '3.07'), row(B, '1', '2', '3')]));
  assert.deepEqual(comparePerCustomer(list, [rowFromCustomerResponse(single(A, '12.5', '0', '3.070')), rowFromCustomerResponse(single(B, '1.00', '2', '3'))]), []);
});

test('comparePerCustomer: one paisa in any of the three figures of one customer is a difference naming it', () => {
  const list = snapshotFromResponse(response([row(A, '12.50', '4.00', '3.07')]));
  for (const [figure, changed] of [['invoices_amount', single(A, '12.51', '4.00', '3.07')], ['not_invoiced_left', single(A, '12.50', '3.99', '3.07')],
    ['not_invoiced_in_store', single(A, '12.50', '4.00', '3.08')]]) {
    const differences = comparePerCustomer(list, [rowFromCustomerResponse(changed)]);
    assert.equal(differences.length, 1, figure);
    assert.match(differences[0], new RegExp(`^${A}: ${figure} `));
  }
});

test('comparePerCustomer: a customer with no answer, an answer for a customer not in the list, and a listed customer the single call says is not listed are differences', () => {
  const list = snapshotFromResponse(response([row(A, '1', '0', '0'), row(B, '2', '0', '0')]));
  const a = rowFromCustomerResponse(single(A, '1', '0', '0'));
  assert.deepEqual(comparePerCustomer(list, [a]), [`${B}: missing after`]);
  assert.deepEqual(comparePerCustomer([list[0]], [a, rowFromCustomerResponse(single(B, '2', '0', '0'))]), [`${B}: extra after`]);
  assert.deepEqual(comparePerCustomer([list[0]], [rowFromCustomerResponse(single(A, '1', '0', '0', false))]),
    [`${A}: in the list but get_customer_dues_for says it is not listed`]);
});
