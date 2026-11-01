import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseReportRequest } from '../functions/_shared/report-request.ts';
import { buildReport, formatCell } from '../functions/_shared/report-definitions.ts';
import { label } from '../functions/_shared/report-labels.ts';
import { documentHtml, cancelledNotice, withNotice } from '../functions/_shared/document-html.ts';
import { headerColumns, invoiceCancelColumns } from '../functions/_shared/document-columns.ts';

// Migration 134: a cancelled invoice is listed with the status Cancelled and is in no sum; its PDF carries one extra line.
const customer = '11111111-1111-4111-8111-111111111111';
const request = (fields = {}) => parseReportRequest({ report: 'invoice-history', customer_id: customer, from: '2026-01-01', to: '2026-01-31', ...fields });
const live = (number, total, extra = {}) => ({ invoice_number: `2026-${number}`, invoice_date: '2026-01-10T06:00:00Z', grn_ref: 'G1', total, tax_amount: 5,
  payment_status: { status: 'pending' }, ...extra });
const cancelled = number => ({ invoice_number: `2026-${number}`, invoice_date: '2026-01-11T06:00:00Z', grn_ref: 'G2', total: 900, tax_amount: 45,
  cancelled_at: '2026-01-12T06:00:00Z', cancel_reason: 'Entered twice', payment_status: { status: 'cancelled' } });
const body = { summary: { total_invoices: 2 }, invoices: [live('0001', 100), live('0002', 200, { payment_status: { status: 'paid', amount: 200 } }), cancelled('0003')] };

test('a cancelled invoice is listed as Cancelled, with no amount, and adds nothing to the totals or the summary', () => {
  const report = buildReport(request({ sort: { field: 'date', order: 'asc' } }), body);
  assert.equal(report.rows.length, 3);
  const row = report.rows.find(cells => cells[0] === '2026-0003');
  assert.deepEqual(row, ['2026-0003', '11-01-2026', 'G2', '', '', 'Cancelled']);
  assert.deepEqual(report.totals, ['Total', '', '', '300.00', '10.00', '']);
  assert.deepEqual(report.summary, [['Invoices', '2'], ['Amount', '300.00'], ['Paid', '200.00'], ['Pending', '100.00']]);
});

test('cancelled_at marks the invoice, in Gujarati too; a status word alone does not', () => {
  const byWord = { ...cancelled('0004'), cancelled_at: null };
  const reportEn = buildReport(request(), { summary: { total_invoices: 0 }, invoices: [byWord] });
  assert.equal(reportEn.rows[0][5], 'Pending', 'the status word is not the rule: no cancelled_at, no payment, so Pending');
  const reportGu = buildReport(request({ lang: 'gu' }), { summary: { total_invoices: 0 }, invoices: [cancelled('0005')] });
  assert.equal(reportGu.rows[0][5], label('gu', 'cancelled'));
  assert.notEqual(label('gu', 'cancelled'), label('en', 'cancelled'));
  assert.equal(formatCell('status', 'cancelled', 'en'), 'Cancelled');
});

test('a Paid or Pending choice never lists a cancelled invoice; an invoice without cancelled_at is unchanged', () => {
  for (const status of ['paid', 'pending']) {
    const report = buildReport(request({ status }), body);
    assert.ok(report.rows.every(cells => cells[0] !== '2026-0003'), status);
  }
  const plain = buildReport(request(), { summary: { total_invoices: 1 }, invoices: [live('0001', 100)] });
  assert.deepEqual(plain.rows, [['2026-0001', '10-01-2026', 'G1', '100.00', '5.00', 'Pending']]);
});

test('the PDF of a cancelled invoice has one CANCELLED line under the title; any other document is byte for byte what it was', () => {
  assert.equal(cancelledNotice('2026-11-01T06:00:00Z', '  Entered twice '), 'CANCELLED 01-11-2026 — Entered twice');
  const plain = documentHtml('INVOICE', 'Co', { Number: '5' }, ['Item'], [['Garlic']]);
  assert.doesNotMatch(plain, /CANCELLED/);
  const html = withNotice(plain, cancelledNotice('2026-11-01T06:00:00Z', 'Entered <twice>'));
  assert.equal(html.replace(/\n    <p style="[^"]*"><strong>[^<]*<\/strong><\/p>/, ''), plain, 'removing the line gives back the plain document');
  assert.equal(html.match(/CANCELLED/g).length, 1);
  assert.match(html, /<strong>CANCELLED 01-11-2026 — Entered &lt;twice&gt;<\/strong>/);
  assert.ok(html.indexOf('<h2>INVOICE</h2>') < html.indexOf('CANCELLED') && html.indexOf('CANCELLED') < html.indexOf('<strong>Number:'), 'the line sits between the title and the details');
});

test('the cancellation columns are read apart from the header list', () => {
  assert.equal(invoiceCancelColumns, 'cancelled_at,cancel_reason');
  assert.ok(!headerColumns('invoice').includes('cancel'));
});
