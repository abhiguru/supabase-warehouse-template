import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseReportRequest, reportNames, periodReports, dayNumber } from '../functions/_shared/report-request.ts';
import { buildReport, reportDefinitions, reportLevel, reportRefusal, sortFields, unwrapReportBody, formatCell, maxReportRows }
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
  assert.deepEqual(request(), { report: 'stock-summary', customerId: null, from: null, to: null, sort: null, lang: 'en' });
  assert.deepEqual(parseReportRequest({ report: 'grn-activity', customer_id: customer.toUpperCase(), from: '2026-01-01', to: '2026-03-31',
    sort: { field: 'quantity', order: 'asc' }, lang: 'gu' }), {
    report: 'grn-activity', customerId: customer, from: '2026-01-01', to: '2026-03-31', sort: { field: 'quantity', order: 'asc' }, lang: 'gu',
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
    customer: { success: true, data: { summary: { total_invoices: 1, net_amount: 1180, paid_amount: 0, pending_amount: 1180 }, invoices: [
      { invoice_number: '2026-7', invoice_date: '2026-01-31', grn_ref: 'Z0010', total: 1000, tax_amount: 180, net_total: 1180, payment_status: { status: 'pending' } },
    ] } },
    all: { success: true, data: { summary: { total_invoices: 1, total_customers: 1, total_amount: 1000, net_amount: 1180 }, by_customer: [
      { customer_name: 'Amar Traders', invoice_count: 1, total_amount: 1000, net_amount: 1180, latest_invoice_date: '2026-01-31' },
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
    customer: { success: true, data: { summary: { total_quantity: 90, average_age_days: 15, qty_over_365_days: 0 }, items: [
      { item_name: 'Cumin', gr_no: 'Z0010', grn_date: '2026-01-05', rack: 'R2', current_stock: 40, aging_days: 26, dispatch_info: { last_dispatch_date: '2026-01-12' } },
      { item_name: 'Cumin', gr_no: 'Z0002', grn_date: '2026-01-20', rack: 'R1', current_stock: 50, aging_days: 11, dispatch_info: { last_dispatch_date: null } },
    ] } },
    all: { success: true, data: { summary: { total_customers: 1, total_quantity: 90, average_age_days: 15, qty_over_365_days: 0 }, by_customer: [
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
      ['આવક પાવતી નંબર', 'તારીખ', 'આઇટમ', 'નંગ', 'વજન (કિલો)', 'સ્ટોક', 'ઇન્વૉઇસ નંબર']],
    all: [['Customer', 'GRNs', 'Quantity', 'Weight (kg)', 'Latest GRN'], ['વેપારી', 'આવક પાવતી', 'નંગ', 'વજન (કિલો)', 'છેલ્લી આવક પાવતી']],
  },
  'dispatch-activity': {
    customer: [['Dispatch number', 'Date', 'GRN', 'Items', 'Quantity'], ['જાવક નંબર', 'તારીખ', 'આવક પાવતી', 'આઇટમ', 'નંગ']],
    all: [['Customer', 'Dispatches', 'Bags dispatched', 'Last dispatch'], ['વેપારી', 'જાવક', 'જાવકના નંગ', 'છેલ્લી જાવક']],
  },
  'invoice-history': {
    customer: [['Invoice number', 'Date', 'GRN', 'Amount', 'Tax', 'Net amount', 'Status'],
      ['ઇન્વૉઇસ નંબર', 'તારીખ', 'આવક પાવતી', 'રકમ', 'Tax', 'ચોખ્ખી રકમ', 'Status']],
    all: [['Customer', 'Invoices', 'Amount', 'Net amount', 'Latest invoice'], ['વેપારી', 'ઇન્વૉઇસ', 'રકમ', 'ચોખ્ખી રકમ', 'Latest invoice']],
  },
  'stock-summary': {
    customer: [['Item', 'GRN number', 'Date', 'Package mark', 'Rack', 'Stock', 'Weight (kg)'],
      ['આઇટમ', 'આવક પાવતી નંબર', 'તારીખ', 'માર્કો', 'રેક', 'સ્ટોક', 'વજન (કિલો)']],
    all: [['Customer', 'Items', 'GRNs', 'Stock', 'Weight (kg)'], ['વેપારી', 'આઇટમ', 'આવક પાવતી', 'સ્ટોક', 'વજન (કિલો)']],
  },
  'stock-aging': {
    customer: [['Item', 'GRN number', 'Date', 'Rack', 'Stock', 'Stock age (days)', 'Last dispatch'],
      ['આઇટમ', 'આવક પાવતી નંબર', 'તારીખ', 'રેક', 'સ્ટોક', 'માલ કેટલા દિવસથી પડ્યો છે (દિવસ)', 'છેલ્લી જાવક']],
    all: [['Customer', 'Stock', 'Average age (days)', 'Over 1 year'], ['વેપારી', 'સ્ટોક', 'સરેરાશ કેટલા દિવસથી (દિવસ)', '૧ વર્ષથી વધુ']],
  },
  'item-stock-summary': {
    customer: [['Item', 'Packaging', 'GRNs', 'Received quantity', 'Stock'], ['આઇટમ', 'પેકિંગ', 'આવક પાવતી', 'આવકના નંગ', 'સ્ટોક']],
    all: [['Item', 'Packaging', 'GRNs', 'Received quantity', 'Stock'], ['આઇટમ', 'પેકિંગ', 'આવક પાવતી', 'આવકના નંગ', 'સ્ટોક']],
  },
  'customer-activity': {
    customer: [['Month', 'GRNs', 'Received quantity', 'Dispatches', 'Bags dispatched', 'Amount', 'Stock at month end'],
      ['મહિનો', 'આવક પાવતી', 'આવકના નંગ', 'જાવક', 'જાવકના નંગ', 'રકમ', 'મહિનાના અંતે સ્ટોક']],
    all: [['Customer', 'City', 'Stock', 'GRNs', 'Dispatches', 'Amount', 'Last activity'], ['વેપારી', 'City', 'સ્ટોક', 'આવક પાવતી', 'જાવક', 'રકમ', 'Last activity']],
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
  assert.deepEqual([...missingGujarati], ['Sort by', 'ascending', 'descending', 'Latest invoice', 'Tax', 'Status', 'City', 'Last activity']);
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
  assert.equal(label('gu', 'showing', { shown: '2,000', total: '2,500' }), '2,500માંથી 2,000 બતાવ્યા છે');
  assert.equal(label('en', 'updated', { time: 'now' }), 'Last updated now');
  // Gujarati copied from the app is spot-checked against the app's English for the same key.
  assert.equal(label('gu', 'customer'), 'વેપારી');
  assert.equal(label('gu', 'quantity'), 'નંગ');
  assert.equal(label('gu', 'allCustomers'), 'બધા વેપારી');
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
  assert.deepEqual(invoices.rows, [['2026-7', '31-01-2026', 'Z0010', '1,000.00', '180.00', '1,180.00', 'બાકી']]);
  assert.deepEqual(invoices.totals, ['કુલ', '', '', '1,000.00', '180.00', '1,180.00', '']);
  assert.deepEqual(invoices.summary, [['ઇન્વૉઇસ', '1'], ['ચોખ્ખી રકમ', '1,180.00'], ['ચૂકવેલ', '0.00'], ['બાકી', '1,180.00']]);

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
    ['customer', 'invoices', 'amount', 'net', 'latest']);
  assert.equal(build('stock-aging', 'customer', 'gu', { sort: { field: 'stock', order: 'asc' } }).sort.label, 'સ્ટોક (ascending)');
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
