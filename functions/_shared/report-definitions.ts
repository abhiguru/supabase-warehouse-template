// What each report PDF reads and prints.
//
// Every report reads one existing report RPC with the caller's token, so the
// RPC guard (warehouse_security.authorize_rpc) and the functions' own
// customer checks decide what the caller sees, exactly as on the app's report
// screens (rn-warehouse-template src/services/reporting/*.ts call the same
// RPCs with the same arguments). Nothing here adds SQL. A report has a
// one-customer level (customer_id given) and an all-customers level
// (customer_id absent), which the RPC guard refuses to a customer account.
//
// The columns are the few a person needs on paper, chosen from what the RPC
// returns. Sorting, the row limit and the totals row are applied here, after
// the RPC answered; the summary figures are the RPC's own (they cover every
// row, also when the table is cut at the limit).
import { label, withUnit, type LabelKey, type ReportLang } from './report-labels.ts';
import type { ReportName, ReportRequest } from './report-request.ts';

/** At most this many table rows per PDF; the rest is left out with a note. */
export const maxReportRows = 2000;

type Kind = 'text' | 'date' | 'month' | 'number' | 'money' | 'status';
type Row = Record<string, unknown>;
type Body = Record<string, any>;

interface Column {
  key: string;
  label: LabelKey | readonly [LabelKey, LabelKey];
  kind: Kind;
  /** Summed in the totals row. */
  total?: boolean;
}

interface Figure {
  label: LabelKey | readonly [LabelKey, LabelKey];
  kind: Kind;
  value: (body: Body, rows: Row[]) => unknown;
}

interface Level {
  rpc: (request: ReportRequest) => { name: string; args: Record<string, unknown> };
  rows: (body: Body) => Row[];
  columns: readonly Column[];
  summary: readonly Figure[];
  defaultSort: { field: string; order: 'asc' | 'desc' };
  empty: LabelKey;
}

interface Definition {
  title: LabelKey;
  customer: Level;
  all: Level;
}

const list = (value: unknown): Row[] => Array.isArray(value) ? value.filter(row => row && typeof row === 'object') : [];
const num = (value: unknown): number | null => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) return Number(value);
  return null;
};
const sum = (rows: Row[], key: string) => rows.reduce((total, row) => total + (num(row[key]) ?? 0), 0);
const period = (request: ReportRequest) => ({ p_from_date: request.from, p_to_date: request.to });
const kg = ['weight', 'kg'] as const;

export const reportDefinitions: Record<ReportName, Definition> = {
  'grn-activity': {
    title: 'titleGrnActivity',
    customer: {
      rpc: request => ({ name: 'get_customer_grn_activity', args: { p_customer_uuid: request.customerId, ...period(request) } }),
      // The RPC's own total_weight per GRN adds up per-bag weights; the weight
      // received is each line's bag weight times its bags.
      rows: body => list(body.grns).map(grn => ({
        gr_no: grn.gr_no,
        date: grn.grn_date,
        items: grn.total_items,
        quantity: grn.total_qty,
        weight: list(grn.items).reduce((total, item) => total + (num(item.weight) ?? 0) * (num(item.quantity) ?? 0), 0),
        stock: (grn.dispatch_summary as Row | undefined)?.current_stock,
        invoice: (grn.invoice_status as Row | undefined)?.invoice_number ?? '',
      })),
      columns: [
        { key: 'gr_no', label: 'grnNumber', kind: 'text' },
        { key: 'date', label: 'date', kind: 'date' },
        { key: 'items', label: 'items', kind: 'number', total: true },
        { key: 'quantity', label: 'quantity', kind: 'number', total: true },
        { key: 'weight', label: kg, kind: 'number', total: true },
        { key: 'stock', label: 'stock', kind: 'number', total: true },
        { key: 'invoice', label: 'invoiceNumber', kind: 'text' },
      ],
      summary: [
        { label: 'grns', kind: 'number', value: body => body.summary?.total_grns },
        { label: 'quantity', kind: 'number', value: body => body.summary?.total_quantity },
        { label: kg, kind: 'number', value: (_, rows) => sum(rows, 'weight') },
        { label: 'invoiced', kind: 'number', value: body => body.summary?.total_invoiced_grns },
      ],
      defaultSort: { field: 'date', order: 'desc' },
      empty: 'emptyGrns',
    },
    all: {
      rpc: request => ({ name: 'get_all_grn_activity', args: period(request) }),
      rows: body => list(body.by_customer).map(row => ({
        customer: row.customer_name, grns: row.grn_count, quantity: row.total_qty, weight: row.total_weight, latest: row.latest_grn,
      })),
      columns: [
        { key: 'customer', label: 'customer', kind: 'text' },
        { key: 'grns', label: 'grns', kind: 'number', total: true },
        { key: 'quantity', label: 'quantity', kind: 'number', total: true },
        { key: 'weight', label: kg, kind: 'number', total: true },
        { key: 'latest', label: 'latestGrn', kind: 'date' },
      ],
      summary: [
        { label: 'grns', kind: 'number', value: body => body.summary?.total_grns },
        { label: 'customers', kind: 'number', value: body => body.summary?.total_customers },
        { label: 'quantity', kind: 'number', value: body => body.summary?.total_quantity },
        { label: kg, kind: 'number', value: body => body.summary?.total_weight },
      ],
      defaultSort: { field: 'quantity', order: 'desc' },
      empty: 'emptyGrns',
    },
  },
  'dispatch-activity': {
    title: 'titleDispatchActivity',
    customer: {
      rpc: request => ({ name: 'get_customer_dispatch_activity', args: { p_customer_uuid: request.customerId, ...period(request) } }),
      rows: body => list(body.dispatches).map(dispatch => ({
        disp_no: dispatch.disp_no,
        date: dispatch.disp_date,
        grn: [...new Set(list(dispatch.items).map(item => item.source_grn).filter(value => typeof value === 'string' && value))].join(', '),
        items: list(dispatch.items).length,
        quantity: dispatch.total_qty,
      })),
      columns: [
        { key: 'disp_no', label: 'dispatchNumber', kind: 'text' },
        { key: 'date', label: 'date', kind: 'date' },
        { key: 'grn', label: 'grn', kind: 'text' },
        { key: 'items', label: 'items', kind: 'number', total: true },
        { key: 'quantity', label: 'quantity', kind: 'number', total: true },
      ],
      summary: [
        { label: 'dispatches', kind: 'number', value: body => body.summary?.total_dispatches },
        { label: 'bagsDispatched', kind: 'number', value: body => body.summary?.total_quantity },
        { label: kg, kind: 'number', value: body => body.summary?.total_weight },
      ],
      defaultSort: { field: 'date', order: 'desc' },
      empty: 'emptyDispatches',
    },
    all: {
      rpc: request => ({ name: 'get_all_dispatch_activity', args: period(request) }),
      rows: body => list(body.by_customer).map(row => ({
        customer: row.customer_name, dispatches: row.dispatch_count, quantity: row.total_qty ?? row.total_quantity, latest: row.latest_dispatch,
      })),
      columns: [
        { key: 'customer', label: 'customer', kind: 'text' },
        { key: 'dispatches', label: 'dispatches', kind: 'number', total: true },
        { key: 'quantity', label: 'bagsDispatched', kind: 'number', total: true },
        { key: 'latest', label: 'lastDispatch', kind: 'date' },
      ],
      summary: [
        { label: 'dispatches', kind: 'number', value: body => body.summary?.total_dispatches },
        { label: 'customersWithDispatches', kind: 'number', value: body => body.summary?.total_customers },
        { label: 'bagsDispatched', kind: 'number', value: body => body.summary?.total_quantity },
      ],
      defaultSort: { field: 'quantity', order: 'desc' },
      empty: 'emptyDispatches',
    },
  },
  'invoice-history': {
    title: 'titleInvoiceHistory',
    customer: {
      rpc: request => ({ name: 'get_customer_invoice_summary', args: { p_customer_uuid: request.customerId, ...period(request) } }),
      rows: body => list(body.invoices).map(invoice => ({
        invoice_no: invoice.invoice_number,
        date: invoice.invoice_date,
        grn: invoice.grn_ref,
        amount: invoice.total,
        tax: invoice.tax_amount,
        net: invoice.net_total,
        status: (invoice.payment_status as Row | undefined)?.status,
      })),
      columns: [
        { key: 'invoice_no', label: 'invoiceNumber', kind: 'text' },
        { key: 'date', label: 'date', kind: 'date' },
        { key: 'grn', label: 'grn', kind: 'text' },
        { key: 'amount', label: 'amount', kind: 'money', total: true },
        { key: 'tax', label: 'tax', kind: 'money', total: true },
        { key: 'net', label: 'netAmount', kind: 'money', total: true },
        { key: 'status', label: 'status', kind: 'status' },
      ],
      summary: [
        { label: 'invoices', kind: 'number', value: body => body.summary?.total_invoices },
        { label: 'netAmount', kind: 'money', value: body => body.summary?.net_amount },
        { label: 'paid', kind: 'money', value: body => body.summary?.paid_amount },
        { label: 'pending', kind: 'money', value: body => body.summary?.pending_amount },
      ],
      defaultSort: { field: 'date', order: 'desc' },
      empty: 'emptyInvoices',
    },
    all: {
      // The app asks the same function with no customer for the all-customers view.
      rpc: request => ({ name: 'get_customer_invoice_summary', args: { p_customer_uuid: null, ...period(request) } }),
      rows: body => list(body.by_customer).map(row => ({
        customer: row.customer_name, invoices: row.invoice_count, amount: row.total_amount, net: row.net_amount, latest: row.latest_invoice_date,
      })),
      columns: [
        { key: 'customer', label: 'customer', kind: 'text' },
        { key: 'invoices', label: 'invoices', kind: 'number', total: true },
        { key: 'amount', label: 'amount', kind: 'money', total: true },
        { key: 'net', label: 'netAmount', kind: 'money', total: true },
        { key: 'latest', label: 'latestInvoice', kind: 'date' },
      ],
      summary: [
        { label: 'invoices', kind: 'number', value: body => body.summary?.total_invoices },
        { label: 'customers', kind: 'number', value: body => body.summary?.total_customers },
        { label: 'amount', kind: 'money', value: body => body.summary?.total_amount },
        { label: 'netAmount', kind: 'money', value: body => body.summary?.net_amount },
      ],
      defaultSort: { field: 'amount', order: 'desc' },
      empty: 'emptyInvoices',
    },
  },
  'stock-summary': {
    title: 'titleStockSummary',
    customer: {
      rpc: request => ({ name: 'get_customer_stock_summary', args: { p_customer_uuid: request.customerId } }),
      // One row per GRN line in stock: where the goods are and how much is left.
      rows: body => list(body.items).flatMap(item => list(item.grns).map(grn => ({
        item: item.item_name,
        gr_no: grn.gr_no,
        date: grn.date,
        mark: grn.package_mark,
        rack: grn.rack,
        stock: grn.stock,
        weight: (num(grn.item_weight) ?? 0) * (num(grn.stock) ?? 0),
      }))),
      columns: [
        { key: 'item', label: 'item', kind: 'text' },
        { key: 'gr_no', label: 'grnNumber', kind: 'text' },
        { key: 'date', label: 'date', kind: 'date' },
        { key: 'mark', label: 'packageMark', kind: 'text' },
        { key: 'rack', label: 'rack', kind: 'text' },
        { key: 'stock', label: 'stock', kind: 'number', total: true },
        { key: 'weight', label: kg, kind: 'number', total: true },
      ],
      summary: [
        { label: 'itemsInStorage', kind: 'number', value: body => body.summary?.total_items },
        { label: 'unitsInStock', kind: 'number', value: body => body.summary?.total_quantity },
        { label: kg, kind: 'number', value: body => body.summary?.total_weight_kg },
        { label: 'grnsWithStock', kind: 'number', value: body => body.summary?.grn_count },
      ],
      defaultSort: { field: 'item', order: 'asc' },
      empty: 'emptyCustomerStock',
    },
    all: {
      rpc: () => ({ name: 'get_all_stock_summary', args: {} }),
      rows: body => list(body.customers).map(row => ({
        customer: row.customer_name, items: row.item_count, grns: row.grn_count, stock: row.total_stock, weight: row.total_weight,
      })),
      columns: [
        { key: 'customer', label: 'customer', kind: 'text' },
        { key: 'items', label: 'items', kind: 'number' },
        { key: 'grns', label: 'grns', kind: 'number', total: true },
        { key: 'stock', label: 'stock', kind: 'number', total: true },
        { key: 'weight', label: kg, kind: 'number', total: true },
      ],
      summary: [
        { label: 'customersWithStock', kind: 'number', value: body => body.summary?.total_customers_with_stock },
        { label: 'itemsInStorage', kind: 'number', value: body => body.summary?.total_items },
        { label: 'unitsInStock', kind: 'number', value: body => body.summary?.total_quantity },
        { label: kg, kind: 'number', value: body => body.summary?.total_weight_kg },
      ],
      defaultSort: { field: 'stock', order: 'desc' },
      empty: 'emptyStock',
    },
  },
  'stock-aging': {
    title: 'titleStockAging',
    customer: {
      rpc: request => ({ name: 'get_stock_aging_report', args: { p_customer_uuid: request.customerId } }),
      rows: body => list(body.items).map(item => ({
        item: item.item_name,
        gr_no: item.gr_no,
        date: item.grn_date,
        rack: item.rack,
        stock: item.current_stock,
        age: item.aging_days,
        last_dispatch: (item.dispatch_info as Row | undefined)?.last_dispatch_date,
      })),
      columns: [
        { key: 'item', label: 'item', kind: 'text' },
        { key: 'gr_no', label: 'grnNumber', kind: 'text' },
        { key: 'date', label: 'date', kind: 'date' },
        { key: 'rack', label: 'rack', kind: 'text' },
        { key: 'stock', label: 'stock', kind: 'number', total: true },
        { key: 'age', label: ['stockAge', 'daysUnit'], kind: 'number' },
        { key: 'last_dispatch', label: 'lastDispatch', kind: 'date' },
      ],
      summary: [
        { label: 'unitsInStock', kind: 'number', value: body => body.summary?.total_quantity },
        { label: ['averageAge', 'daysUnit'], kind: 'number', value: body => body.summary?.average_age_days },
        { label: 'overOneYear', kind: 'number', value: body => body.summary?.qty_over_365_days },
      ],
      defaultSort: { field: 'age', order: 'desc' },
      empty: 'emptyCustomerStock',
    },
    all: {
      rpc: () => ({ name: 'get_stock_aging_report', args: { p_customer_uuid: null } }),
      rows: body => list(body.by_customer).map(row => ({
        customer: row.customer_name, stock: row.total_stock, average_age: row.average_age_days, over_one_year: row.items_over_365_days,
      })),
      columns: [
        { key: 'customer', label: 'customer', kind: 'text' },
        { key: 'stock', label: 'stock', kind: 'number', total: true },
        { key: 'average_age', label: ['averageAge', 'daysUnit'], kind: 'number' },
        { key: 'over_one_year', label: 'overOneYear', kind: 'number', total: true },
      ],
      summary: [
        { label: 'customers', kind: 'number', value: body => body.summary?.total_customers },
        { label: 'unitsInStock', kind: 'number', value: body => body.summary?.total_quantity },
        { label: ['averageAge', 'daysUnit'], kind: 'number', value: body => body.summary?.average_age_days },
        { label: 'overOneYear', kind: 'number', value: body => body.summary?.qty_over_365_days },
      ],
      defaultSort: { field: 'stock', order: 'desc' },
      empty: 'emptyStock',
    },
  },
  'item-stock-summary': {
    title: 'titleItemStockSummary',
    customer: {
      rpc: request => itemCall(request, request.customerId),
      rows: body => itemRows(body),
      columns: itemColumns(),
      summary: itemSummary(),
      defaultSort: { field: 'item', order: 'asc' },
      empty: 'emptyCustomerStock',
    },
    all: {
      rpc: request => itemCall(request, null),
      rows: body => itemRows(body),
      columns: itemColumns(),
      summary: itemSummary(),
      defaultSort: { field: 'item', order: 'asc' },
      empty: 'emptyStock',
    },
  },
  'customer-activity': {
    title: 'titleCustomerActivity',
    customer: {
      rpc: request => ({ name: 'get_customer_activity_detail', args: { p_customer_uuid: request.customerId, ...period(request) } }),
      // The customer's month-by-month movement over the period.
      rows: body => list(body.monthly_trends).map(month => ({
        month: month.month,
        grns: month.grn_count,
        received: month.grn_quantity,
        dispatches: month.dispatch_count,
        dispatched: month.dispatch_quantity,
        amount: month.invoice_amount,
        stock_end: month.stock_level_end,
      })),
      columns: [
        { key: 'month', label: 'month', kind: 'month' },
        { key: 'grns', label: 'grns', kind: 'number', total: true },
        { key: 'received', label: 'receivedQuantity', kind: 'number', total: true },
        { key: 'dispatches', label: 'dispatches', kind: 'number', total: true },
        { key: 'dispatched', label: 'bagsDispatched', kind: 'number', total: true },
        { key: 'amount', label: 'amount', kind: 'money', total: true },
        { key: 'stock_end', label: 'stockAtMonthEnd', kind: 'number' },
      ],
      summary: [
        { label: 'totalStock', kind: 'number', value: body => body.summary?.current_stock },
        { label: 'grns', kind: 'number', value: body => body.summary?.total_grns },
        { label: 'dispatches', kind: 'number', value: body => body.summary?.total_dispatches },
        { label: 'amount', kind: 'money', value: body => body.summary?.total_invoice_amount },
        { label: 'paid', kind: 'money', value: body => body.summary?.total_paid_amount },
        { label: 'pending', kind: 'money', value: body => body.summary?.total_pending_amount },
      ],
      defaultSort: { field: 'month', order: 'asc' },
      empty: 'emptyActivity',
    },
    all: {
      rpc: request => ({ name: 'get_all_customer_activity_summary', args: period(request) }),
      rows: body => list(body.customers).map(row => ({
        customer: row.customer_name,
        city: row.customer_city,
        stock: row.current_stock,
        grns: row.total_grns,
        dispatches: row.total_dispatches,
        amount: row.total_invoice_amount,
        last_activity: row.last_activity_date,
      })),
      columns: [
        { key: 'customer', label: 'customer', kind: 'text' },
        { key: 'city', label: 'city', kind: 'text' },
        { key: 'stock', label: 'stock', kind: 'number', total: true },
        { key: 'grns', label: 'grns', kind: 'number', total: true },
        { key: 'dispatches', label: 'dispatches', kind: 'number', total: true },
        { key: 'amount', label: 'amount', kind: 'money', total: true },
        { key: 'last_activity', label: 'lastActivity', kind: 'date' },
      ],
      summary: [
        { label: 'customers', kind: 'number', value: body => body.summary?.total_customers },
        { label: 'totalStock', kind: 'number', value: body => body.summary?.total_current_stock },
        { label: 'grns', kind: 'number', value: body => body.summary?.total_grns },
        { label: 'dispatches', kind: 'number', value: body => body.summary?.total_dispatches },
        { label: 'amount', kind: 'money', value: body => body.summary?.total_invoice_amount },
      ],
      defaultSort: { field: 'stock', order: 'desc' },
      empty: 'emptyActivity',
    },
  },
};

// The list is paged and sorted by the server (migration 52), so a list longer
// than the limit is cut after the rows that come first in the chosen order.
// One row past the limit shows whether it was cut. Packaging is not a server
// sort; the server then keeps its item-name order.
const itemServerSort: Record<string, string> = { item: 'item_name', stock: 'total_stock', received: 'total_qty', grns: 'grn_count' };
function itemCall(request: ReportRequest, customerId: string | null) {
  const field = request.sort?.field ?? 'item';
  // Own keys only: a field such as "constructor" names nothing here.
  const server = Object.hasOwn(itemServerSort, field) ? itemServerSort[field] : undefined;
  return {
    name: 'get_item_wise_stock_list',
    args: {
      p_customer_id: customerId, p_search_query: null, p_limit: maxReportRows + 1, p_offset: 0,
      p_sort_by: server ?? 'item_name', p_sort_order: server ? request.sort?.order ?? 'asc' : 'asc',
    },
  };
}
function itemRows(body: Body): Row[] {
  return list(body.items).map(item => ({
    item: item.item_name, packaging: item.packaging, grns: item.grn_count, received: item.total_qty, stock: item.total_stock,
  }));
}
function itemColumns(): Column[] {
  return [
    { key: 'item', label: 'item', kind: 'text' },
    { key: 'packaging', label: 'packaging', kind: 'text' },
    { key: 'grns', label: 'grns', kind: 'number', total: true },
    { key: 'received', label: 'receivedQuantity', kind: 'number', total: true },
    { key: 'stock', label: 'stock', kind: 'number', total: true },
  ];
}
// Migration 52 gives get_item_wise_stock_list a summary of the whole list;
// without one (an older database) the figures add up the rows read.
function itemSummary(): Figure[] {
  return [
    { label: 'items', kind: 'number', value: (body, rows) => body.total_count ?? rows.length },
    { label: 'unitsInStock', kind: 'number', value: (body, rows) => body.summary?.total_stock ?? sum(rows, 'stock') },
    { label: 'receivedQuantity', kind: 'number', value: (body, rows) => body.summary?.total_qty ?? sum(rows, 'received') },
  ];
}

/** The level a request reads. */
export function reportLevel(request: ReportRequest): Level {
  const definition = reportDefinitions[request.report];
  return request.customerId ? definition.customer : definition.all;
}

/** The fields a request may sort the report by (every column of its level). */
export function sortFields(request: ReportRequest): string[] {
  return reportLevel(request).columns.map(column => column.key);
}

/** The RPC answer itself: the first row of an array, and the `data` of a {success, data} envelope. */
export function unwrapReportBody(data: unknown): Body | null {
  const body = Array.isArray(data) ? data[0] : data;
  if (!body || typeof body !== 'object') return null;
  const inner = (body as Body).data;
  if ('success' in body && inner && typeof inner === 'object' && !Array.isArray(inner)) return inner as Body;
  return body as Body;
}

const accessWords = /access denied|permission|staff access required|role required|administrator required|active account required|authentication required/i;

/**
 * The HTTP answer for an RPC that refused in its body, or null for a report.
 * The report functions answer a refusal as data: {success:false, error,
 * error_code} or, in older ones, {error, summary:null} without `success`. The
 * same test as the app's src/utils/rpcRefusal.ts.
 */
export function reportRefusal(data: unknown): { status: number; message: string } | null {
  const body = Array.isArray(data) ? data[0] : data;
  if (!body || typeof body !== 'object') return null;
  const value = body as Body;
  const text = (item: unknown) => typeof item === 'string' && item.trim() !== '' ? item : undefined;
  const refused = value.success === false || (value.success !== true && text(value.error) !== undefined);
  if (!refused) return null;
  const message = text(value.error) ?? text(value.message) ?? '';
  const code = text(value.error_code) ?? text(value.code);
  if (code === '42501' || accessWords.test(message)) return { status: 403, message: 'Report not available to this account' };
  if (/not found/i.test(message)) return { status: 404, message: 'Customer unavailable' };
  return { status: 503, message: 'Report data unavailable' };
}

const indian = (min: number, max: number) => new Intl.NumberFormat('en-IN', { minimumFractionDigits: min, maximumFractionDigits: max });
const plain = indian(0, 2);
const money = indian(2, 2);

/** A cell as printed. Numbers use Indian digit grouping, dates DD-MM-YYYY. */
export function formatCell(kind: Kind, value: unknown, lang: ReportLang): string {
  if (value === null || value === undefined || value === '') return '';
  if (kind === 'number' || kind === 'money') {
    const number = num(value);
    return number === null ? '' : (kind === 'money' ? money : plain).format(number);
  }
  const text = String(value);
  if (kind === 'date') {
    const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(text);
    return match ? `${match[3]}-${match[2]}-${match[1]}` : text;
  }
  if (kind === 'month') {
    const match = /^(\d{4})-(\d{2})/.exec(text);
    return match ? `${match[2]}-${match[1]}` : text;
  }
  if (kind === 'status') {
    if (text === 'paid') return label(lang, 'paid');
    if (text === 'pending') return label(lang, 'pending');
  }
  return text;
}

const columnLabel = (lang: ReportLang, value: Column['label']) =>
  typeof value === 'string' ? label(lang, value) : withUnit(lang, value[0], value[1]);

const missingValue = (kind: Kind, value: unknown) => value === null || value === undefined || value === '' ||
  ((kind === 'number' || kind === 'money') && num(value) === null);

function compare(kind: Kind, left: unknown, right: unknown): number {
  if (kind === 'number' || kind === 'money') return num(left)! - num(right)!;
  if (kind === 'date' || kind === 'month') return String(left) < String(right) ? -1 : String(left) > String(right) ? 1 : 0;
  return String(left).localeCompare(String(right), 'en', { numeric: true, sensitivity: 'base' });
}

export interface BuiltReport {
  title: string;
  columns: { label: string; numeric: boolean }[];
  rows: string[][];
  totals: string[] | null;
  summary: [string, string][];
  sort: { field: string; order: 'asc' | 'desc'; label: string };
  rowsTotal: number;
  truncated: boolean;
  empty: string;
}

/** The printed report: columns, sorted and capped rows, totals and summary, in the request's language. */
export function buildReport(request: ReportRequest, body: Body): BuiltReport {
  const level = reportLevel(request);
  const lang = request.lang;
  const all = level.rows(body);
  const wanted = request.sort && level.columns.some(column => column.key === request.sort!.field) ? request.sort : level.defaultSort;
  const column = level.columns.find(item => item.key === wanted.field)!;
  const direction = wanted.order === 'desc' ? -1 : 1;
  // Array.prototype.sort is stable: equal rows keep the order the RPC gave. A
  // row without the value comes last in either direction.
  const sorted = [...all].sort((left, right) => {
    const a = missingValue(column.kind, left[column.key]); const b = missingValue(column.kind, right[column.key]);
    if (a || b) return a === b ? 0 : a ? 1 : -1;
    return direction * compare(column.kind, left[column.key], right[column.key]);
  });
  // The item list is read one row past the limit, so its own count is the better total.
  const rowsTotal = request.report === 'item-stock-summary' ? Math.max(num(body.total_count) ?? 0, sorted.length) : sorted.length;
  const shown = sorted.slice(0, maxReportRows);
  const hasTotals = level.columns.some(item => item.total);
  const totals = hasTotals && shown.length > 0
    ? level.columns.map((item, index) => item.total
      ? formatCell(item.kind, shown.reduce((total, row) => total + (num(row[item.key]) ?? 0), 0), lang)
      : index === 0 ? label(lang, 'total') : '')
    : null;
  return {
    title: label(lang, reportDefinitions[request.report].title),
    columns: level.columns.map(item => ({ label: columnLabel(lang, item.label), numeric: item.kind === 'number' || item.kind === 'money' })),
    rows: shown.map(row => level.columns.map(item => formatCell(item.kind, row[item.key], lang))),
    totals,
    summary: level.summary.map(figure => [columnLabel(lang, figure.label), formatCell(figure.kind, figure.value(body, all) ?? 0, lang)]),
    sort: {
      field: wanted.field,
      order: wanted.order,
      label: `${columnLabel(lang, column.label)} (${label(lang, wanted.order === 'asc' ? 'ascending' : 'descending')})`,
    },
    rowsTotal,
    truncated: rowsTotal > shown.length,
    empty: label(lang, level.empty),
  };
}
