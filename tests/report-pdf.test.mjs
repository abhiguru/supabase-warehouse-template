import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { parseReportRequest, reportNames, periodReports, dayNumber } from '../functions/_shared/report-request.ts';
import { buildReport, reportDefinitions, reportFilters, reportLevel, reportRefusal, sortFields, unwrapReportBody, formatCell, indiaDay, maxReportRows }
  from '../functions/_shared/report-definitions.ts';
import { label, labelKeys, missingGujarati } from '../functions/_shared/report-labels.ts';
import { reportHtml, documentHtml } from '../functions/_shared/document-html.ts';
import { workerEnv, workerEnvNames } from '../functions/main/worker-env.ts';

const customer = '11111111-1111-4111-8111-111111111111';
const request = (fields = {}) => parseReportRequest({ report: 'stock-summary', ...fields });
const rejects = (body, message) => assert.throws(() => parseReportRequest(body), error => {
  assert.equal(error.status, 400, JSON.stringify(body));
  assert.equal(error.message, message, JSON.stringify(body));
  return true;
});

test('a report request is accepted with its defaults and with every optional field', () => {
  assert.deepEqual(request(), { report: 'stock-summary', customerId: null, from: null, to: null, sort: null, lang: 'en', status: null });
  assert.deepEqual(parseReportRequest({ report: 'grn-activity', customer_id: customer.toUpperCase(), from: '2026-01-01', to: '2026-03-31',
    sort: { field: 'quantity', order: 'asc' }, lang: 'gu' }), {
    report: 'grn-activity', customerId: customer, from: '2026-01-01', to: '2026-03-31', sort: { field: 'quantity', order: 'asc' }, lang: 'gu', status: null,
  });
  // null is the same as leaving a field out
  assert.deepEqual(request({ customer_id: null, sort: null, lang: null }), request());
  // 450 days, both ends included, is the longest period; one day is the shortest
  assert.equal(parseReportRequest({ report: 'invoice-history', from: '2025-01-01', to: '2026-03-26' }).to, '2026-03-26');
  assert.equal(parseReportRequest({ report: 'customer-activity', from: '2026-02-28', to: '2026-02-28' }).from, '2026-02-28');
  assert.deepEqual([...reportNames].sort(), ['customer-activity', 'dispatch-activity', 'grn-activity', 'invoice-history', 'item-stock-summary', 'stock-aging', 'stock-summary']);
  assert.deepEqual([...periodReports].sort(), ['customer-activity', 'dispatch-activity', 'grn-activity', 'invoice-history']);
});

test('every malformed report request is refused with 400 before anything is read', () => {
  for (const body of [null, undefined, 'stock-summary', 7, [], [{ report: 'stock-summary' }]]) rejects(body, 'Invalid report request');
  rejects({ report: 'stock-summary', extra: 1 }, 'Unknown field in report request');
  rejects({ report: 'stock-summary', customerId: customer }, 'Unknown field in report request');
  for (const report of [undefined, '', 'operations-dashboard', 'Stock-Summary', 'stock_summary', 3, ['stock-summary'], '__proto__']) {
    rejects({ report }, 'Unknown report');
  }
  for (const id of ['', 'not-a-uuid', `${customer}x`, 42, {}, ['x'], '11111111111141118111111111111111']) {
    rejects({ report: 'stock-summary', customer_id: id }, 'customer_id must be a UUID');
  }
  rejects({ report: 'grn-activity' }, 'from and to are required for this report');
  rejects({ report: 'grn-activity', from: '2026-01-01' }, 'from and to are required for this report');
  rejects({ report: 'dispatch-activity', to: '2026-01-01' }, 'from and to are required for this report');
  for (const [from, to] of [['2026-1-01', '2026-01-02'], ['2026-02-30', '2026-03-01'], ['2026-01-01', '2026-13-01'], ['01-01-2026', '2026-01-02'],
    ['2026-01-01T00:00:00Z', '2026-01-02'], [20260101, '2026-01-02'], [null, '2026-01-02'], ['1999-12-31', '2000-01-02'], ['2026-01-01', '']]) {
    rejects({ report: 'invoice-history', from, to }, 'from and to must be dates written YYYY-MM-DD');
  }
  rejects({ report: 'customer-activity', from: '2026-03-02', to: '2026-03-01' }, 'from must not be after to');
  rejects({ report: 'grn-activity', from: '2025-01-01', to: '2026-03-27' }, 'The period must not be longer than 450 days');
  for (const report of ['stock-summary', 'stock-aging', 'item-stock-summary']) {
    rejects({ report, from: '2026-01-01', to: '2026-01-02' }, 'This report has no period; leave out from and to');
    rejects({ report, to: '2026-01-02' }, 'This report has no period; leave out from and to');
  }
  for (const sort of ['date', 3, ['date', 'asc'], true]) rejects({ report: 'stock-summary', sort }, 'sort must be an object');
  rejects({ report: 'stock-summary', sort: { field: 'stock', order: 'asc', nulls: 'last' } }, 'Unknown field in sort');
  for (const field of [undefined, '', 'Stock', 'stock desc', 'a'.repeat(41), 'stock;drop', 5]) {
    rejects({ report: 'stock-summary', sort: { field, order: 'asc' } }, 'sort.field must be a short lower-case name');
  }
  for (const order of [undefined, 'ASC', 'ascending', 1, null]) {
    rejects({ report: 'stock-summary', sort: { field: 'stock', order } }, "sort.order must be 'asc' or 'desc'");
  }
  for (const lang of ['', 'hi', 'EN', 'gu-IN', 1]) rejects({ report: 'stock-summary', lang }, "lang must be 'en' or 'gu'");
  assert.equal(dayNumber('2024-02-29') - dayNumber('2024-02-28'), 1);
  assert.equal(dayNumber('2023-02-29'), null);
});

test('each report reads its existing RPC with the arguments the app uses, at the one-customer and all-customers level', () => {
  const calls = Object.fromEntries(reportNames.map(report => {
    const period = periodReports.has(report) ? { from: '2026-01-01', to: '2026-01-31' } : {};
    const one = parseReportRequest({ report, customer_id: customer, ...period });
    const all = parseReportRequest({ report, ...period });
    return [report, [reportLevel(one).rpc(one), reportLevel(all).rpc(all)]];
  }));
  const dates = { p_from_date: '2026-01-01', p_to_date: '2026-01-31' };
  const items = { p_search_query: null, p_limit: maxReportRows + 1, p_offset: 0, p_sort_by: 'item_name', p_sort_order: 'asc' };
  assert.deepEqual(calls, {
    'grn-activity': [{ name: 'get_customer_grn_activity', args: { p_customer_uuid: customer, ...dates } }, { name: 'get_all_grn_activity', args: dates }],
    'dispatch-activity': [{ name: 'get_customer_dispatch_activity', args: { p_customer_uuid: customer, ...dates } }, { name: 'get_all_dispatch_activity', args: dates }],
    'invoice-history': [{ name: 'get_customer_invoice_summary', args: { p_customer_uuid: customer, ...dates } },
      { name: 'get_customer_invoice_summary', args: { p_customer_uuid: null, ...dates } }],
    'stock-summary': [{ name: 'get_customer_stock_summary', args: { p_customer_uuid: customer } }, { name: 'get_all_stock_summary', args: {} }],
    'stock-aging': [{ name: 'get_stock_aging_report', args: { p_customer_uuid: customer } }, { name: 'get_stock_aging_report', args: { p_customer_uuid: null } }],
    'item-stock-summary': [{ name: 'get_item_wise_stock_list', args: { p_customer_id: customer, ...items } },
      { name: 'get_item_wise_stock_list', args: { p_customer_id: null, ...items } }],
    'customer-activity': [{ name: 'get_customer_activity_detail', args: { p_customer_uuid: customer, ...dates } },
      { name: 'get_all_customer_activity_summary', args: dates }],
  });
  // The item list is sorted by the server (migration 52) for the fields it knows, so a cut list keeps the rows that come first.
  const sorted = parseReportRequest({ report: 'item-stock-summary', sort: { field: 'stock', order: 'desc' } });
  assert.deepEqual(reportLevel(sorted).rpc(sorted).args, { p_customer_id: null, ...items, p_sort_by: 'total_stock', p_sort_order: 'desc' });
  const packaging = parseReportRequest({ report: 'item-stock-summary', sort: { field: 'packaging', order: 'desc' } });
  assert.deepEqual(reportLevel(packaging).rpc(packaging).args, { p_customer_id: null, ...items });
  for (const field of ['constructor', '__proto__', 'hasownproperty']) {
    const odd = parseReportRequest({ report: 'item-stock-summary', sort: { field, order: 'desc' } });
    assert.deepEqual(reportLevel(odd).rpc(odd).args, { p_customer_id: null, ...items }, field);
    assert.deepEqual(buildReport(odd, { items: [] }).sort.field, 'item', field);
  }
  // Every RPC named here exists in the migrations.
  const sql = ['00000000000000_initial_schema.sql', '00000000000052_report_sort.sql']
    .map(name => readFileSync(new URL(`../migrations/${name}`, import.meta.url), 'utf8')).join('\n');
  for (const [one, all] of Object.values(calls)) {
    for (const call of [one, all]) assert.match(sql, new RegExp(`FUNCTION public\\.${call.name}\\(`), call.name);
  }
});

// by_bucket of a stock aging answer (default buckets 120, 240, 364): the PDF prints the item count of the '364+' bucket.
const agingBuckets = {
  '0-120': { item_count: 2, total_quantity: 90, percentage: 100 }, '121-240': { item_count: 0, total_quantity: 0, percentage: 0 },
  '241-364': { item_count: 0, total_quantity: 0, percentage: 0 }, '364+': { item_count: 0, total_quantity: 0, percentage: 0 },
};

// RPC answers in the shapes the functions return (migration 0 bodies, as the app's services read them).
const fixtures = {
  'grn-activity': {
    customer: { success: true, data: { summary: { total_grns: 2, total_quantity: 150, total_invoiced_grns: 1 }, grns: [
      { gr_no: 'Z0002', grn_date: '2026-01-20', total_items: 1, total_qty: 50, total_weight: 30, invoice_status: { invoice_number: null },
        dispatch_summary: { current_stock: 50 }, items: [{ quantity: 50, weight: 30 }] },
      { gr_no: 'Z0010', grn_date: '2026-01-05', total_items: 2, total_qty: 100, total_weight: 75, invoice_status: { invoice_number: '2026-7' },
        dispatch_summary: { current_stock: 40 }, items: [{ quantity: 60, weight: 50 }, { quantity: 40, weight: 25.5 }] },
    ] } },
    all: { success: true, summary: { total_grns: 3, total_customers: 2, total_quantity: 900, total_weight: 1234.5 }, by_customer: [
      { customer_name: 'Amar Traders', grn_count: 1, total_qty: 100, total_weight: 1000, latest_grn: '2026-01-10' },
      { customer_name: 'Bharat Foods', grn_count: 2, total_qty: 800, total_weight: 234.5, latest_grn: '2026-01-15' },
    ] },
  },
  'dispatch-activity': {
    customer: { summary: { total_dispatches: 1, total_quantity: 12, total_weight: 600 }, dispatches: [
      { disp_no: 'I0001', disp_date: '2026-01-12', total_qty: 12, items: [{ source_grn: 'Z0002' }, { source_grn: 'Z0002' }, { source_grn: 'Z0010' }] },
    ] },
    all: { success: true, summary: { total_dispatches: 1, total_customers: 1, total_quantity: 12 }, by_customer: [
      { customer_name: 'Amar Traders', dispatch_count: 1, total_qty: 12, latest_dispatch: '2026-01-12' },
    ] },
  },
  'invoice-history': {
    // The invoice's total (1000) already holds its tax (180); since migration 61 net_total and net_amount are that total.
    customer: { success: true, data: { summary: { total_invoices: 1, net_amount: 1000, paid_amount: 0, pending_amount: 1000 }, invoices: [
      { invoice_number: '2026-7', invoice_date: '2026-01-31', grn_ref: 'Z0010', total: 1000, tax_amount: 180, net_total: 1000, payment_status: { status: 'pending' } },
    ] } },
    all: { success: true, data: { summary: { total_invoices: 1, total_customers: 1, total_amount: 1000, net_amount: 1000 }, by_customer: [
      { customer_name: 'Amar Traders', invoice_count: 1, total_amount: 1000, net_amount: 1000, latest_invoice_date: '2026-01-31' },
    ] } },
  },
  'stock-summary': {
    customer: { summary: { total_items: 1, total_quantity: 90, total_weight_kg: 4500, grn_count: 2 }, items: [
      { item_name: 'Cumin', grns: [
        { gr_no: 'Z0002', date: '2026-01-20', package_mark: 'AT', rack: 'R1', stock: 50, item_weight: 50 },
        { gr_no: 'Z0010', date: '2026-01-05', package_mark: 'AT', rack: 'R2', stock: 40, item_weight: 50 },
      ] },
    ] },
    all: { success: true, summary: { total_customers_with_stock: 1, total_items: 1, total_quantity: 90, total_weight_kg: 4500 }, customers: [
      { customer_name: 'Amar Traders', item_count: 1, grn_count: 2, total_stock: 90, total_weight: 4500 },
    ] },
  },
  'stock-aging': {
    customer: { success: true, data: { summary: { total_quantity: 90, average_age_days: 15, qty_over_365_days: 0 }, by_bucket: agingBuckets, items: [
      { item_name: 'Cumin', gr_no: 'Z0010', grn_date: '2026-01-05', rack: 'R2', current_stock: 40, aging_days: 26, dispatch_info: { last_dispatch_date: '2026-01-12' } },
      { item_name: 'Cumin', gr_no: 'Z0002', grn_date: '2026-01-20', rack: 'R1', current_stock: 50, aging_days: 11, dispatch_info: { last_dispatch_date: null } },
    ] } },
    all: { success: true, data: { summary: { total_customers: 1, total_quantity: 90, average_age_days: 15, qty_over_365_days: 0 }, by_bucket: agingBuckets, by_customer: [
      { customer_name: 'Amar Traders', total_stock: 90, average_age_days: 15, items_over_365_days: 0 },
    ] } },
  },
  'item-stock-summary': {
    customer: { success: true, data: { total_count: 2, items: [
      { item_name: 'Cumin', packaging: 'Bag', grn_count: 2, total_qty: 150, total_stock: 90 },
      { item_name: 'Fennel', packaging: 'Bag', grn_count: 1, total_qty: 20, total_stock: 5 },
    ] } },
    all: { success: true, data: { total_count: 2, summary: { total_stock: 95, total_qty: 170, item_count: 2 }, items: [
      { item_name: 'Cumin', packaging: 'Bag', grn_count: 2, total_qty: 150, total_stock: 90 },
      { item_name: 'Fennel', packaging: 'Bag', grn_count: 1, total_qty: 20, total_stock: 5 },
    ] } },
  },
  'customer-activity': {
    customer: { success: true, data: { summary: { current_stock: 90, total_grns: 2, total_dispatches: 1, total_invoice_amount: 1180,
      total_paid_amount: 0, total_pending_amount: 1180 }, monthly_trends: [
      { month: '2025-12', grn_count: 0, grn_quantity: 0, dispatch_count: 0, dispatch_quantity: 0, invoice_amount: 0, stock_level_end: 0 },
      { month: '2026-01', grn_count: 2, grn_quantity: 150, dispatch_count: 1, dispatch_quantity: 12, invoice_amount: 1180, stock_level_end: 90 },
    ] } },
    all: { success: true, data: { summary: { total_customers: 1, total_current_stock: 90, total_grns: 2, total_dispatches: 1, total_invoice_amount: 1180 }, customers: [
      { customer_name: 'Amar Traders', customer_city: 'Unjha', current_stock: 90, total_grns: 2, total_dispatches: 1, total_invoice_amount: 1180, last_activity_date: '2026-01-31' },
    ] } },
  },
};

const build = (report, level, lang, extra = {}) => {
  const period = periodReports.has(report) ? { from: '2026-01-01', to: '2026-01-31' } : {};
  const req = parseReportRequest({ report, lang, ...period, ...(level === 'customer' ? { customer_id: customer } : {}), ...extra });
  return buildReport(req, unwrapReportBody(fixtures[report][level]));
};

// The columns of each PDF, in English and Gujarati. Labels without Gujarati in the app print the English.
const expectedColumns = {
  'grn-activity': {
    customer: [['GRN number', 'Date', 'Items', 'Quantity', 'Weight (kg)', 'Stock', 'Invoice number'],
      ['આવક નં.', 'તારીખ', 'આઇટમ', 'નંગ', 'વજન (કિલો)', 'સ્ટોક', 'ઇન્વૉઇસ નંબર']],
    all: [['Customer', 'GRNs', 'Quantity', 'Weight (kg)', 'Latest GRN'], ['વેપારી', 'આવક પાવતી', 'નંગ', 'વજન (કિલો)', 'છેલ્લી આવક પાવતી']],
  },
  'dispatch-activity': {
    customer: [['Dispatch number', 'Date', 'GRN', 'Items', 'Quantity'], ['જાવક નંબર', 'તારીખ', 'આવક પાવતી', 'આઇટમ', 'નંગ']],
    all: [['Customer', 'Dispatches', 'Bags dispatched', 'Last dispatch'], ['વેપારી', 'જાવક', 'જાવકના નંગ', 'છેલ્લી જાવક']],
  },
  'invoice-history': {
    customer: [['Invoice number', 'Date', 'GRN', 'Amount', 'Tax', 'Status'],
      ['ઇન્વૉઇસ નંબર', 'તારીખ', 'આવક પાવતી', 'રકમ', 'ટેક્સ', 'સ્થિતિ']],
    all: [['Customer', 'Invoices', 'Amount', 'Latest invoice'], ['વેપારી', 'ઇન્વૉઇસ', 'રકમ', 'છેલ્લું ઇન્વૉઇસ']],
  },
  'stock-summary': {
    customer: [['Item', 'GRN number', 'Date', 'Package mark', 'Rack', 'Stock', 'Weight (kg)'],
      ['આઇટમ', 'આવક નં.', 'તારીખ', 'માર્કો', 'રેક', 'સ્ટોક', 'વજન (કિલો)']],
    all: [['Customer', 'Items', 'GRNs', 'Stock', 'Weight (kg)'], ['વેપારી', 'આઇટમ', 'આવક પાવતી', 'સ્ટોક', 'વજન (કિલો)']],
  },
  'stock-aging': {
    customer: [['Item', 'GRN number', 'Date', 'Rack', 'Stock', 'Stock age (days)', 'Last dispatch'],
      ['આઇટમ', 'આવક નં.', 'તારીખ', 'રેક', 'સ્ટોક', 'કેટલા દિવસથી (દિવસ)', 'છેલ્લી જાવક']],
    all: [['Customer', 'Stock', 'Average age (days)', 'Over 1 year'], ['વેપારી', 'સ્ટોક', 'સરેરાશ કેટલા દિવસથી (દિવસ)', '૧ વર્ષથી વધુ']],
  },
  'item-stock-summary': {
    customer: [['Item', 'Packaging', 'GRNs', 'Received quantity', 'Stock'], ['આઇટમ', 'પેકિંગ', 'આવક પાવતી', 'આવકના નંગ', 'સ્ટોક']],
    all: [['Item', 'Packaging', 'GRNs', 'Received quantity', 'Stock'], ['આઇટમ', 'પેકિંગ', 'આવક પાવતી', 'આવકના નંગ', 'સ્ટોક']],
  },
  'customer-activity': {
    customer: [['Month', 'GRNs', 'Received quantity', 'Dispatches', 'Bags dispatched', 'Amount', 'Stock at month end'],
      ['મહિનો', 'આવક પાવતી', 'આવકના નંગ', 'જાવક', 'જાવકના નંગ', 'રકમ', 'મહિનાના અંતે સ્ટોક']],
    all: [['Customer', 'City', 'Stock', 'GRNs', 'Dispatches', 'Amount', 'Last activity'], ['વેપારી', 'શહેર', 'સ્ટોક', 'આવક પાવતી', 'જાવક', 'રકમ', 'છેલ્લી કામગીરી']],
  },
};

test('each report prints at most seven chosen columns, labelled in English and Gujarati', () => {
  for (const report of reportNames) {
    for (const level of ['customer', 'all']) {
      const [en, gu] = expectedColumns[report][level];
      const english = build(report, level, 'en');
      const gujarati = build(report, level, 'gu');
      assert.deepEqual(english.columns.map(column => column.label), en, `${report} ${level} en`);
      assert.deepEqual(gujarati.columns.map(column => column.label), gu, `${report} ${level} gu`);
      assert.ok(en.length <= 7, `${report} ${level} has too many columns`);
      assert.equal(english.rows[0].length, en.length);
    }
  }
  assert.equal(build('grn-activity', 'customer', 'en').title, 'GRN activity');
  assert.equal(build('stock-aging', 'all', 'gu').title, 'માલ કેટલા દિવસથી પડ્યો છે');
  assert.deepEqual(reportNames.map(report => build(report, 'all', 'gu').title),
    ['આવકની કામગીરી', 'જાવકની કામગીરી', 'ઇન્વૉઇસનો ઇતિહાસ', 'સ્ટોકનો સારાંશ', 'માલ કેટલા દિવસથી પડ્યો છે', 'આઇટમ મુજબ સ્ટોકનો સારાંશ', 'વેપારીની કામગીરી']);
});

test('the Gujarati table holds only the app\'s wording, and the labels it lacks are listed', () => {
  // Every label has Gujarati now: the two that had none ('Latest invoice', 'Last activity') are made of the app's words.
  assert.deepEqual([...missingGujarati], []);
  const gujaratiScript = /[઀-૿]/;
  for (const key of labelKeys) {
    const english = label('en', key);
    const gujarati = label('gu', key);
    if (missingGujarati.includes(english)) assert.equal(gujarati, english, `${key} falls back to English`);
    else if (key !== 'dateRange' && key !== 'updated' && key !== 'showing') assert.match(gujarati, gujaratiScript, `${key} has Gujarati`);
    assert.doesNotMatch(english, gujaratiScript, `${key} English`);
  }
  assert.equal(label('gu', 'dateRange', { from: '01-01-2026', to: '31-01-2026' }), '01-01-2026થી 31-01-2026 સુધી');
  assert.equal(label('en', 'showing', { shown: '2,000', total: '2,500' }), 'Showing 2,000 of 2,500');
  assert.equal(label('gu', 'showing', { shown: '2,000', total: '2,500' }), '2,500માંથી 2,000 દેખાય છે');
  assert.equal(label('en', 'updated', { time: 'now' }), 'Last updated now');
  // Gujarati copied from the app is spot-checked against the app's English for the same key.
  assert.equal(label('gu', 'customer'), 'વેપારી');
  assert.equal(label('gu', 'quantity'), 'નંગ');
  assert.equal(label('gu', 'allCustomers'), 'બધા વેપારી');
  // Filled from other app files: filters.sheet.sortOrder (the reviewed wording of the sort line; the sort sheet's own
  // command, filters.sheet.sortBy, is 'આ મુજબ સૉર્ટ કરો'), components.table.sortedAscending / sortedDescending,
  // invoice.label.tax, users.fields.status, customers.fields.city.
  assert.deepEqual(['sortBy', 'ascending', 'descending', 'tax', 'status', 'city'].map(key => label('gu', key)),
    ['સૉર્ટનો ક્રમ', 'ચઢતા ક્રમમાં', 'ઉતરતા ક્રમમાં', 'ટેક્સ', 'સ્થિતિ', 'શહેર']);
  // The four labels of the wording review of 2026-10-12 (the owner applied its suggestions): the sort line, the cut note, the
  // GRN number column (filters.sort.grnNumberChip) and the stock age column (reports.sort.age). The stock aging REPORT
  // keeps the whole clause as its title, which is its own label, and the long forms stay where the app has them.
  assert.deepEqual(['sortBy', 'grnNumber', 'stockAge', 'titleStockAging'].map(key => label('gu', key)),
    ['સૉર્ટનો ક્રમ', 'આવક નં.', 'કેટલા દિવસથી', 'માલ કેટલા દિવસથી પડ્યો છે']);
  assert.deepEqual(['sortBy', 'showing', 'grnNumber', 'stockAge'].map(key => label('en', key, { shown: '1', total: '2' })),
    ['Sort by', 'Showing 1 of 2', 'GRN number', 'Stock age']);
  assert.equal(label('gu', 'overOneYear'), '૧ વર્ષથી વધુ', 'the fifth doubtful label is left as it was');
  assert.deepEqual(['grn', 'grns', 'averageAge'].map(key => label('gu', key)), ['આવક પાવતી', 'આવક પાવતી', 'સરેરાશ કેટલા દિવસથી']);
  // The app's 'Latest {{date}}' of an invoice row is 'છેલ્લું {{date}}'; its 'Last active' is 'છેલ્લી કામગીરી'.
  assert.equal(label('gu', 'latestInvoice'), 'છેલ્લું ઇન્વૉઇસ');
  assert.equal(label('gu', 'lastActivity'), 'છેલ્લી કામગીરી');
  // reports.filters.payment, reports.customerActivity.paid, common.pending.
  assert.deepEqual(['payment', 'paid', 'pending'].map(key => label('gu', key)), ['ચુકવણી', 'ચૂકવેલ', 'બાકી']);
  assert.deepEqual(['payment', 'paid', 'pending'].map(key => label('en', key)), ['Payment', 'Paid', 'Pending']);
});

test('rows, summary figures and totals come from the RPC answer and are printed with Indian grouping', () => {
  const grn = build('grn-activity', 'customer', 'en');
  // Newest GRN first by default; weight is each line's bag weight times its bags.
  assert.deepEqual(grn.rows, [
    ['Z0002', '20-01-2026', '1', '50', '1,500', '50', ''],
    ['Z0010', '05-01-2026', '2', '100', '4,020', '40', '2026-7'],
  ]);
  assert.deepEqual(grn.totals, ['Total', '', '3', '150', '5,520', '90', '']);
  assert.deepEqual(grn.summary, [['GRNs', '2'], ['Quantity', '150'], ['Weight (kg)', '5,520'], ['Invoiced', '1']]);
  assert.deepEqual(grn.columns.map(column => column.numeric), [false, false, true, true, true, true, false]);
  assert.deepEqual(grn.sort, { field: 'date', order: 'desc', label: 'Date (descending)' });

  const invoices = build('invoice-history', 'customer', 'gu');
  assert.deepEqual(invoices.rows, [['2026-7', '31-01-2026', 'Z0010', '1,000.00', '180.00', 'બાકી']]);
  assert.deepEqual(invoices.totals, ['કુલ', '', '', '1,000.00', '180.00', '']);
  assert.deepEqual(invoices.summary, [['ઇન્વૉઇસ', '1'], ['રકમ', '1,000.00'], ['ચૂકવેલ', '0.00'], ['બાકી', '1,000.00']]);

  assert.deepEqual(build('dispatch-activity', 'customer', 'en').rows, [['I0001', '12-01-2026', 'Z0002, Z0010', '3', '12']]);
  assert.deepEqual(build('stock-summary', 'customer', 'en').rows, [
    ['Cumin', 'Z0002', '20-01-2026', 'AT', 'R1', '50', '2,500'],
    ['Cumin', 'Z0010', '05-01-2026', 'AT', 'R2', '40', '2,000'],
  ]);
  assert.deepEqual(build('customer-activity', 'customer', 'en').rows[1], ['01-2026', '2', '150', '1', '12', '1,180.00', '90']);
  // Item stock: the whole-list summary of migration 52 when present, otherwise the rows read.
  assert.deepEqual(build('item-stock-summary', 'all', 'en').summary, [['Items', '2'], ['Units in stock', '95'], ['Received quantity', '170']]);
  assert.deepEqual(build('item-stock-summary', 'customer', 'en').summary, [['Items', '2'], ['Units in stock', '95'], ['Received quantity', '170']]);
  assert.equal(build('grn-activity', 'all', 'en').summary[3][1], '1,234.5');
  assert.equal(formatCell('number', 12345678.456, 'en'), '1,23,45,678.46');
  assert.equal(formatCell('number', 'x', 'en'), '');
  assert.equal(formatCell('date', '2026-01-05T10:00:00+00:00', 'en'), '05-01-2026');
});

test('a requested sort is applied when the report knows the field; anything else gives the default order', () => {
  const quantityAsc = build('grn-activity', 'customer', 'en', { sort: { field: 'quantity', order: 'asc' } });
  assert.deepEqual(quantityAsc.rows.map(row => row[0]), ['Z0002', 'Z0010']);
  const quantityDesc = build('grn-activity', 'customer', 'en', { sort: { field: 'quantity', order: 'desc' } });
  assert.deepEqual(quantityDesc.rows.map(row => row[0]), ['Z0010', 'Z0002']);
  assert.equal(quantityDesc.sort.label, 'Quantity (descending)');
  // GRN numbers compare by their digits: Z0002 before Z0010.
  assert.deepEqual(build('grn-activity', 'customer', 'en', { sort: { field: 'gr_no', order: 'asc' } }).rows.map(row => row[0]), ['Z0002', 'Z0010']);
  // A field of another level or report is not this report's: the default (newest first) applies.
  for (const field of ['customer', 'not_a_field', 'constructor']) {
    const fallback = build('grn-activity', 'customer', 'en', { sort: { field, order: 'asc' } });
    assert.deepEqual(fallback.sort, { field: 'date', order: 'desc', label: 'Date (descending)' });
    assert.deepEqual(fallback.rows.map(row => row[0]), ['Z0002', 'Z0010']);
  }
  // A missing value comes last in either direction.
  for (const order of ['asc', 'desc']) {
    const aging = build('stock-aging', 'customer', 'en', { sort: { field: 'last_dispatch', order } });
    assert.equal(aging.rows[1][6], '', order);
  }
  assert.deepEqual(sortFields(parseReportRequest({ report: 'invoice-history', from: '2026-01-01', to: '2026-01-02' })),
    ['customer', 'invoices', 'amount', 'latest', 'net']);
  assert.equal(build('stock-aging', 'customer', 'gu', { sort: { field: 'stock', order: 'asc' } }).sort.label, 'સ્ટોક (ચઢતા ક્રમમાં)');
  assert.equal(build('stock-aging', 'customer', 'gu', { sort: { field: 'stock', order: 'desc' } }).sort.label, 'સ્ટોક (ઉતરતા ક્રમમાં)');
  // Every default sort names a column of its level.
  for (const report of reportNames) {
    for (const level of ['customer', 'all']) {
      const definition = reportDefinitions[report][level];
      assert.ok(definition.columns.some(column => column.key === definition.defaultSort.field), `${report} ${level}`);
    }
  }
});

test(`a report longer than ${maxReportRows} rows is cut, and says so`, () => {
  const many = { success: true, data: { summary: { total_quantity: 1 }, items: Array.from({ length: 2500 }, (_, index) => ({
    item_name: `Item ${index}`, gr_no: `Z${index}`, grn_date: '2026-01-01', rack: 'R', current_stock: 1, aging_days: index,
  })) } };
  const req = parseReportRequest({ report: 'stock-aging', customer_id: customer });
  const built = buildReport(req, unwrapReportBody(many));
  assert.equal(built.rows.length, maxReportRows);
  assert.equal(built.rowsTotal, 2500);
  assert.equal(built.truncated, true);
  assert.equal(built.rows[0][1], 'Z2499', 'the oldest stock comes first and stays');
  assert.equal(built.totals[4], '2,000', 'the totals row adds up the rows printed');
  const exact = buildReport(req, unwrapReportBody({ data: { items: many.data.items.slice(0, maxReportRows) }, success: true }));
  assert.equal(exact.truncated, false);
  // The item list is read one row past the limit; its count says how many there are.
  const items = { success: true, data: { total_count: 3100, items: Array.from({ length: maxReportRows + 1 }, (_, index) => ({ item_name: `I${index}`, total_stock: 1 })) } };
  const list = buildReport(parseReportRequest({ report: 'item-stock-summary' }), unwrapReportBody(items));
  assert.equal(list.rows.length, maxReportRows);
  assert.equal(list.rowsTotal, 3100);
  assert.equal(list.truncated, true);
  // No rows: no totals row, and the empty text of the report.
  const empty = buildReport(parseReportRequest({ report: 'stock-summary', lang: 'gu' }), unwrapReportBody({ success: true, summary: {}, customers: [] }));
  assert.deepEqual([empty.rows, empty.totals, empty.empty], [[], null, 'હજુ કોઈ સ્ટોક નથી']);
});

test('a refusal in the RPC body becomes 403, an unknown customer 404, anything else 503', () => {
  assert.deepEqual(reportRefusal({ success: false, error: 'Failed to retrieve customer activity summary: Staff access required', error_code: '42501' }),
    { status: 403, message: 'Report not available to this account' });
  assert.deepEqual(reportRefusal({ success: false, error: 'Failed to retrieve stock summary: Staff access required' }).status, 403);
  assert.deepEqual(reportRefusal({ error: 'Access denied: customer not accessible', summary: null, items: [] }).status, 403);
  assert.deepEqual(reportRefusal([{ success: false, error: 'PERMISSION_DENIED: Customer UUID required for non-staff users' }]).status, 403);
  assert.deepEqual(reportRefusal({ success: false, error: 'Customer not found' }), { status: 404, message: 'Customer unavailable' });
  assert.deepEqual(reportRefusal({ success: false, error: 'something broke', error_code: 'XX000' }), { status: 503, message: 'Report data unavailable' });
  assert.deepEqual(reportRefusal({ success: false }), { status: 503, message: 'Report data unavailable' });
  for (const answer of [{ success: true, data: {} }, { summary: {}, dispatches: [] }, null, 'text', [], { success: true, error: 'ignored' }]) {
    assert.equal(reportRefusal(answer), null, JSON.stringify(answer));
  }
  assert.deepEqual(unwrapReportBody({ success: true, data: { items: [1] } }), { items: [1] });
  assert.deepEqual(unwrapReportBody([{ summary: { a: 1 } }]), { summary: { a: 1 } });
  assert.deepEqual(unwrapReportBody({ success: true, summary: {}, by_customer: [] }), { success: true, summary: {}, by_customer: [] });
  assert.equal(unwrapReportBody(null), null);
  // The handler maps the PostgREST error the guard raises (42501) the same way.
  const handler = readFileSync(new URL('../functions/_shared/report-pdf.ts', import.meta.url), 'utf8');
  assert.match(handler, /answer\.error\.code === '42501'\) throw \{ status: 403/);
  assert.match(handler, /const reader = createClient\(internal, Deno\.env\.get\('SUPABASE_ANON_KEY'\)!/);
  assert.match(handler, /const answer = await reader\.rpc\(call\.name, call\.args\);/);
  assert.doesNotMatch(handler, /writer\.rpc|writer\.from\('(?!system_settings)/, 'the server key reads no business data');
  assert.match(handler, /`report\/\$\{request\.report\}\/\$\{request\.customerId \?\? 'all'\}\/\$\{crypto\.randomUUID\(\)\}\.pdf`/);
  assert.match(handler, /createSignedUrl\(path, 3600\)/);
});

const sample = (overrides = {}) => reportHtml({
  title: 'Stock summary', company: 'Fictional Cold Storage', lang: 'en',
  filters: [['Customer', 'Amar Traders'], ['Sort by', 'Stock (descending)'], ['', 'Last updated 12-10-2026 08:00 UTC']],
  summaryTitle: 'Summary', summary: [['Units in stock', '1,23,456'], ['Weight (kg)', '4,500']],
  columns: [{ label: 'Item', numeric: false }, { label: 'Stock', numeric: true }],
  rows: [['Cumin', '90'], ['Fennel', '5']], totals: ['Total', '95'], empty: 'No stock yet', ...overrides,
});

test('the report HTML has the summary block, right-aligned figures, a totals row, the filters on every page and the font stack', () => {
  const html = sample();
  assert.match(html, /<section class="summary"><h3>Summary<\/h3><dl class="kpis"><div class="kpi"><dt>Units in stock<\/dt><dd>1,23,456<\/dd><\/div>/);
  assert.match(html, /<th class="num">Stock<\/th>/);
  assert.match(html, /<td>Cumin<\/td><td class="num">90<\/td>/);
  assert.match(html, /<tr class="totals"><td>Total<\/td><td class="num">95<\/td><\/tr>/);
  assert.match(html, /\.num\{text-align:right;font-variant-numeric:tabular-nums;/);
  // The filters head the page and are the first header row of the table, which repeats on each page.
  assert.match(html, /<thead><tr class="filters"><th colspan="2"><span class="filter"><strong>Customer:<\/strong> Amar Traders<\/span>/);
  assert.match(html, /thead\{display:table-header-group\}/);
  assert.equal(html.match(/<strong>Sort by:<\/strong> Stock \(descending\)/g).length, 2);
  assert.equal(html.match(/<span class="filter">Last updated 12-10-2026 08:00 UTC<\/span>/g).length, 2);
  assert.match(html, /body\{font:12px [^;]*'Noto Sans Gujarati'[^;]*sans-serif;/);
  assert.match(html, /body\{font:12px 'Liberation Sans','Noto Sans Gujarati',sans-serif;/);
  assert.ok(html.includes("default-src 'none'"));
  assert.ok(!html.includes('class="note"'));
  // Totals come after the last row, in the body: a <tfoot> would repeat them on every page.
  assert.ok(!html.includes('<tfoot'));
  assert.ok(html.indexOf('<td>Fennel</td>') < html.indexOf('<tr class="totals">'));

  const cut = sample({ note: 'Showing 2,000 of 2,500', lang: 'gu' });
  assert.match(cut, /<p class="note">Showing 2,000 of 2,500<\/p><\/body>/);
  assert.match(cut, /<html lang="gu">/);
  const none = sample({ rows: [], totals: null });
  assert.match(none, /<p class="empty">No stock yet<\/p>/);
  assert.ok(!none.includes('<table'));
  assert.ok(!sample({ totals: null }).includes('class="totals"'));
});

test('every value in the report HTML is escaped', () => {
  const attack = '<script>fetch("http://private.internal")</script>';
  const html = sample({ title: attack, company: attack, filters: [[attack, attack]], summaryTitle: attack, summary: [[attack, attack]],
    columns: [{ label: attack, numeric: true }], rows: [[attack]], totals: [attack], note: attack, empty: attack });
  assert.ok(!html.includes('<script>'));
  assert.equal(html.match(/&lt;script&gt;/g).length, 13); // the filters twice, the empty text not at all
  // The four document PDFs keep their layout.
  assert.ok(documentHtml('GRN', 'Fictional Cold Storage', { Number: 'Z1' }, ['Item'], [['Cumin']]).includes('<td>Cumin</td>'));
});

test('the page footer carries the report title without a number and the cut note on every page', async () => {
  const oldDeno = globalThis.Deno;
  globalThis.Deno = { env: { get: () => undefined } };
  try {
    const { createFooterHtml } = await import('../functions/_shared/gotenberg-client.ts');
    const footer = createFooterHtml('Fictional Cold Storage', 'સ્ટોકનો સારાંશ', '', 'Showing 2,000 of <2,500>');
    assert.ok(footer.includes('<div class="footer-left">સ્ટોકનો સારાંશ<span class="footer-note">Showing 2,000 of &lt;2,500&gt;</span></div>'));
    assert.ok(footer.includes('<span class="pageNumber"></span>'));
    assert.match(footer, /font-family: [^;]*'Noto Sans Gujarati'/);
    assert.ok(createFooterHtml('W', 'Report', '').includes('<div class="footer-left">Report</div>'));
    assert.ok(createFooterHtml('W', 'GRN', 'Z1').includes('<div class="footer-left">GRN #Z1</div>'));
  } finally { globalThis.Deno = oldDeno; }
});

test('generate-report-pdf is routed for signed-in callers and gets the document PDF environment', () => {
  const router = readFileSync(new URL('../functions/main/index.ts', import.meta.url), 'utf8');
  assert.match(router, /const allowed = new Set\(\[\.\.\.publicFunctions, [^\]]*'generate-report-pdf'\]\);/);
  assert.doesNotMatch(/const publicFunctions = new Set\(\[([^\]]+)\]\)/.exec(router)[1], /generate-report-pdf/);
  assert.deepEqual([...workerEnvNames['generate-report-pdf']].sort(),
    ['GOTENBERG_URL', 'JWT_SECRET', 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLIC_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_URL']);
  const env = { JWT_SECRET: 's', SUPABASE_URL: 'u', SUPABASE_ANON_KEY: 'a', SUPABASE_SERVICE_ROLE_KEY: 'k', SUPABASE_PUBLIC_URL: 'p',
    GOTENBERG_URL: 'g', SUPABASE_DB_URL: 'postgresql://x', CENTRAL_ISSUER: 'c', APP_ENV: 'production' };
  assert.deepEqual(Object.keys(Object.fromEntries(workerEnv('generate-report-pdf', env))).sort(),
    ['GOTENBERG_URL', 'JWT_SECRET', 'SUPABASE_ANON_KEY', 'SUPABASE_PUBLIC_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_URL']);
  assert.equal(readFileSync(new URL('../functions/generate-report-pdf/index.ts', import.meta.url), 'utf8'),
    "import { reportPdf } from '../_shared/report-pdf.ts';\nDeno.serve(reportPdf);\n");
});

test('migration 53 lists exactly the paths generate-report-pdf writes, in ASCII', () => {
  const sql = readFileSync(new URL('../migrations/00000000000053_report_pdf_retention.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(sql, /[^\x09\x0A\x0D\x20-\x7E]/);
  assert.match(sql, /^-- /);
  assert.match(sql, /NOTIFY pgrst, 'reload schema';\n$/);
  assert.match(sql, /CREATE OR REPLACE FUNCTION warehouse_maintenance\.expired_generated_documents\(p_now timestamptz DEFAULT now\(\)\)/);
  const names = /\^report\/\(([a-z|-]+)\)\//.exec(sql)[1].split('|');
  assert.deepEqual(names, [...reportNames]);
  // The document pattern of migration 43 is kept as it was.
  const old = readFileSync(new URL('../migrations/00000000000043_image_paths_and_document_expiry.sql', import.meta.url), 'utf8');
  const documentPattern = /o\.name ~ '(\^\(grn\|dispatch\|invoice\|stock\)[^']+)'/.exec(old)[1];
  assert.ok(sql.includes(`o.name ~ '${documentPattern}'`));
  const migrations = readFileSync(new URL('../tests/migrations.sh', import.meta.url), 'utf8');
  assert.match(migrations, /"\$ROOT\/tests\/report_pdf_retention\.sql"/);
});

// ---------------------------------------------------------------------------
// status: the app's Paid / Pending choice on the invoice history of one customer
// ---------------------------------------------------------------------------
const invoicePeriod = { from: '2026-01-01', to: '2026-01-31' };
const invoicesRequest = (fields = {}) => parseReportRequest({ report: 'invoice-history', customer_id: customer, ...invoicePeriod, ...fields });

test('status is accepted for the invoice history of one customer as paid or pending, and for no other request', () => {
  assert.equal(invoicesRequest().status, null);
  assert.equal(invoicesRequest({ status: null }).status, null);
  assert.equal(invoicesRequest({ status: undefined }).status, null);
  assert.equal(invoicesRequest({ status: 'paid' }).status, 'paid');
  assert.equal(invoicesRequest({ status: 'pending' }).status, 'pending');
  assert.deepEqual(invoicesRequest({ status: 'pending', lang: 'gu', sort: { field: 'net', order: 'asc' } }), {
    report: 'invoice-history', customerId: customer, from: '2026-01-01', to: '2026-01-31', sort: { field: 'net', order: 'asc' }, lang: 'gu', status: 'pending',
  });

  const value = "status must be 'paid' or 'pending'";
  const scope = 'status is only for the invoice history of one customer';
  for (const status of ['', 'all', 'Paid', 'PAID', 'unpaid', ' paid', 'paid ', 0, 1, true, false, {}, ['paid'], '<b>x</b>']) {
    rejects({ report: 'invoice-history', customer_id: customer, ...invoicePeriod, status }, value);
  }
  // Without a customer, or on any other report, status is refused, with either value.
  for (const status of ['paid', 'pending']) {
    rejects({ report: 'invoice-history', ...invoicePeriod, status }, scope);
    rejects({ report: 'invoice-history', customer_id: null, ...invoicePeriod, status }, scope);
    for (const report of reportNames.filter(name => name !== 'invoice-history')) {
      const period = periodReports.has(report) ? invoicePeriod : {};
      rejects({ report, ...period, status }, scope);
      rejects({ report, customer_id: customer, ...period, status }, scope);
    }
  }
  rejects({ report: 'stock-summary', status: 'bogus' }, scope);
  // The refusal is the fixed message and nothing else: the value sent is not echoed.
  assert.throws(() => parseReportRequest({ report: 'invoice-history', customer_id: customer, ...invoicePeriod, status: 'secret-value-4711' }),
    error => { assert.deepEqual(error, { status: 400, message: value }); return true; });
  assert.throws(() => parseReportRequest({ report: 'stock-summary', status: 'secret-value-4711' }),
    error => { assert.deepEqual(error, { status: 400, message: scope }); return true; });
  // Other keys are still unknown, with the message the app relies on.
  for (const key of ['Status', 'payment', 'payment_status', 'statuses']) {
    rejects({ report: 'invoice-history', customer_id: customer, ...invoicePeriod, [key]: 'paid' }, 'Unknown field in report request');
  }
  rejects({ report: 'stock-summary', extra: 1 }, 'Unknown field in report request');
  // A request without status is what it was, plus status: null.
  assert.deepEqual(Object.keys(invoicesRequest()).sort(), ['customerId', 'from', 'lang', 'report', 'sort', 'status', 'to']);
});

// One customer's invoices as the RPC answers since migration 61 (net_total is the invoice's total, which already holds its tax):
// five invoices, three paid and two pending, with amounts that have paise, and the RPC's own summary over all five.
// Paid: 1,600.50 (tax 288.09). Pending: 2,750.00 (tax 495.00). Together 4,350.50 (tax 783.09).
const mixedInvoices = { success: true, data: {
  summary: { total_invoices: 5, total_amount: 4350.5, net_amount: 4350.5, paid_amount: 1600.5, pending_amount: 2750 },
  invoices: [
    { invoice_number: '2026-0005', invoice_date: '2026-01-30', grn_ref: 'Z0005', total: 100, tax_amount: 18, net_total: 100, payment_status: { status: 'paid' } },
    { invoice_number: '2026-0004', invoice_date: '2026-01-28', grn_ref: 'Z0004', total: 750, tax_amount: 135, net_total: 750, payment_status: { status: 'pending' } },
    { invoice_number: '2026-0003', invoice_date: '2026-01-20', grn_ref: 'Z0003', total: 500.5, tax_amount: 90.09, net_total: 500.5, payment_status: { status: 'paid' } },
    { invoice_number: '2026-0002', invoice_date: '2026-01-12', grn_ref: 'Z0002', total: 2000, tax_amount: 360, net_total: 2000, payment_status: { status: 'pending' } },
    { invoice_number: '2026-0001', invoice_date: '2026-01-05', grn_ref: 'Z0001', total: 1000, tax_amount: 180, net_total: 1000, payment_status: { status: 'paid' } },
  ] } };
const NOW = '2026-10-12T08:00:00.000Z';
/** The document as the handler makes it: request, report, header choices and HTML. */
function invoiceDocument(lang, fields = {}, body = mixedInvoices) {
  const req = invoicesRequest({ lang, ...fields });
  const built = buildReport(req, unwrapReportBody(body));
  const filters = reportFilters(req, 'Amar Traders', built, NOW);
  const html = reportHtml({ title: built.title, company: 'Fictional Cold Storage', lang, filters, summaryTitle: label(lang, 'summary'), summary: built.summary,
    columns: built.columns, rows: built.rows, totals: built.totals, note: '', empty: built.empty });
  return { built, filters, html };
}
const invoiceNumbers = built => built.rows.map(row => row[0]);

test('with status paid only the paid invoices are listed, and the totals and the summary are theirs', () => {
  const { built, filters, html } = invoiceDocument('en', { status: 'paid' });
  assert.deepEqual(invoiceNumbers(built), ['2026-0005', '2026-0003', '2026-0001']);
  assert.deepEqual(built.rows.map(row => row[5]), ['Paid', 'Paid', 'Paid']);
  assert.deepEqual(built.totals, ['Total', '', '', '1,600.50', '288.09', '']);
  // Every figure is over the three listed invoices, not the RPC's five (5, 4,350.50, 1,600.50, 2,750.00).
  assert.deepEqual(built.summary, [['Invoices', '3'], ['Amount', '1,600.50'], ['Paid', '1,600.50'], ['Pending', '0.00']]);
  assert.equal(built.rowsTotal, 3);
  assert.equal(built.truncated, false);
  // The document says it is filtered: one more line where the customer and the period are named.
  assert.deepEqual(filters, [['Customer', 'Amar Traders'], ['Period', '01-01-2026 – 31-01-2026'], ['Payment', 'Paid'],
    ['Sort by', 'Date (descending)'], ['', 'Last updated 12-10-2026 13:30 IST']]);
  assert.equal(html.match(/<span class="filter"><strong>Payment:<\/strong> Paid<\/span>/g).length, 2, 'under the title and in the header row of the table');
  assert.ok(html.indexOf('<strong>Period:</strong>') < html.indexOf('<strong>Payment:</strong>'));
  assert.ok(html.indexOf('<strong>Payment:</strong>') < html.indexOf('<strong>Sort by:</strong>'));
  for (const number of ['2026-0005', '2026-0003', '2026-0001']) assert.ok(html.includes(`<td>${number}</td>`), number);
  for (const number of ['2026-0004', '2026-0002']) assert.ok(!html.includes(number), `${number} is not listed`);
  assert.ok(html.includes('<tr class="totals"><td>Total</td><td></td><td></td><td class="num">1,600.50</td><td class="num">288.09</td><td></td></tr>'));
  assert.ok(html.includes('<div class="kpi"><dt>Invoices</dt><dd>3</dd></div><div class="kpi"><dt>Amount</dt><dd>1,600.50</dd></div>'));
});

test('with status pending only the pending invoices are listed, and the totals and the summary are theirs', () => {
  const { built, filters, html } = invoiceDocument('en', { status: 'pending' });
  assert.deepEqual(invoiceNumbers(built), ['2026-0004', '2026-0002']);
  assert.deepEqual(built.rows.map(row => row[5]), ['Pending', 'Pending']);
  assert.deepEqual(built.totals, ['Total', '', '', '2,750.00', '495.00', '']);
  assert.deepEqual(built.summary, [['Invoices', '2'], ['Amount', '2,750.00'], ['Paid', '0.00'], ['Pending', '2,750.00']]);
  assert.deepEqual(filters[2], ['Payment', 'Pending']);
  assert.equal(html.match(/<span class="filter"><strong>Payment:<\/strong> Pending<\/span>/g).length, 2);
  for (const number of ['2026-0003', '2026-0001', '2026-0005']) assert.ok(!html.includes(number), `${number} is not listed`);
  assert.ok(html.includes('<tr class="totals"><td>Total</td><td></td><td></td><td class="num">2,750.00</td><td class="num">495.00</td><td></td></tr>'));
});

test('the Gujarati document names the choice with the app\'s words and lists the same invoices', () => {
  const paid = invoiceDocument('gu', { status: 'paid' });
  assert.deepEqual(invoiceNumbers(paid.built), ['2026-0005', '2026-0003', '2026-0001']);
  assert.deepEqual(paid.built.rows.map(row => row[5]), ['ચૂકવેલ', 'ચૂકવેલ', 'ચૂકવેલ']);
  assert.deepEqual(paid.built.totals, ['કુલ', '', '', '1,600.50', '288.09', '']);
  assert.deepEqual(paid.built.summary, [['ઇન્વૉઇસ', '3'], ['રકમ', '1,600.50'], ['ચૂકવેલ', '1,600.50'], ['બાકી', '0.00']]);
  assert.deepEqual(paid.filters[2], ['ચુકવણી', 'ચૂકવેલ']);
  assert.equal(paid.html.match(/<span class="filter"><strong>ચુકવણી:<\/strong> ચૂકવેલ<\/span>/g).length, 2);
  assert.match(paid.html, /<html lang="gu">/);
  const pending = invoiceDocument('gu', { status: 'pending' });
  assert.deepEqual(invoiceNumbers(pending.built), ['2026-0004', '2026-0002']);
  assert.deepEqual(pending.built.rows.map(row => row[5]), ['બાકી', 'બાકી']);
  assert.deepEqual(pending.built.totals, ['કુલ', '', '', '2,750.00', '495.00', '']);
  assert.deepEqual(pending.built.summary, [['ઇન્વૉઇસ', '2'], ['રકમ', '2,750.00'], ['ચૂકવેલ', '0.00'], ['બાકી', '2,750.00']]);
  assert.deepEqual(pending.filters[2], ['ચુકવણી', 'બાકી']);
  assert.equal(pending.html.match(/<span class="filter"><strong>ચુકવણી:<\/strong> બાકી<\/span>/g).length, 2);
});

test('without status the invoice history lists every invoice, adds its amounts up from the totals listed and prints no payment line', () => {
  for (const [lang, expectedSummary] of [['en', [['Invoices', '5'], ['Amount', '4,350.50'], ['Paid', '1,600.50'], ['Pending', '2,750.00']]],
    ['gu', [['ઇન્વૉઇસ', '5'], ['રકમ', '4,350.50'], ['ચૂકવેલ', '1,600.50'], ['બાકી', '2,750.00']]]]) {
    for (const fields of [{}, { status: null }]) {
      const { built, filters, html } = invoiceDocument(lang, fields);
      assert.deepEqual(invoiceNumbers(built), ['2026-0005', '2026-0004', '2026-0003', '2026-0002', '2026-0001']);
      assert.deepEqual(built.totals.slice(3, 5), ['4,350.50', '783.09']);
      assert.deepEqual(built.summary, expectedSummary, lang);
      assert.deepEqual(filters.map(([key]) => key), [label(lang, 'customer'), label(lang, 'period'), label(lang, 'sortBy'), ''], 'no payment line');
      assert.ok(!html.includes(label(lang, 'payment')), `${lang}: the document does not mention the payment choice`);
    }
  }
});

test('status works with a sort, drops invoices of no known status, and the summary covers a cut table', () => {
  const sorted = invoiceDocument('en', { status: 'paid', sort: { field: 'net', order: 'asc' } });
  assert.deepEqual(invoiceNumbers(sorted.built), ['2026-0005', '2026-0003', '2026-0001']);
  // The app still sends 'net' for the amount sort; it sorts by the amount column, which the report then names.
  assert.deepEqual(sorted.filters[3], ['Sort by', 'Amount (ascending)']);
  const largest = invoiceDocument('en', { status: 'pending', sort: { field: 'net', order: 'desc' } });
  assert.deepEqual(invoiceNumbers(largest.built), ['2026-0002', '2026-0004']);
  // An invoice whose status is neither is listed without a choice, as the app does ("All" only), and under neither choice.
  const odd = { success: true, data: { summary: { total_invoices: 6 }, invoices: [
    ...mixedInvoices.data.invoices,
    { invoice_number: '2026-0006', invoice_date: '2026-01-31', grn_ref: 'Z0006', total: 10, tax_amount: 0, net_total: 10, payment_status: { status: 'void' } },
    { invoice_number: '2026-0007', invoice_date: '2026-01-31', grn_ref: 'Z0007', total: 10, tax_amount: 0, net_total: 10 },
  ] } };
  assert.equal(invoiceDocument('en', {}, odd).built.rows.length, 7);
  assert.deepEqual(invoiceNumbers(invoiceDocument('en', { status: 'paid' }, odd).built), ['2026-0005', '2026-0003', '2026-0001']);
  assert.deepEqual(invoiceNumbers(invoiceDocument('en', { status: 'pending' }, odd).built), ['2026-0004', '2026-0002']);
  // 2,100 paid invoices of 1.00 and 100 pending ones: the table is cut at the limit, the summary and the count still cover all the paid ones.
  const many = { success: true, data: { summary: { total_invoices: 2200, net_amount: 2200, paid_amount: 2100, pending_amount: 100 }, invoices: [
    ...Array.from({ length: 2100 }, (_, index) => ({ invoice_number: `P${index}`, invoice_date: '2026-01-05', grn_ref: 'Z', total: 1, tax_amount: 0, net_total: 1, payment_status: { status: 'paid' } })),
    ...Array.from({ length: 100 }, (_, index) => ({ invoice_number: `Q${index}`, invoice_date: '2026-01-06', grn_ref: 'Z', total: 1, tax_amount: 0, net_total: 1, payment_status: { status: 'pending' } })),
  ] } };
  const cutPaid = invoiceDocument('en', { status: 'paid' }, many).built;
  assert.equal(cutPaid.rows.length, maxReportRows);
  assert.equal(cutPaid.rowsTotal, 2100);
  assert.equal(cutPaid.truncated, true);
  assert.deepEqual(cutPaid.summary, [['Invoices', '2,100'], ['Amount', '2,100.00'], ['Paid', '2,100.00'], ['Pending', '0.00']]);
  const wholePending = invoiceDocument('en', { status: 'pending' }, many).built;
  assert.equal(wholePending.rows.length, 100);
  assert.equal(wholePending.truncated, false);
  assert.deepEqual(wholePending.summary, [['Invoices', '100'], ['Amount', '100.00'], ['Paid', '0.00'], ['Pending', '100.00']]);
});

test('the handler takes the header choices from reportFilters and reports status in the answer only when it is set', () => {
  const handler = readFileSync(new URL('../functions/_shared/report-pdf.ts', import.meta.url), 'utf8');
  assert.match(handler, /const filters = reportFilters\(request, customerName, report, now\);/);
  assert.match(handler, /if \(request\.status\) document\.status = request\.status;/);
  // The RPC is still called as the caller, with the arguments it had: status filters after the answer, no new privilege.
  const one = invoicesRequest({ status: 'paid' });
  assert.deepEqual(reportLevel(one).rpc(one), { name: 'get_customer_invoice_summary', args: { p_customer_uuid: customer, p_from_date: '2026-01-01', p_to_date: '2026-01-31' } });
  assert.deepEqual(reportLevel(one).rpc(one), reportLevel(invoicesRequest()).rpc(invoicesRequest()));
});

// sha256 of the complete report HTML of every fixture above, both levels and both languages, made with the code of commit 2dbac98
// (before status) and a fixed clock. A request without status must print exactly what it printed. The time stamp of all 28
// documents changes on purpose (it is India's day and clock, "12-10-2026 13:30 IST", and was the UTC day and clock, "12-10-2026
// 08:00 UTC"); it is put back first, twice per document (under the title and in the table's header). No fixture holds a night
// moment (their dates are plain days), so no date column changes. Ten documents change on purpose
// and are compared with the old text put back: the two Gujarati documents that held an English label ('Latest invoice',
// 'Last activity'), the four stock aging documents, whose summary figure for the oldest stock is now the item count of the
// 364+ bucket under the app's label (it was 'Over 1 year', the bags over 365 days; both are 0 in these fixtures), and the four
// invoice history documents (migration 61). The invoice history fixtures now hold the RPC's answer of migration 61, where the
// net figures are the invoice's total (1,000.00; they were total + tax, 1,180.00). Both levels lost the Net amount column and
// figure, which would repeat the amount: the one-customer documents print 'Amount' in the summary where it said 'Net amount'
// (added up from the totals listed), the all-customers ones keep their Amount column and figure. The old text (the Net amount
// column of 1,180.00, its cell in the totals row and its figure in the summary) is put back piece by piece, each piece a
// counted text; the label 'Net amount' is no longer in report-labels.ts, so the test holds the old words itself.
// Then the Gujarati wording review of 2026-10-12 (migration 62's commit) changes all fourteen Gujarati documents: the sort line
// says 'સૉર્ટનો ક્રમ' where it said 'આ મુજબ સૉર્ટ કરો' (twice per document), and three of them reword a column header ('આવક નં.' for
// the GRN number in the one-customer GRN activity, stock summary and stock aging; 'કેટલા દિવસથી (દિવસ)' for the stock age in the
// stock aging, which is also its sort line). The old text is put back the same way (`gujaratiReview`). The fourteen English
// documents are unchanged by it, and the Paid / Pending rule changes none of the 28: the invoice history fixtures hold one
// pending invoice with no payment, which prints 'Pending' as before.
const baselineHtml = {
  'grn-activity/customer/en': '268d1e5d7c4a28cb3f11aa1a8512036f1feecb339c2bc669a311951d03091263',
  'grn-activity/customer/gu': '2dc25c75fb437a85412b51329e139ef4132f8ea211b4f294e530b6f80f28c367',
  'grn-activity/all/en': 'ee04e65ab64a4d5fdecb2124d80ba2f99f345937f7d59d2558462d4abd6179aa',
  'grn-activity/all/gu': '392191cf817708dec663ac12c113daef3eadbb092957cf8f20c3b8c72b9c2e1d',
  'dispatch-activity/customer/en': '8c565a8024f796afd50c4662a0d2020f99f0b439896901ebfc7d87071eb92c56',
  'dispatch-activity/customer/gu': 'ca9f4c35d3037b08cf3a7a02adecb7590bab080e2ae4f60787ab41eac2e3a141',
  'dispatch-activity/all/en': '6f2489a5906ca3d3675e8136bef0984d280c31f2f8a79375e1e2e3851298d95e',
  'dispatch-activity/all/gu': '06962fcd1214fb4143f494c940cbc26853cdfebc9062392583b5e11661aee8a5',
  'invoice-history/customer/en': '48ee2cf16f3b1f8420b0b26da8ae71116a5e186d9818b56adacf56964d599f31',
  'invoice-history/customer/gu': 'dd206569b66da76118701c8168aa630426ef0a2d0bba39cc584ebf33391f5625',
  'invoice-history/all/en': '6ce0a66071ef2b6b6037a85e83fe65f80338747047f121679f915c5ff21866cc',
  'invoice-history/all/gu': 'c33240e45f72d09d0fdc46d0e29a64550fb98dc6495026e20f003095dff72c4a',
  'stock-summary/customer/en': 'c8058911bcd79090092e8894c7aac9749dab3cd8c10d76bbacc4c6aa398cbe48',
  'stock-summary/customer/gu': 'ab7dc6c78818a1ec94a536db6190a8a5f072a5f36a721677d917f78c364d0a69',
  'stock-summary/all/en': 'f08d93de326e40975b452540026eb251a279250dc89e7a6042980492ef9d6fd0',
  'stock-summary/all/gu': 'fca405f995c3859e9e200d0e3fe3c6f2f3a1f12b9930194cf47b3497a24911da',
  'stock-aging/customer/en': 'cd6e39070e193cc338f90c68cd05d156cea3c80bf0ed679804c156f0af64f5d5',
  'stock-aging/customer/gu': 'c043e77f385700e70ce99c381d2a74de996b143978d55509eb6c94e3fcd6f88a',
  'stock-aging/all/en': 'd9fb25dc404eca762f2f7f0ad2bfd9d3368cf128b73a0ea80b1dc5f782b126fe',
  'stock-aging/all/gu': '92084915881af766f54d0c969869942a0b074824127d42bede2d6385ce906e4e',
  'item-stock-summary/customer/en': '636898edb986ef9d5f7dd8ada0a0a00e7bb1c6b74941213a20ad4c5fba5e15ba',
  'item-stock-summary/customer/gu': 'bdeb9ef150b970b936c216a54f5582590cc36526b118f1c5c81ae35dc2e41d17',
  'item-stock-summary/all/en': '8c4f9ae580c42e74315402b0f15bade523c7529ecd3e9587dfa4ffdb31f3d794',
  'item-stock-summary/all/gu': 'f631a4f1f99c83795d608e6f714f45791ac7f695fc64a316f191cd29f84cc8e7',
  'customer-activity/customer/en': 'c5044dc477b3bfef7fc17a9fb2268cc9c3285e7475e552d370dac08bb60540ec',
  'customer-activity/customer/gu': 'd670d3ec926f195afe2ea75ca85803a3e9a097b60f6f307fb97881366074f7e0',
  'customer-activity/all/en': '9d61344bfa50d911dd465f65b32c0dc3a07d3b080910b0a9253127cd25e69498',
  'customer-activity/all/gu': '0c72342b628cb8b00989e1156d3d5b2d9a1458ce6a518bb3511a564b5bc5bbb5',
};

// What the new invoice history documents (fixtures of migration 61: net = total = 1,000.00, tax 180.00, one pending invoice)
// hold in place of the old ones, as [new text, old text, times]. The old documents had a Net amount column and figure of
// 1,180.00 = total + tax (all-customers: 1,180.00 too, from net_amount).
function oldInvoiceHistory(level, lang) {
  const word = key => label(lang, key);
  const oldNet = { en: 'Net amount', gu: 'ચોખ્ખી રકમ' }[lang];
  const num = value => `<td class="num">${value}</td>`;
  if (level === 'all') {
    return [
      ['<th colspan="4">', '<th colspan="5">', 1],
      [`<th class="num">${word('amount')}</th>`, `<th class="num">${word('amount')}</th><th class="num">${oldNet}</th>`, 1],
      [`${num('1,000.00')}<td>31-01-2026</td>`, `${num('1,000.00')}${num('1,180.00')}<td>31-01-2026</td>`, 1],
      [`${num('1,000.00')}<td></td></tr>`, `${num('1,000.00')}${num('1,180.00')}<td></td></tr>`, 1],
      [`<dt>${word('amount')}</dt><dd>1,000.00</dd></div></dl>`,
        `<dt>${word('amount')}</dt><dd>1,000.00</dd></div><div class="kpi"><dt>${oldNet}</dt><dd>1,180.00</dd></div></dl>`, 1],
    ];
  }
  const status = `<td>${formatCell('status', 'pending', lang)}</td>`;
  return [
    ['<th colspan="6">', '<th colspan="7">', 1],
    [`<th class="num">${word('tax')}</th><th>${word('status')}</th>`, `<th class="num">${word('tax')}</th><th class="num">${oldNet}</th><th>${word('status')}</th>`, 1],
    [num('180.00') + status, num('180.00') + num('1,180.00') + status, 1],
    [`${num('180.00')}<td></td></tr>`, `${num('180.00')}${num('1,180.00')}<td></td></tr>`, 1],
    [`<dt>${word('amount')}</dt><dd>1,000.00</dd>`, `<dt>${oldNet}</dt><dd>1,180.00</dd>`, 1],
    [`<dt>${word('pending')}</dt><dd>1,000.00</dd>`, `<dt>${word('pending')}</dt><dd>1,180.00</dd>`, 1],
  ];
}

test('without status every existing fixture prints byte for byte the HTML it printed before, but for the time stamp and the changes on purpose', () => {
  const english = ['<div class="kpi"><dt>Items over 364 days</dt><dd>0</dd></div>', '<div class="kpi"><dt>Over 1 year</dt><dd>0</dd></div>'];
  const gujarati = ['<div class="kpi"><dt>૩૬૪ દિવસથી વધુ જૂની આઇટમ</dt><dd>0</dd></div>', '<div class="kpi"><dt>૧ વર્ષથી વધુ</dt><dd>0</dd></div>'];
  const swapped = {
    'invoice-history/all/gu': ['છેલ્લું ઇન્વૉઇસ', 'Latest invoice'], 'customer-activity/all/gu': ['છેલ્લી કામગીરી', 'Last activity'],
    'stock-aging/customer/en': english, 'stock-aging/all/en': english, 'stock-aging/customer/gu': gujarati, 'stock-aging/all/gu': gujarati,
  };
  // The Gujarati wording review of 2026-10-12 (the owner applied its suggestions) changes every Gujarati document: the sort line
  // (under the title and in the table's header row) and, where the table has the column, the GRN number and the stock age
  // headers. [new text, old text, times]. The stock age text is told from the averageAge one ('સરેરાશ કેટલા દિવસથી (દિવસ)') by
  // what comes before it: the closing tag of the header cell, or the label of the sort line. The English documents are unchanged.
  const gujaratiReview = (key) => [
    ['<strong>સૉર્ટનો ક્રમ:</strong>', '<strong>આ મુજબ સૉર્ટ કરો:</strong>', 2],
    ...(['grn-activity/customer/gu', 'stock-summary/customer/gu', 'stock-aging/customer/gu'].includes(key)
      ? [['>આવક નં.</th>', '>આવક પાવતી નંબર</th>', 1]] : []),
    ...(key === 'stock-aging/customer/gu'
      ? [['>કેટલા દિવસથી (દિવસ)</th>', '>માલ કેટલા દિવસથી પડ્યો છે (દિવસ)</th>', 1],
        ['</strong> કેટલા દિવસથી (દિવસ) (', '</strong> માલ કેટલા દિવસથી પડ્યો છે (દિવસ) (', 2]] : []),
  ];
  let compared = 0;
  for (const report of reportNames) {
    for (const level of ['customer', 'all']) {
      for (const lang of ['en', 'gu']) {
        const period = periodReports.has(report) ? { from: '2026-01-01', to: '2026-01-31' } : {};
        const req = parseReportRequest({ report, lang, ...period, ...(level === 'customer' ? { customer_id: customer } : {}) });
        const built = buildReport(req, unwrapReportBody(fixtures[report][level]));
        const filters = reportFilters(req, level === 'customer' ? 'Amar Traders' : null, built, NOW);
        let html = reportHtml({ title: built.title, company: 'Fictional Cold Storage', lang, filters, summaryTitle: label(lang, 'summary'), summary: built.summary,
          columns: built.columns, rows: built.rows, totals: built.totals, note: '', empty: built.empty });
        const key = `${report}/${level}/${lang}`;
        const stamp = time => label(lang, 'updated', { time });
        assert.equal(html.split(stamp('12-10-2026 13:30 IST')).length - 1, 2, `${key} holds the new time stamp twice`);
        html = html.replaceAll(stamp('12-10-2026 13:30 IST'), stamp('12-10-2026 08:00 UTC'));
        if (swapped[key]) {
          assert.equal(html.split(swapped[key][0]).length - 1, 1, `${key} holds the new text once`);
          html = html.replace(swapped[key][0], swapped[key][1]);
        }
        if (lang === 'gu') {
          for (const [added, old, times] of gujaratiReview(key)) {
            assert.equal(html.split(added).length - 1, times, `${key} holds ${added} ${times} time(s)`);
            html = html.replaceAll(added, old);
          }
        }
        if (report === 'invoice-history') {
          for (const [added, old, times] of oldInvoiceHistory(level, lang)) {
            assert.equal(html.split(added).length - 1, times, `${key} holds ${added} ${times} time(s)`);
            html = html.replaceAll(added, old);
          }
        }
        assert.equal(createHash('sha256').update(html).digest('hex'), baselineHtml[key], key);
        compared += 1;
      }
    }
  }
  assert.equal(compared, 28);
  assert.deepEqual(Object.keys(baselineHtml).length, 28);
});

test('the one-customer GRN PDF weighs each GRN from its lines, with or without migration 59, and the all-customers one prints the RPC weight', () => {
  // Before migration 59 the RPC's total_weight of a GRN was the sum of its per-bag weights (30 and 75); after it, the kg (1500 and 4020).
  const before = structuredClone(fixtures['grn-activity'].customer);
  const after = structuredClone(fixtures['grn-activity'].customer);
  after.data.grns[0].total_weight = 1500;
  after.data.grns[1].total_weight = 4020;
  after.data.summary.total_weight_kg = 5520;
  const request = parseReportRequest({ report: 'grn-activity', customer_id: customer, from: '2026-01-01', to: '2026-01-31' });
  const built = [before, after].map(answer => buildReport(request, unwrapReportBody(answer)));
  assert.deepEqual(built[0], built[1]);
  assert.deepEqual(built[1].rows.map(row => row[4]), ['1,500', '4,020']);
  assert.deepEqual(built[1].summary[2], ['Weight (kg)', '5,520']);
  // The all-customers level prints get_all_grn_activity's own weights.
  const all = build('grn-activity', 'all', 'en');
  assert.deepEqual(all.rows.map(row => row[3]), ['234.5', '1,000']);
  assert.deepEqual(all.summary[3], ['Weight (kg)', '1,234.5']);
});

test('migration 59 is ASCII, patches only the weight totals with counted markers, and its SQL test is registered after the dispatch weight one', () => {
  const sql = readFileSync(new URL('../migrations/00000000000059_grn_activity_weight.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(sql, /[^\x09\x0A\x0D\x20-\x7E]/);
  assert.match(sql, /^-- /);
  assert.match(sql, /NOTIFY pgrst, 'reload schema';\n$/);
  // Every entry: [signature, before text, after text, expected count]; the whole VALUES list, in order.
  const entries = [...sql.matchAll(/\('(public\.[a-z_]+\([a-z,]+\))',\s*\$b\$(.*?)\$b\$,\s*\$a\$(.*?)\$a\$, (\d+)\)/gs)]
    .map(match => [match[1], match[2], match[3], Number(match[4])]);
  assert.deepEqual(entries.map(([signature, , , times]) => [signature, times]), [
    ['public.get_customer_grn_activity(uuid,date,date)', 2], ['public.get_customer_grn_activity(uuid,date,date)', 1],
    ['public.get_customer_grn_activity(uuid,date,date)', 1], ['public.get_customer_grn_activity(uuid,date,date)', 1],
    ['public.get_customer_grn_activity(uuid,date,date)', 1], ['public.get_customer_grn_activity(uuid,date,date)', 1],
    ['public.get_all_grn_activity(date,date)', 1], ['public.get_all_grn_activity(date,date)', 1],
  ]);
  // One entry changes text (the bags join the sum, twice); every other one is a guard: its text is unchanged.
  const changing = entries.filter(([, before, after]) => before !== after);
  assert.deepEqual(changing.map(([, before, after]) => [before, after]), [
    ['SUM(grt.weight) as total_weight', 'COALESCE(SUM(grt.weight::numeric * grt.qty), 0) as total_weight'],
  ]);
  const migrations = readFileSync(new URL('../tests/migrations.sh', import.meta.url), 'utf8');
  // Registered, and after the dispatch weight test; what else follows it in the list is not this test's business.
  const dispatchWeight = migrations.indexOf('"$ROOT/tests/report_dispatch_weight.sql"');
  const grnWeight = migrations.indexOf('"$ROOT/tests/report_grn_weight.sql"');
  assert.ok(dispatchWeight >= 0 && grnWeight > dispatchWeight);
});

// ---------------------------------------------------------------------------
// The stock aging PDF says what the app's screen says about the oldest stock
// ---------------------------------------------------------------------------
// The app's screen (app/reports/stock-aging.tsx) shows "Items over 364 days": the item count of the '364+' bucket of the answer
// (by_bucket['364+'].item_count), the same figure as its red bar. The answers below give every neighbouring figure a different
// value: 3 items in the bucket, 2 items over 365 days, 120 bags over 365 days, 320 bags in the bucket.
const oldestBuckets = {
  '0-120': { item_count: 1, total_quantity: 100, percentage: 20 }, '121-240': { item_count: 0, total_quantity: 0, percentage: 0 },
  '241-364': { item_count: 1, total_quantity: 80, percentage: 20 }, '364+': { item_count: 3, total_quantity: 320, percentage: 60 },
};
const agingOldest = {
  customer: { success: true, data: { summary: { total_items: 5, total_quantity: 500, average_age_days: 300, items_over_365_days: 2, qty_over_365_days: 120 },
    by_bucket: oldestBuckets, items: [] } },
  all: { success: true, data: { summary: { total_customers: 2, total_items: 5, total_quantity: 500, average_age_days: 300, items_over_365_days: 2, qty_over_365_days: 120 },
    by_bucket: oldestBuckets, by_customer: [
      { customer_name: 'Amar Traders', total_stock: 300, average_age_days: 320, items_over_365_days: 1 },
      { customer_name: 'Bharat Foods', total_stock: 200, average_age_days: 270, items_over_365_days: 1 },
    ] } },
};
const aging = (level, lang, answer = agingOldest) => {
  const body = unwrapReportBody(answer[level]);
  const req = parseReportRequest({ report: 'stock-aging', lang, ...(level === 'customer' ? { customer_id: customer } : {}) });
  const built = buildReport(req, body);
  const filters = reportFilters(req, level === 'customer' ? 'Amar Traders' : null, built, NOW);
  const html = reportHtml({ title: built.title, company: 'Fictional Cold Storage', lang, filters, summaryTitle: label(lang, 'summary'), summary: built.summary,
    columns: built.columns, rows: built.rows, totals: built.totals, note: '', empty: built.empty });
  return { built, html };
};

test('the stock aging PDF prints the item count of the 364+ bucket under the app\'s label, not the bags over 365 days', () => {
  assert.equal(label('en', 'itemsOver364'), 'Items over 364 days');
  assert.equal(label('gu', 'itemsOver364'), '૩૬૪ દિવસથી વધુ જૂની આઇટમ');
  const one = { en: aging('customer', 'en'), gu: aging('customer', 'gu') };
  assert.deepEqual(one.en.built.summary, [['Units in stock', '500'], ['Average age (days)', '300'], ['Items over 364 days', '3']]);
  assert.deepEqual(one.gu.built.summary, [['સ્ટોકમાં નંગ', '500'], ['સરેરાશ કેટલા દિવસથી (દિવસ)', '300'], ['૩૬૪ દિવસથી વધુ જૂની આઇટમ', '3']]);
  assert.ok(one.en.html.includes('<div class="kpi"><dt>Items over 364 days</dt><dd>3</dd></div>'));
  assert.ok(one.gu.html.includes('<div class="kpi"><dt>૩૬૪ દિવસથી વધુ જૂની આઇટમ</dt><dd>3</dd></div>'));
  // Not the bags over 365 days (120), not the items over 365 days (2), not the bags in the bucket (320), and no "Over 1 year" tile.
  for (const html of [one.en.html, one.gu.html]) {
    assert.ok(!html.includes('<dd>120</dd>') && !html.includes('<dd>2</dd>') && !html.includes('<dd>320</dd>'));
    assert.ok(!html.includes('Over 1 year') && !html.includes('૧ વર્ષથી વધુ'));
  }
  // The all-customers level reads the same place of its answer.
  const all = { en: aging('all', 'en'), gu: aging('all', 'gu') };
  assert.deepEqual(all.en.built.summary, [['Customers', '2'], ['Units in stock', '500'], ['Average age (days)', '300'], ['Items over 364 days', '3']]);
  assert.deepEqual(all.gu.built.summary, [['વેપારીઓ', '2'], ['સ્ટોકમાં નંગ', '500'], ['સરેરાશ કેટલા દિવસથી (દિવસ)', '300'], ['૩૬૪ દિવસથી વધુ જૂની આઇટમ', '3']]);
  assert.ok(all.en.html.includes('<div class="kpi"><dt>Items over 364 days</dt><dd>3</dd></div>'));
  // Its table keeps the per-customer count of items over 365 days under 'Over 1 year' (the answer has no per-customer bucket count).
  assert.deepEqual(all.en.built.columns.map(column => column.label), ['Customer', 'Stock', 'Average age (days)', 'Over 1 year']);
  assert.deepEqual(all.en.built.rows.map(row => row[3]), ['1', '1']);
  assert.deepEqual(all.en.built.totals, ['Total', '500', '', '2']);
  // A bucket the answer does not hold is 0, as on the screen: the figure never falls back to the bags over 365 days.
  for (const level of ['customer', 'all']) {
    const without = structuredClone(agingOldest);
    delete without[level].data.by_bucket;
    assert.equal(aging(level, 'en', without).built.summary.at(-1)[1], '0', level);
    const empty = structuredClone(agingOldest);
    empty[level].data.by_bucket = {};
    assert.equal(aging(level, 'en', empty).built.summary.at(-1)[1], '0', level);
  }
});

test('the source comments of report-labels.ts point at app keys that exist', () => {
  const source = readFileSync(new URL('../functions/_shared/report-labels.ts', import.meta.url), 'utf8');
  for (const gone of ['reports.period.dateRange', 'reports.dispatchActivity.customersWithDispatches', 'reports.stockSummary.unitsInStock',
    'reports.stockSummary.itemsInStorage', 'reports.stockSummary.customersWithStock', 'reports.stockAging.overOneYear']) {
    assert.ok(!source.includes(gone), `${gone} no longer exists in the app`);
  }
  assert.match(source, /dateRange: .*\/\/ filters\.chip\.dateBetween/);
  assert.equal(source.split('(wording kept from an earlier app version)').length - 1, 5);
  assert.match(source, /itemsOver364: .*\/\/ reports\.stockAging\.itemsOver364/);
});

// ---------------------------------------------------------------------------
// Invoice amounts are the invoice's total (migration 61), with or without the migration
// ---------------------------------------------------------------------------
// Three invoices of one customer, as a database WITHOUT migration 61 answers them: net_total is total + labour + tax - discount
// (labour, tax and discount counted a second time) and the summary's net, paid and pending are sums of those. The same three
// invoices as a database WITH migration 61 answers them: net_total is the total. 109 pending, 111 and 14 (the worked example:
// 1 bag, charge 10, labour 2.50, tax 5%, total 14, old net 17.50) paid; together 234, paid 125, pending 109.
const threeInvoices = (net, summary) => ({ success: true, data: { summary: { total_invoices: 3, total_amount: 234, ...summary }, invoices: [
  { invoice_number: '2026-6103', invoice_date: '2026-10-12', grn_ref: 'G3', total: 109, labour: 12, tax_amount: 17, discount: 0, net_total: net(138, 109), payment_status: { status: 'pending' } },
  { invoice_number: '2026-6102', invoice_date: '2026-10-05', grn_ref: 'G2', total: 111, labour: 12, tax_amount: 6, discount: 7.5, net_total: net(121.5, 111), payment_status: { status: 'paid' } },
  { invoice_number: '2026-6101', invoice_date: '2026-09-20', grn_ref: 'G1', total: 14, labour: 2.5, tax_amount: 1, discount: 0, net_total: net(17.5, 14), payment_status: { status: 'paid' } },
] } });
const withoutMigration61 = threeInvoices(old => old, { net_amount: 276.5, paid_amount: 139, pending_amount: 138 });
const withMigration61 = threeInvoices((old, total) => total, { net_amount: 234, paid_amount: 125, pending_amount: 109 });

test('the invoice history of one customer prints the same on a database with or without migration 61, from the invoices\' totals', () => {
  for (const lang of ['en', 'gu']) {
    for (const fields of [{}, { status: 'paid' }, { status: 'pending' }, { sort: { field: 'net', order: 'asc' } }]) {
      const before = invoiceDocument(lang, fields, withoutMigration61);
      const after = invoiceDocument(lang, fields, withMigration61);
      assert.deepEqual(before.built, after.built, `${lang} ${JSON.stringify(fields)}`);
      assert.equal(before.html, after.html, `${lang} ${JSON.stringify(fields)}`);
    }
  }
  const built = invoiceDocument('en', {}, withoutMigration61).built;
  assert.deepEqual(built.columns.map(column => column.label), ['Invoice number', 'Date', 'GRN', 'Amount', 'Tax', 'Status']);
  assert.deepEqual(built.rows, [
    ['2026-6103', '12-10-2026', 'G3', '109.00', '17.00', 'Pending'],
    ['2026-6102', '05-10-2026', 'G2', '111.00', '6.00', 'Paid'],
    ['2026-6101', '20-09-2026', 'G1', '14.00', '1.00', 'Paid'],
  ]);
  assert.deepEqual(built.totals, ['Total', '', '', '234.00', '24.00', '']);
  // Amount, paid and pending are worked out from the totals listed (125.00 + 109.00 = 234.00), not the RPC's 276.50, 139.00, 138.00.
  assert.deepEqual(built.summary, [['Invoices', '3'], ['Amount', '234.00'], ['Paid', '125.00'], ['Pending', '109.00']]);
  const html = invoiceDocument('en', {}, withoutMigration61).html;
  for (const wrong of ['17.50', '121.50', '138.00', '276.50', '139.00']) assert.ok(!html.includes(wrong), `${wrong} is not printed`);
  assert.ok(html.includes('<td class="num">14.00</td>'), 'the worked example is 14.00');
  // With a choice the figures cover the listed invoices only, as before.
  assert.deepEqual(invoiceDocument('en', { status: 'paid' }, withoutMigration61).built.summary,
    [['Invoices', '2'], ['Amount', '125.00'], ['Paid', '125.00'], ['Pending', '0.00']]);
  assert.deepEqual(invoiceDocument('en', { status: 'pending' }, withoutMigration61).built.summary,
    [['Invoices', '1'], ['Amount', '109.00'], ['Paid', '0.00'], ['Pending', '109.00']]);
});

test('the invoice history of all customers prints total_amount once, as the amount, with or without migration 61', () => {
  const answer = net => ({ success: true, data: { summary: { total_invoices: 4, total_customers: 2, total_amount: 502, net_amount: net(583, 502) }, by_customer: [
    { customer_name: 'Amar Traders', invoice_count: 3, total_amount: 323, net_amount: net(375, 323), latest_invoice_date: '2026-10-12' },
    { customer_name: 'Bharat Foods', invoice_count: 1, total_amount: 179, net_amount: net(208, 179), latest_invoice_date: '2026-10-08' },
  ] } });
  const req = parseReportRequest({ report: 'invoice-history', ...invoicePeriod });
  const before = buildReport(req, unwrapReportBody(answer(old => old)));
  const after = buildReport(req, unwrapReportBody(answer((old, total) => total)));
  assert.deepEqual(before, after);
  assert.deepEqual(after.columns.map(column => column.label), ['Customer', 'Invoices', 'Amount', 'Latest invoice']);
  assert.deepEqual(after.rows, [['Amar Traders', '3', '323.00', '12-10-2026'], ['Bharat Foods', '1', '179.00', '08-10-2026']]);
  assert.deepEqual(after.totals, ['Total', '4', '502.00', '']);
  assert.deepEqual(after.summary, [['Invoices', '4'], ['Customers', '2'], ['Amount', '502.00']]);
});

test('the app\'s net sort of the invoice history is still accepted at both levels and sorts by the amount', () => {
  // The amounts are 100, 750, 500.50, 2,000 and 1,000.00 (numbers 0005, 0004, 0003, 0002, 0001): the amount order differs from the date order.
  const byAmount = ['2026-0005', '2026-0003', '2026-0004', '2026-0001', '2026-0002'];
  const amountAsc = invoiceDocument('en', { sort: { field: 'amount', order: 'asc' } });
  assert.deepEqual(invoiceNumbers(amountAsc.built), byAmount);
  for (const [order, expected] of [['asc', byAmount], ['desc', [...byAmount].reverse()]]) {
    const net = invoiceDocument('en', { sort: { field: 'net', order } });
    assert.deepEqual(invoiceNumbers(net.built), expected, order);
    // The report names the column it sorted by, and says so in the header and in the answer's sort.
    assert.deepEqual(net.built.sort, { field: 'amount', order, label: `Amount (${order === 'asc' ? 'ascending' : 'descending'})` }, order);
    assert.deepEqual(net.filters.at(-2), ['Sort by', net.built.sort.label]);
  }
  assert.deepEqual(invoiceDocument('gu', { sort: { field: 'net', order: 'desc' } }).built.sort.label, 'રકમ (ઉતરતા ક્રમમાં)');
  // It is an alias, not a column: no net column is printed, and other fields that are not columns still give the default order.
  assert.deepEqual(sortFields(invoicesRequest()), ['invoice_no', 'date', 'grn', 'amount', 'tax', 'status', 'net']);
  for (const field of ['net_total', 'constructor', '__proto__', 'hasownproperty']) {
    const fallback = invoiceDocument('en', { sort: { field, order: 'asc' } });
    assert.deepEqual(fallback.built.sort, { field: 'date', order: 'desc', label: 'Date (descending)' }, field);
    assert.deepEqual(invoiceNumbers(fallback.built), ['2026-0005', '2026-0004', '2026-0003', '2026-0002', '2026-0001'], field);
  }
  // The all-customers level lost its net column the same way: the app's net sort is an alias of its amount, and sorts by it.
  const customers = { success: true, data: { summary: { total_invoices: 6 }, by_customer: [
    { customer_name: 'Amar Traders', invoice_count: 3, total_amount: 323, latest_invoice_date: '2026-10-12' },
    { customer_name: 'Bharat Foods', invoice_count: 5, total_amount: 179, latest_invoice_date: '2026-10-08' },
    { customer_name: 'Chandra Stores', invoice_count: 1, total_amount: 250, latest_invoice_date: '2026-10-15' },
  ] } };
  const allBuilt = (fields, lang = 'en') => buildReport(parseReportRequest({ report: 'invoice-history', lang, ...invoicePeriod, ...fields }), unwrapReportBody(customers));
  const names = built => built.rows.map(row => row[0]);
  // By amount (179, 250, 323) is not the order by invoice count (1, 3, 5), by latest invoice (08, 12, 15 Oct) or by name.
  assert.deepEqual(names(allBuilt({})), ['Amar Traders', 'Chandra Stores', 'Bharat Foods']);
  for (const [order, expected] of [['asc', ['Bharat Foods', 'Chandra Stores', 'Amar Traders']], ['desc', ['Amar Traders', 'Chandra Stores', 'Bharat Foods']]]) {
    const net = allBuilt({ sort: { field: 'net', order } });
    assert.deepEqual(names(net), expected, order);
    assert.deepEqual(net.sort, { field: 'amount', order, label: `Amount (${order === 'asc' ? 'ascending' : 'descending'})` }, order);
    assert.deepEqual(allBuilt({ sort: { field: 'amount', order } }).rows, net.rows, order);
  }
  assert.deepEqual(allBuilt({ sort: { field: 'net', order: 'asc' } }, 'gu').sort.label, 'રકમ (ચઢતા ક્રમમાં)');
  assert.deepEqual(names(allBuilt({ sort: { field: 'invoices', order: 'asc' } })), ['Chandra Stores', 'Amar Traders', 'Bharat Foods'], 'its own columns still sort');
  assert.deepEqual(names(allBuilt({ sort: { field: 'latest', order: 'asc' } })), ['Bharat Foods', 'Amar Traders', 'Chandra Stores']);
  assert.deepEqual(allBuilt({ sort: { field: 'constructor', order: 'asc' } }).sort, { field: 'amount', order: 'desc', label: 'Amount (descending)' });
  assert.deepEqual(sortFields(parseReportRequest({ report: 'invoice-history', ...invoicePeriod })), ['customer', 'invoices', 'amount', 'latest', 'net']);
});

test('migration 61 is ASCII, patches only the invoice amounts with counted markers, and its SQL test is registered after the PDF retention one', () => {
  const sql = readFileSync(new URL('../migrations/00000000000061_invoice_report_amounts.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(sql, /[^\x09\x0A\x0D\x20-\x7E]/);
  assert.match(sql, /^-- /);
  assert.match(sql, /NOTIFY pgrst, 'reload schema';\n$/);
  assert.doesNotMatch(sql, /authorize_rpc\(|CREATE (OR REPLACE )?FUNCTION (?!pg_temp)/, 'it redefines no function and does not touch the guard');
  // Every entry: [step, signature, before text, after text, expected count], in order.
  const entries = [...sql.matchAll(/\((\d+), '(public\.[a-z_]+\([a-z,]+\))',\s*\$b\$(.*?)\$b\$,\s*\$a\$(.*?)\$a\$, (\d+)\)/gs)]
    .map(match => [Number(match[1]), match[2], match[3], match[4], Number(match[5])]);
  assert.deepEqual(entries.map(([step, signature, , , times]) => [step, signature, times]), [
    [1, 'public.get_customer_invoice_summary(uuid,date,date,integer)', 2], [2, 'public.get_customer_invoice_summary(uuid,date,date,integer)', 1],
    [3, 'public.get_customer_invoice_summary(uuid,date,date,integer)', 1], [4, 'public.get_customer_invoice_summary(uuid,date,date,integer)', 1],
    [5, 'public.get_customer_activity_detail(uuid,date,date)', 2], [6, 'public.get_customer_activity_detail(uuid,date,date)', 1],
    [7, 'public.get_all_customer_activity_summary(date,date)', 1],
  ]);
  // The three sums become the total; none of the new texts mentions labour, tax or discount.
  for (const [step, , before, after] of entries.filter(([step]) => [1, 5, 6, 7].includes(step))) {
    assert.match(before, /\+ COALESCE\((i\.)?labour, 0\) \+ COALESCE\((i\.)?tax_amount, 0\) - COALESCE\((i\.)?discount, 0\)/, `step ${step}`);
    assert.doesNotMatch(after, /labour|tax_amount|discount/, `step ${step}`);
  }
  const migrations = readFileSync(new URL('../tests/migrations.sh', import.meta.url), 'utf8');
  // Registered once, after the PDF retention test and before the report_to_date one; what follows is not this test's business.
  const retention = migrations.indexOf('"$ROOT/tests/report_pdf_retention.sql"');
  const amounts = migrations.indexOf('"$ROOT/tests/report_invoice_amounts.sql"');
  assert.equal(migrations.split('"$ROOT/tests/report_invoice_amounts.sql"').length - 1, 1);
  assert.ok(retention >= 0 && amounts > retention && amounts < migrations.indexOf('"$ROOT/tests/report_to_date.sql"'));
});

test('migration 62 is ASCII, patches only the paid and pending expressions with counted markers, and its SQL test is registered after the invoice amounts one', () => {
  const sql = readFileSync(new URL('../migrations/00000000000062_invoice_paid_follows_money.sql', import.meta.url), 'utf8');
  assert.doesNotMatch(sql, /[^\x09\x0A\x0D\x20-\x7E]/);
  assert.match(sql, /^-- /);
  assert.match(sql, /NOTIFY pgrst, 'reload schema';\n$/);
  assert.doesNotMatch(sql, /authorize_rpc\(|CREATE (OR REPLACE )?FUNCTION (?!pg_temp)/, 'it redefines no function and does not touch the guard');
  assert.ok(!sql.includes('get_all_customer_activity_summary(date,date)\''), 'the all-customers activity summary has no paid or pending figure and is not patched');
  // Every entry: [step, signature, before text, after text, expected count], in order.
  const entries = [...sql.matchAll(/\((\d+), '(public\.[a-z_]+\([a-z,]+\))',\s*\$b\$(.*?)\$b\$,\s*\$a\$(.*?)\$a\$, (\d+)\)/gs)]
    .map(match => [Number(match[1]), match[2], match[3], match[4], Number(match[5])]);
  const summary = 'public.get_customer_invoice_summary(uuid,date,date,integer)';
  const detail = 'public.get_customer_activity_detail(uuid,date,date)';
  assert.deepEqual(entries.map(([step, signature, , , times]) => [step, signature, times]), [
    [1, summary, 1], [2, summary, 1], [3, summary, 1], [4, summary, 1], [5, summary, 1], [6, summary, 1], [7, summary, 1], [8, summary, 1], [9, summary, 1],
    [10, detail, 1], [11, detail, 1], [12, detail, 1],
  ]);
  // The rule is written with the tolerance of get_open_invoices_for_customer, 0.50, and the cap GREATEST(0, LEAST(sum, total)).
  const after = step => entries.find(entry => entry[0] === step)[3];
  assert.match(after(3), /bal\.balance <= 0\.50/);
  assert.match(after(2), /GREATEST\(0, LEAST\(COALESCE\(ps\.paid_sum, 0\), COALESCE\(id\.total, 0\)\)\)/);
  assert.match(after(12), /<= 0\.50 THEN 'paid' ELSE 'pending'/);
  assert.match(after(10), /GREATEST\(0, LEAST\(/);
  // Steps 7 and 8 change nothing: they only fail the migration when the counts no longer read the status.
  for (const step of [7, 8]) assert.equal(entries.find(entry => entry[0] === step)[2], after(step), `step ${step} is a check`);
  // No replacement touches the sums of the total, the day cuts or the payments' total_paid_amount.
  for (const [, , , text] of entries) assert.doesNotMatch(text, /business_day_start|business_date|total_paid_amount|net_amount/);
  const migrations = readFileSync(new URL('../tests/migrations.sh', import.meta.url), 'utf8');
  // Registered once, on the line directly after the invoice amounts test.
  assert.equal(migrations.split('"$ROOT/tests/report_invoice_paid.sql"').length - 1, 1);
  assert.ok(migrations.includes('  "$ROOT/tests/report_invoice_amounts.sql"\n  "$ROOT/tests/report_invoice_paid.sql"\n'));
  assert.ok(migrations.indexOf('"$ROOT/tests/report_invoice_paid.sql"') < migrations.indexOf('"$ROOT/tests/report_to_date.sql"'));
});

// ---------------------------------------------------------------------------
// Paid and Pending follow the money (migration 62), with or without the migration
// ---------------------------------------------------------------------------
// The owner's rule: "Paid is the money received and Pending is what is still owed. An invoice counts as Paid only when nothing
// is owed; a part-paid invoice stays Pending with the balance." Per invoice: received = the sum of its payments, never below 0
// and never above its total; balance = total - received; Paid when the balance is 0.50 or less (get_open_invoices_for_customer's
// tolerance: owed > 0.50 is open), otherwise Pending.
//
//   no    total  tax   payments (sum)            rule: status    received  balance
//   0101    14      1  14.00                      Paid            14.00      0.00   fully paid
//   0102    14      1   4.00                      Pending          4.00     10.00   part paid
//   0103   100      5  none                       Pending          0.00    100.00   unpaid
//   0104    50   2.50  60.00                      Paid            50.00      0.00   over-paid (60 of 50)
//   0105    20      1  19.50                      Paid            19.50      0.50   0.50 owed: within the tolerance
//   0106    20      1  19.49                      Pending         19.49      0.51   0.51 owed: just outside it
//   0107    30      3  status 'paid', no amount   Paid            30.00      0.00   "paid" without an amount: all of it
//   0108 125000  1250  1,00,000.50                Pending    1,00,000.50 24,999.50   Indian grouping in the row
// Together: amount 1,25,248.00 = Paid 1,00,137.49 + Pending 25,110.51.
const moneyCases = [
  // [number, day, total, tax, payment sum or null, rule status, received, balance]
  ['0101', '2026-01-16', 14, 1, 14, 'paid', 14, 0],
  ['0102', '2026-01-18', 14, 1, 4, 'pending', 4, 10],
  ['0103', '2026-01-20', 100, 5, null, 'pending', 0, 100],
  ['0104', '2026-01-22', 50, 2.5, 60, 'paid', 50, 0],
  ['0105', '2026-01-24', 20, 1, 19.5, 'paid', 19.5, 0.5],
  ['0106', '2026-01-26', 20, 1, 19.49, 'pending', 19.49, 0.51],
  ['0107', '2026-01-28', 30, 3, 'no amount', 'paid', 30, 0],
  ['0108', '2026-01-30', 125000, 1250, 100000.5, 'pending', 100000.5, 24999.5],
];
/**
 * The RPC's answer for those invoices. 'without' is a database with migration 61 only: payment_status.status is 'paid' as soon as
 * any payment row names the invoice, and its amount is the sum of the rows. 'with' is a database with migration 62: the status is
 * the rule's, and each invoice has the two new keys paid_amount and balance_amount. The summary is the RPC's own and the PDF must
 * not print it (in 'without' it counts the part-paid invoices as paid).
 */
const moneyAnswer = shape => ({ success: true, data: {
  summary: shape === 'with'
    ? { total_invoices: 8, total_amount: 125248, net_amount: 125248, paid_amount: 100137.49, pending_amount: 25110.51, paid_count: 4, pending_count: 4 }
    : { total_invoices: 8, total_amount: 125248, net_amount: 125248, paid_amount: 125148, pending_amount: 100, paid_count: 7, pending_count: 1 },
  invoices: [...moneyCases].reverse().map(([number, day, total, tax, sum, status, received, balance]) => {
    const rows = sum === null ? null : { paid_date: `${day}T06:00:00+00:00`, payment_ref: `UTR-${number}`, payment_mode: 'ONLINE', ...(sum === 'no amount' ? {} : { amount: sum }) };
    return {
      invoice_number: `2026-${number}`, invoice_date: `${day}T06:00:00+00:00`, grn_ref: `Z${number}`, total, tax_amount: tax, net_total: total,
      payment_status: sum === null ? { status: 'pending', paid_date: null, payment_ref: null }
        : { status: shape === 'with' ? status : 'paid', ...rows },
      ...(shape === 'with' ? { paid_amount: received, balance_amount: balance } : {}),
    };
  }) } });
const moneyShapes = { without: moneyAnswer('without'), with: moneyAnswer('with') };
const numbersOf = built => built.rows.map(row => row[0].slice(5));

test('Paid and Pending follow the money: fully paid, part paid, unpaid, over-paid, the 0.50 tolerance and "paid" without an amount', () => {
  for (const [shape, body] of Object.entries(moneyShapes)) {
    const en = invoiceDocument('en', {}, body).built;
    // Newest first. The status is the rule's, not the answer's: 0102, 0106 and 0108 are paid in part and are Pending in both shapes.
    assert.deepEqual(en.rows, [
      ['2026-0108', '30-01-2026', 'Z0108', '1,25,000.00', '1,250.00', 'Pending (Paid 1,00,000.50)'],
      ['2026-0107', '28-01-2026', 'Z0107', '30.00', '3.00', 'Paid'],
      ['2026-0106', '26-01-2026', 'Z0106', '20.00', '1.00', 'Pending (Paid 19.49)'],
      ['2026-0105', '24-01-2026', 'Z0105', '20.00', '1.00', 'Paid'],
      ['2026-0104', '22-01-2026', 'Z0104', '50.00', '2.50', 'Paid'],
      ['2026-0103', '20-01-2026', 'Z0103', '100.00', '5.00', 'Pending'],
      ['2026-0102', '18-01-2026', 'Z0102', '14.00', '1.00', 'Pending (Paid 4.00)'],
      ['2026-0101', '16-01-2026', 'Z0101', '14.00', '1.00', 'Paid'],
    ], shape);
    assert.deepEqual(en.totals, ['Total', '', '', '1,25,248.00', '1,264.50', ''], shape);
    // Paid = the money received (the over-payment counts 50, not 60), Pending = the balances; together the amount. The RPC's own
    // summary of the 'without' shape (Paid 1,25,148.00, Pending 100.00) is not what is printed.
    assert.deepEqual(en.summary, [['Invoices', '8'], ['Amount', '1,25,248.00'], ['Paid', '1,00,137.49'], ['Pending', '25,110.51']], shape);
    const gu = invoiceDocument('gu', {}, body).built;
    assert.deepEqual(gu.rows.map(row => row[5]), ['બાકી (ચૂકવેલ 1,00,000.50)', 'ચૂકવેલ', 'બાકી (ચૂકવેલ 19.49)', 'ચૂકવેલ', 'ચૂકવેલ', 'બાકી', 'બાકી (ચૂકવેલ 4.00)', 'ચૂકવેલ'], shape);
    assert.deepEqual(gu.summary, [['ઇન્વૉઇસ', '8'], ['રકમ', '1,25,248.00'], ['ચૂકવેલ', '1,00,137.49'], ['બાકી', '25,110.51']], shape);
    assert.deepEqual(gu.totals, ['કુલ', '', '', '1,25,248.00', '1,264.50', ''], shape);
    // The part payment is in the status cell of the printed document, and only there.
    const html = invoiceDocument('en', {}, body).html;
    assert.ok(html.includes('<td>Pending (Paid 4.00)</td>') && html.includes('<td>Pending (Paid 1,00,000.50)</td>') && html.includes('<td>Pending</td>'), shape);
    assert.ok(!html.includes('Paid 14.00') && !html.includes('Paid 50.00') && !html.includes('Paid 19.50') && !html.includes('Paid 30.00') && !html.includes('Paid 0.00'), `${shape}: no part payment on a paid or unpaid invoice`);
  }
  // Paid + Pending is the amount, in the whole document and under each choice (paise are exact).
  for (const lang of ['en', 'gu']) for (const status of [undefined, 'paid', 'pending']) {
    const { summary } = invoiceDocument(lang, { status }, moneyShapes.with).built;
    const [, amount, paid, pending] = summary.map(([, value]) => Math.round(Number(value.replaceAll(',', '')) * 100));
    assert.equal(paid + pending, amount, `${lang} ${status}`);
  }
});

test('the status choice follows the rule: a part-paid invoice is under Pending, an invoice owing 0.50 or less is under Paid', () => {
  for (const [shape, body] of Object.entries(moneyShapes)) {
    const paid = invoiceDocument('en', { status: 'paid' }, body);
    // Paid: 0107, 0105 (0.50 owed), 0104 (over-paid), 0101. Not 0102 (4.00 of 14.00), not 0106 (0.51 owed), not 0108.
    assert.deepEqual(numbersOf(paid.built), ['0107', '0105', '0104', '0101'], shape);
    assert.deepEqual(paid.built.rows.map(row => row[5]), ['Paid', 'Paid', 'Paid', 'Paid'], shape);
    assert.deepEqual(paid.built.totals, ['Total', '', '', '114.00', '7.50', ''], shape);
    // Paid here is the received money (113.50), and what 0105 still owes (0.50) is the Pending of this document.
    assert.deepEqual(paid.built.summary, [['Invoices', '4'], ['Amount', '114.00'], ['Paid', '113.50'], ['Pending', '0.50']], shape);
    assert.equal(paid.built.rowsTotal, 4);
    assert.deepEqual(paid.filters[2], ['Payment', 'Paid']);

    const pending = invoiceDocument('en', { status: 'pending' }, body);
    assert.deepEqual(numbersOf(pending.built), ['0108', '0106', '0103', '0102'], shape);
    assert.deepEqual(pending.built.rows.map(row => row[5]), ['Pending (Paid 1,00,000.50)', 'Pending (Paid 19.49)', 'Pending', 'Pending (Paid 4.00)'], shape);
    assert.deepEqual(pending.built.totals, ['Total', '', '', '1,25,134.00', '1,257.00', ''], shape);
    assert.deepEqual(pending.built.summary, [['Invoices', '4'], ['Amount', '1,25,134.00'], ['Paid', '1,00,023.99'], ['Pending', '25,110.01']], shape);
    assert.deepEqual(pending.filters[2], ['Payment', 'Pending']);
    // The two choices split the eight invoices, and their figures add up to the whole document's.
    assert.equal(numbersOf(paid.built).length + numbersOf(pending.built).length, 8);

    const guPaid = invoiceDocument('gu', { status: 'paid' }, body).built;
    const guPending = invoiceDocument('gu', { status: 'pending' }, body).built;
    assert.deepEqual(guPaid.summary, [['ઇન્વૉઇસ', '4'], ['રકમ', '114.00'], ['ચૂકવેલ', '113.50'], ['બાકી', '0.50']], shape);
    assert.deepEqual(guPending.summary, [['ઇન્વૉઇસ', '4'], ['રકમ', '1,25,134.00'], ['ચૂકવેલ', '1,00,023.99'], ['બાકી', '25,110.01']], shape);
    assert.deepEqual(guPending.rows.map(row => row[5]), ['બાકી (ચૂકવેલ 1,00,000.50)', 'બાકી (ચૂકવેલ 19.49)', 'બાકી', 'બાકી (ચૂકવેલ 4.00)'], shape);
  }
  // A sort by the status column orders by the rule's status (Paid before Pending), not by the answer's.
  const byStatus = invoiceDocument('en', { sort: { field: 'status', order: 'asc' } }, moneyShapes.without).built;
  assert.deepEqual(byStatus.rows.map(row => row[5].split(' ')[0]), ['Paid', 'Paid', 'Paid', 'Paid', 'Pending', 'Pending', 'Pending', 'Pending']);
});

test('the same document is printed from the answer of a database with and without migration 62', () => {
  for (const lang of ['en', 'gu']) {
    for (const fields of [{}, { status: 'paid' }, { status: 'pending' }, { sort: { field: 'amount', order: 'desc' } }, { sort: { field: 'net', order: 'asc' } }]) {
      const before = invoiceDocument(lang, fields, moneyShapes.without);
      const after = invoiceDocument(lang, fields, moneyShapes.with);
      assert.deepEqual(before.built, after.built, `${lang} ${JSON.stringify(fields)}`);
      assert.equal(before.html, after.html, `${lang} ${JSON.stringify(fields)}`);
    }
  }
  // Without migration 62 the answer calls the part-paid invoices paid; the PDF does not follow it.
  assert.equal(moneyShapes.without.data.invoices.filter(invoice => invoice.payment_status.status === 'paid').length, 7);
  assert.equal(moneyShapes.with.data.invoices.filter(invoice => invoice.payment_status.status === 'paid').length, 4);
  // The two new keys are not columns and are never printed.
  assert.ok(!invoiceDocument('en', {}, moneyShapes.with).html.includes('balance_amount'));
  assert.deepEqual(sortFields(invoicesRequest()), ['invoice_no', 'date', 'grn', 'amount', 'tax', 'status', 'net']);
});

test('an amount that cannot be used: a paid invoice has received all of it, a pending one nothing, and money stays between 0 and the total', () => {
  const one = (total, payment_status, fields = {}) => ({ success: true, data: { summary: { total_invoices: 1 }, invoices: [
    { invoice_number: '2026-0900', invoice_date: '2026-01-05', grn_ref: 'Z', total, tax_amount: 0, net_total: total, payment_status }] } });
  const cell = (total, payment_status) => invoiceDocument('en', {}, one(total, payment_status)).built;
  // 'paid' with no amount, null, text or a non-number: the whole total is received. 'pending' with none: nothing.
  for (const amount of [undefined, null, '', 'abc', {}, [], NaN]) {
    assert.deepEqual(cell(14, { status: 'paid', amount }).rows[0].slice(3), ['14.00', '0.00', 'Paid'], `paid, amount ${String(amount)}`);
    assert.deepEqual(cell(14, { status: 'paid', amount }).summary.slice(2), [['Paid', '14.00'], ['Pending', '0.00']]);
    assert.deepEqual(cell(14, { status: 'pending', amount }).rows[0].slice(3), ['14.00', '0.00', 'Pending'], `pending, amount ${String(amount)}`);
    assert.deepEqual(cell(14, { status: 'pending', amount }).summary.slice(2), [['Paid', '0.00'], ['Pending', '14.00']]);
  }
  // A number sent as text is a number (numeric columns may come as text); a payment of 0 is nothing received; a negative sum is 0.
  assert.deepEqual(cell(14, { status: 'paid', amount: '4.00' }).rows[0][5], 'Pending (Paid 4.00)');
  assert.deepEqual(cell(14, { status: 'paid', amount: 0 }).rows[0][5], 'Pending');
  assert.deepEqual(cell(14, { status: 'paid', amount: 0 }).summary.slice(2), [['Paid', '0.00'], ['Pending', '14.00']]);
  assert.deepEqual(cell(14, { status: 'paid', amount: -5 }).summary.slice(2), [['Paid', '0.00'], ['Pending', '14.00']]);
  // Over-paid: received is the total, not the money paid.
  assert.deepEqual(cell(14, { status: 'paid', amount: 1000 }).summary.slice(1), [['Amount', '14.00'], ['Paid', '14.00'], ['Pending', '0.00']]);
  // The tolerance, to the paisa: 0.50 owed is Paid, 0.51 owed is Pending; a total with paise works the same way.
  assert.equal(cell(14, { status: 'paid', amount: 13.5 }).rows[0][5], 'Paid');
  assert.equal(cell(14, { status: 'paid', amount: 13.49 }).rows[0][5], 'Pending (Paid 13.49)');
  assert.equal(cell(0.5, { status: 'pending' }).rows[0][5], 'Paid', 'a total of 0.50 with nothing received owes 0.50: nothing is owed in the sense of the rule');
  assert.equal(cell(0.51, { status: 'pending' }).rows[0][5], 'Pending');
  assert.equal(cell(0, { status: 'pending' }).rows[0][5], 'Paid', 'an invoice of 0 owes nothing');
  assert.equal(cell(20.1, { status: 'paid', amount: 19.6 }).rows[0][5], 'Paid', '0.50 owed whatever the binary form of 20.1 - 19.6 is');
  // An invoice of another status than paid or pending is listed and counted in the amount, but is in neither sum.
  const odd = cell(14, { status: 'void', amount: 14 });
  assert.deepEqual(odd.rows[0].slice(3), ['14.00', '0.00', 'void']);
  assert.deepEqual(odd.summary.slice(1), [['Amount', '14.00'], ['Paid', '0.00'], ['Pending', '0.00']]);
  assert.deepEqual(invoiceDocument('en', {}, one(14, undefined)).built.rows[0].slice(3), ['14.00', '0.00', '']);
});

// ---------------------------------------------------------------------------
// Dates: a moment prints as the day it fell on in India, as the app's screen does
// ---------------------------------------------------------------------------
test('indiaDay keeps a plain day, moves a moment to India time, and gives nothing for anything else', () => {
  const cases = [
    // The edge of the day: 18:29:59 UTC is 23:59:59 in India, 18:30:00 UTC is midnight.
    ['2026-09-30T18:29:59Z', '2026-09-30'], ['2026-09-30T18:30:00Z', '2026-10-01'],
    ['2026-09-30T21:00:00+00:00', '2026-10-01'], ['2026-10-01T01:30:00+05:30', '2026-10-01'],
    // An offset behind UTC, and one that is written with no colon or with the hours only.
    ['2026-09-30T10:00:00-08:00', '2026-09-30'], ['2026-09-30T20:00:00-0800', '2026-10-01'], ['2026-09-30T21:00:00+00', '2026-10-01'],
    // The last day of a year, with no seconds, and with a fraction of a second.
    ['2025-12-31T21:00:00+00:00', '2026-01-01'], ['2025-12-31T21:00Z', '2026-01-01'], ['2026-09-30T21:00:00.123456+00:00', '2026-10-01'],
    // Postgres writes a space for the T and an offset of hours only.
    ['2026-09-30 21:00:00+00', '2026-10-01'], ['2026-09-30 18:29:59+00', '2026-09-30'], ['2026-09-30 21:00:00.5+00', '2026-10-01'],
    // A plain day is already a day.
    ['2026-10-01', '2026-10-01'], ['2026-01-31', '2026-01-31'],
    // Nothing to print: empty, null, not a date, a time that cannot be placed on a calendar (no offset), an impossible day or time.
    ['', ''], [null, ''], [undefined, ''], ['garbage', ''], [20260101, ''], ['2026-09-30T21:00:00', ''], ['2026-09-30 21:00:00', ''],
    ['2026-02-30T10:00:00Z', ''], ['2026-01-01T24:00:00Z', ''], ['2026-01-01T10:00:00+25:00', ''], ['2026-10-01 ', ''], ['01-10-2026', ''],
  ];
  const zone = process.env.TZ;
  try {
    // The result does not depend on the zone the function runs in.
    for (const tz of ['UTC', 'Asia/Kolkata', 'America/Los_Angeles', 'Pacific/Kiritimati']) {
      process.env.TZ = tz;
      for (const [value, expected] of cases) assert.equal(indiaDay(value), expected, `${tz}: ${JSON.stringify(value)}`);
    }
  } finally {
    if (zone === undefined) delete process.env.TZ; else process.env.TZ = zone;
  }
  // The cell is that day written DD-MM-YYYY, and empty when there is no day.
  assert.equal(formatCell('date', '2026-09-30T21:00:00+00:00', 'en'), '01-10-2026');
  assert.equal(formatCell('date', '2026-09-30T18:29:59Z', 'gu'), '30-09-2026');
  assert.equal(formatCell('date', '2026-09-30 21:00:00+00', 'en'), '01-10-2026');
  assert.equal(formatCell('date', '2026-10-01', 'en'), '01-10-2026');
  for (const value of [null, undefined, '', 'garbage', '2026-09-30T21:00:00']) assert.equal(formatCell('date', value, 'en'), '', String(value));
});

test('the date columns of the seven reports are the ones the document tests below cover, and no summary figure is a date', () => {
  const columns = [];
  for (const report of reportNames) {
    for (const level of ['customer', 'all']) {
      const definition = reportDefinitions[report][level];
      for (const column of definition.columns) if (column.kind === 'date' || column.kind === 'month') columns.push(`${report}/${level}/${column.key}:${column.kind}`);
      assert.deepEqual(definition.summary.filter(figure => figure.kind === 'date' || figure.kind === 'month'), [], `${report}/${level} summary`);
    }
  }
  assert.deepEqual(columns, [
    'grn-activity/customer/date:date', 'grn-activity/all/latest:date',
    'dispatch-activity/customer/date:date', 'dispatch-activity/all/latest:date',
    'invoice-history/customer/date:date', 'invoice-history/all/latest:date',
    'stock-summary/customer/date:date',
    'stock-aging/customer/date:date', 'stock-aging/customer/last_dispatch:date',
    'customer-activity/customer/month:month', 'customer-activity/all/last_activity:date',
  ]);
});

/** The document as the handler makes it, from an RPC answer, with the fixed clock. */
function documentOf(report, level, lang, body, extra = {}) {
  const period = periodReports.has(report) ? { from: '2026-01-01', to: '2026-02-28' } : {};
  const req = parseReportRequest({ report, lang, ...period, ...(level === 'customer' ? { customer_id: customer } : {}), ...extra });
  const built = buildReport(req, unwrapReportBody(body));
  const filters = reportFilters(req, level === 'customer' ? 'Amar Traders' : null, built, NOW);
  const html = reportHtml({ title: built.title, company: 'Fictional Cold Storage', lang, filters, summaryTitle: label(lang, 'summary'), summary: built.summary,
    columns: built.columns, rows: built.rows, totals: built.totals, note: '', empty: built.empty });
  return { built, html };
}
// 21:00 UTC is 02:30 the next morning in India: the last evening of a month is the first day of the next one.
const nightOfJanuary = '2026-01-31T21:00:00+00:00';
const nightOfFebruary = '2026-02-28T21:00:00+00:00';

test('a receipt made at 02:30 India time on 1 February prints as 1 February in the GRN activity and the stock aging PDFs, in both languages', () => {
  const grns = { success: true, data: { summary: { total_grns: 2, total_quantity: 20, total_invoiced_grns: 0 }, grns: [
    { gr_no: 'N0002', grn_date: nightOfJanuary, total_items: 1, total_qty: 10, items: [], dispatch_summary: { current_stock: 10 } },
    { gr_no: 'N0001', grn_date: '2026-01-31T18:00:00+00:00', total_items: 1, total_qty: 10, items: [], dispatch_summary: { current_stock: 10 } },
  ] } };
  const aging = { success: true, data: { summary: { total_quantity: 20 }, by_bucket: agingBuckets, items: [
    { item_name: 'Cumin', gr_no: 'N0002', grn_date: nightOfJanuary, rack: 'R1', current_stock: 10, aging_days: 3, dispatch_info: { last_dispatch_date: nightOfFebruary } },
    { item_name: 'Cumin', gr_no: 'N0001', grn_date: '2026-01-31T18:00:00+00:00', rack: 'R2', current_stock: 10, aging_days: 4, dispatch_info: { last_dispatch_date: '2026-02-28T18:29:59+00:00' } },
  ] } };
  for (const lang of ['en', 'gu']) {
    // 18:00 UTC is 23:30 on 31 January in India; 21:00 UTC is 1 February. Newest first by default.
    const grn = documentOf('grn-activity', 'customer', lang, grns);
    assert.deepEqual(grn.built.rows.map(row => [row[0], row[1]]), [['N0002', '01-02-2026'], ['N0001', '31-01-2026']], lang);
    assert.match(grn.html, /<td>N0002<\/td><td>01-02-2026<\/td>/, lang);
    assert.match(grn.html, /<td>N0001<\/td><td>31-01-2026<\/td>/, lang);
    // Both date columns of the aging report: the receipt, and the last dispatch (28 February 21:00 UTC is 1 March).
    const stock = documentOf('stock-aging', 'customer', lang, aging, { sort: { field: 'gr_no', order: 'desc' } });
    assert.deepEqual(stock.built.rows.map(row => [row[1], row[2], row[6]]), [['N0002', '01-02-2026', '01-03-2026'], ['N0001', '31-01-2026', '28-02-2026']], lang);
    assert.match(stock.html, /<td>N0002<\/td><td>01-02-2026<\/td><td>R1<\/td>/, lang);
    assert.match(stock.html, /<td>01-03-2026<\/td>/, lang);
  }
});

test('an invoice made at 02:30 India time on 1 February prints as 1 February in the invoice history, one customer and all customers, in both languages', () => {
  const invoices = { success: true, data: { summary: { total_invoices: 2 }, invoices: [
    { invoice_number: '2026-0002', invoice_date: nightOfJanuary, grn_ref: 'N0002', total: 200, tax_amount: 36, payment_status: { status: 'pending' } },
    { invoice_number: '2026-0001', invoice_date: '2026-01-31T18:00:00+00:00', grn_ref: 'N0001', total: 100, tax_amount: 18, payment_status: { status: 'paid' } },
  ] } };
  const customers = { success: true, data: { summary: { total_invoices: 2, total_customers: 2, total_amount: 300 }, by_customer: [
    { customer_name: 'Amar Traders', invoice_count: 1, total_amount: 200, latest_invoice_date: nightOfJanuary },
    { customer_name: 'Bharat Foods', invoice_count: 1, total_amount: 100, latest_invoice_date: '2026-01-31T18:00:00+00:00' },
  ] } };
  for (const lang of ['en', 'gu']) {
    const one = documentOf('invoice-history', 'customer', lang, invoices);
    assert.deepEqual(one.built.rows.map(row => [row[0], row[1]]), [['2026-0002', '01-02-2026'], ['2026-0001', '31-01-2026']], lang);
    assert.match(one.html, /<td>2026-0002<\/td><td>01-02-2026<\/td>/, lang);
    const all = documentOf('invoice-history', 'all', lang, customers);
    assert.deepEqual(all.built.rows.map(row => [row[0], row[3]]), [['Amar Traders', '01-02-2026'], ['Bharat Foods', '31-01-2026']], lang);
    assert.match(all.html, /<td class="num">200\.00<\/td><td>01-02-2026<\/td>/, lang);
  }
});

test('the last activity of a customer made at 02:30 India time on 1 February prints as 1 February in the all-customers customer activity, in both languages', () => {
  const customers = { success: true, data: { summary: { total_customers: 2 }, customers: [
    { customer_name: 'Amar Traders', customer_city: 'Unjha', current_stock: 20, total_grns: 1, total_dispatches: 0, total_invoice_amount: 0, last_activity_date: nightOfJanuary },
    { customer_name: 'Bharat Foods', customer_city: 'Unjha', current_stock: 10, total_grns: 1, total_dispatches: 0, total_invoice_amount: 0, last_activity_date: '2026-01-31T18:00:00+00:00' },
  ] } };
  for (const lang of ['en', 'gu']) {
    const { built, html } = documentOf('customer-activity', 'all', lang, customers);
    assert.deepEqual(built.rows.map(row => [row[0], row[6]]), [['Amar Traders', '01-02-2026'], ['Bharat Foods', '31-01-2026']], lang);
    assert.match(html, /<td class="num">0\.00<\/td><td>01-02-2026<\/td>/, lang);
  }
});

test('the days the database already gives as plain days print as they are, whatever the hour of a moment would have been', () => {
  // dispatch disp_date and latest_dispatch, the GRN activity's latest_grn, the stock summary's days (migrations 56 and 60) and the
  // activity detail's months are India days or months already: the last day of a month stays that day.
  const dispatch = { summary: { total_dispatches: 1 }, dispatches: [{ disp_no: 'I0001', disp_date: '2026-01-31', total_qty: 1, items: [] }] };
  const dispatchAll = { success: true, summary: {}, by_customer: [{ customer_name: 'Amar Traders', dispatch_count: 1, total_qty: 1, latest_dispatch: '2026-01-31' }] };
  const grnAll = { success: true, summary: {}, by_customer: [{ customer_name: 'Amar Traders', grn_count: 1, total_qty: 1, total_weight: 1, latest_grn: '2026-01-31' }] };
  const stock = { summary: {}, items: [{ item_name: 'Cumin', grns: [{ gr_no: 'N0001', date: '2026-01-31', package_mark: 'AT', rack: 'R1', stock: 1, item_weight: 1 }] }] };
  const months = { success: true, data: { summary: {}, monthly_trends: [{ month: '2026-01' }, { month: '2026-02' }] } };
  for (const lang of ['en', 'gu']) {
    assert.deepEqual(documentOf('dispatch-activity', 'customer', lang, dispatch).built.rows.map(row => row[1]), ['31-01-2026'], lang);
    assert.deepEqual(documentOf('dispatch-activity', 'all', lang, dispatchAll).built.rows.map(row => row[3]), ['31-01-2026'], lang);
    assert.deepEqual(documentOf('grn-activity', 'all', lang, grnAll).built.rows.map(row => row[4]), ['31-01-2026'], lang);
    assert.deepEqual(documentOf('stock-summary', 'customer', lang, stock).built.rows.map(row => row[2]), ['31-01-2026'], lang);
    assert.deepEqual(documentOf('customer-activity', 'customer', lang, months).built.rows.map(row => row[0]), ['01-2026', '02-2026'], lang);
  }
});

test('a sort by a date column orders by the India day that is printed, and by the true moment within a day', () => {
  const grns = dates => ({ success: true, data: { summary: {}, grns: dates.map(([gr_no, grn_date]) => ({ gr_no, grn_date, total_items: 1, total_qty: 1, items: [] })) } });
  const order = (dates, direction) => {
    const { built } = documentOf('grn-activity', 'customer', 'en', grns(dates), { sort: { field: 'date', order: direction } });
    return built.rows.map(row => `${row[0]} ${row[1]}`);
  };
  // 10:00 UTC and 20:00 UTC of 31 January are the same day in UTC but 31 January (15:30) and 1 February (01:30) in India; 05:00 UTC
  // on 1 February is 1 February (10:30) in India too, which is the same India day as the second.
  const dates = [['A', '2026-01-31T20:00:00+00:00'], ['B', '2026-01-31T10:00:00+00:00'], ['C', '2026-02-01T05:00:00+00:00']];
  assert.deepEqual(order(dates, 'asc'), ['B 31-01-2026', 'A 01-02-2026', 'C 01-02-2026']);
  assert.deepEqual(order(dates, 'desc'), ['C 01-02-2026', 'A 01-02-2026', 'B 31-01-2026']);
  // The same two days and the same UTC day, with one moment written in India's offset: 23:30 +05:30 is 18:00 UTC, which is
  // 31 January in India; 19:00 UTC is 1 February. The text "…T23:30…" sorts after "…T19:00…", the day does not.
  const mixed = [['M1', '2026-01-31T19:00:00+00:00'], ['M0', '2026-01-31T23:30:00+05:30']];
  assert.deepEqual(order(mixed, 'asc'), ['M0 31-01-2026', 'M1 01-02-2026']);
  assert.deepEqual(order(mixed, 'desc'), ['M1 01-02-2026', 'M0 31-01-2026']);
  // One India day, two moments written with different offsets: they keep their true order (19:00 UTC, then 22:00 UTC), which
  // is the reverse of their text ("2026-02-01T00:30+05:30" sorts after "2026-01-31T22:00+00:00").
  const sameDay = [['Q', '2026-01-31T22:00:00+00:00'], ['P', '2026-02-01T00:30:00+05:30']];
  assert.deepEqual(order(sameDay, 'asc'), ['P 01-02-2026', 'Q 01-02-2026']);
  assert.deepEqual(order(sameDay, 'desc'), ['Q 01-02-2026', 'P 01-02-2026']);
  // A date that is missing or cannot be read prints empty and comes last in either direction.
  const gaps = [['X', null], ['Y', '2026-01-31T10:00:00+00:00'], ['Z', 'garbage'], ['W', '2026-01-31T20:00:00+00:00']];
  assert.deepEqual(order(gaps, 'asc'), ['Y 31-01-2026', 'W 01-02-2026', 'X ', 'Z ']);
  assert.deepEqual(order(gaps, 'desc'), ['W 01-02-2026', 'Y 31-01-2026', 'X ', 'Z ']);
});

test('the time of the report is India\'s day and clock, so a report made at 02:30 on 1 October says 1 October', () => {
  const built = build('stock-summary', 'all', 'en');
  const stamp = (now, lang = 'en') => reportFilters(request({ lang }), null, built, now).at(-1);
  assert.deepEqual(stamp('2026-09-30T21:00:00.000Z'), ['', 'Last updated 01-10-2026 02:30 IST']);
  assert.deepEqual(stamp('2026-09-30T18:29:59.999Z'), ['', 'Last updated 30-09-2026 23:59 IST']);
  assert.deepEqual(stamp('2026-10-12T08:00:00.000Z'), ['', 'Last updated 12-10-2026 13:30 IST']);
  assert.deepEqual(stamp('2026-12-31T20:00:00.000Z', 'gu'), ['', 'છેલ્લે અપડેટ થયું: 01-01-2027 01:30 IST']);
});
