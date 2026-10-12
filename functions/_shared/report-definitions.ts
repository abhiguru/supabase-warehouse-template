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
// row, also when the table is cut at the limit). The one exception is the
// invoice history of one customer: its amount, paid and pending figures are
// added up here from the invoices listed (their total and the payment amount of
// their payment status), and with a Paid / Pending choice (`status`) the invoices
// of the other status are dropped first, so every figure of the PDF, the summary
// included, is worked out from the invoices listed. An invoice's amount is its
// total; the RPC's net_total and net_amount (total + labour + tax - discount
// until migration 61, when they became the total) are not printed from it.
// Paid and Pending follow the money (the owner's rule, migration 62): see
// `invoiceMoney`.
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
  /** The printed cell, when it is more than the value of the row's `key` formatted by its `kind`. */
  cell?: (row: Row, lang: ReportLang) => string;
}

interface Figure {
  label: LabelKey | readonly [LabelKey, LabelKey];
  kind: Kind;
  /** `rows` are all the rows of the report (before the row limit), after any choice such as `status`. */
  value: (body: Body, rows: Row[], request: ReportRequest) => unknown;
}

interface Level {
  rpc: (request: ReportRequest) => { name: string; args: Record<string, unknown> };
  rows: (body: Body, request: ReportRequest) => Row[];
  columns: readonly Column[];
  summary: readonly Figure[];
  defaultSort: { field: string; order: 'asc' | 'desc' };
  /** A sort field the app may still send that names no column of this level: the column key it sorts by instead. */
  sortAliases?: Readonly<Record<string, string>>;
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
/** A sum of rupee amounts, added in whole paise so that two decimals stay exact. */
const sumMoney = (rows: Row[], key: string) => rows.reduce((total, row) => total + Math.round((num(row[key]) ?? 0) * 100), 0) / 100;
/** The unit of a rupee amount, one paisa: money is compared in whole paise so that two decimals stay exact. */
const paise = (value: number) => Math.round(value * 100);
/** An invoice is paid when no more than this is still owed (0.50, as get_open_invoices_for_customer: owed > 0.50 is open). */
const paidWithinPaise = 50;
/**
 * Paid and Pending follow the money (the owner's rule of 2026-10-12, migration 62): "Paid is the money received and
 * Pending is what is still owed. An invoice counts as Paid only when nothing is owed; a part-paid invoice stays
 * Pending with the balance."
 *   received = the sum of the invoice's payments (payment_status.amount since migration 61), never below 0 and never
 *              above the invoice's total;
 *   balance  = total - received;
 *   status   = 'paid' when the balance is 0.50 or less, otherwise 'pending'.
 * The answer's own status is not the rule on a database without migration 62 (it is 'paid' as soon as any payment row
 * names the invoice), so it is only read to tell the two statuses from anything else, and to decide what a missing
 * amount means: 'paid' with no usable amount (a database from before migration 61 answers the one row's amount; any
 * answer may leave it out) has received the whole total, 'pending' with none has received nothing. With the amount, the
 * answer of a database with migration 62 and of one without it give the same status, received and balance.
 * An invoice whose status is neither is not worked out: no received and no balance, so it is in neither sum.
 */
function invoiceMoney(invoice: Row): { status: unknown; received?: number; balance?: number } {
  const payment = invoice.payment_status as Row | undefined;
  const status = payment?.status;
  if (status !== 'paid' && status !== 'pending') return { status };
  const total = paise(num(invoice.total) ?? 0);
  const amount = num(payment?.amount);
  const money = amount === null ? (status === 'paid' ? total : 0) : paise(amount);
  const received = Math.max(0, Math.min(money, total));
  const balance = total - received;
  return { status: balance <= paidWithinPaise ? 'paid' : 'pending', received: received / 100, balance: balance / 100 };
}
const period = (request: ReportRequest) => ({ p_from_date: request.from, p_to_date: request.to });
const kg = ['weight', 'kg'] as const;
/**
 * The oldest stock of the stock aging report, as the app's screen shows it (app/reports/stock-aging.tsx, "Items over 364
 * days"): the item count of the over-364-days bucket of the RPC's answer, by_bucket['364+'].item_count, which is also what
 * the red bar of the screen shows. The report is asked with the default buckets (120, 240, 364), so the oldest is '364+'.
 * It is not summary.qty_over_365_days (bags, counted from 365 days), and a missing bucket is 0 as on the screen.
 */
const itemsOver364 = (body: Body) => body.by_bucket?.['364+']?.item_count;

export const reportDefinitions: Record<ReportName, Definition> = {
  'grn-activity': {
    title: 'titleGrnActivity',
    customer: {
      rpc: request => ({ name: 'get_customer_grn_activity', args: { p_customer_uuid: request.customerId, ...period(request) } }),
      // Until migration 59 the RPC's own total_weight per GRN added up per-bag
      // weights without the bags. The weight received is computed here from each
      // line (its bag weight times its bags), which is right with or without that
      // migration.
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
      // The weight is the RPC's own: get_all_grn_activity has always added up bags
      // times bag weight (kg of the received lines, summary.total_weight and
      // by_customer[].total_weight), and migration 59 makes get_customer_grn_activity
      // agree with it and checks this is still so.
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
      // With a Paid / Pending choice only the invoices of that status are listed, the status being the one of
      // the rule of `invoiceMoney` (a part-paid invoice is Pending). An invoice's amount is its total (the amount
      // that is paid or owed); the RPC's net_total was total + labour + tax - discount, which counts the labour,
      // the tax and the discount twice, until migration 61 made it the total. The PDF therefore prints no net
      // column, and its summary is worked out below from the totals and the payments it lists, so it is right on
      // a database with or without migrations 61 and 62.
      rows: (body, request) => list(body.invoices).map(invoice => ({
        invoice_no: invoice.invoice_number,
        date: invoice.invoice_date,
        grn: invoice.grn_ref,
        amount: invoice.total,
        tax: invoice.tax_amount,
        ...invoiceMoney(invoice),
      })).filter(row => !request.status || row.status === request.status),
      columns: [
        { key: 'invoice_no', label: 'invoiceNumber', kind: 'text' },
        { key: 'date', label: 'date', kind: 'date' },
        { key: 'grn', label: 'grn', kind: 'text' },
        { key: 'amount', label: 'amount', kind: 'money', total: true },
        { key: 'tax', label: 'tax', kind: 'money', total: true },
        // A part payment shows in the row: "Pending (Paid 4.00)" / "બાકી (ચૂકવેલ 4.00)", the status and the money
        // received, in the app's own words for Pending and Paid. A Pending invoice with nothing received, and a
        // Paid one, print the status alone.
        { key: 'status', label: 'status', kind: 'status',
          cell: (row, lang) => {
            const status = formatCell('status', row.status, lang);
            const received = num(row.received) ?? 0;
            return row.status === 'pending' && received > 0 ? `${status} (${label(lang, 'paid')} ${formatCell('money', received, lang)})` : status;
          } },
      ],
      summary: [
        // The count is the RPC's own without a choice. The amount, paid and pending are always added up from the
        // listed invoices: the amount of every one, Paid the money received on them and Pending the balances still
        // owed, so Paid + Pending = Amount (an invoice of another status than paid or pending is in neither).
        { label: 'invoices', kind: 'number', value: (body, rows, request) => request.status ? rows.length : body.summary?.total_invoices },
        { label: 'amount', kind: 'money', value: (_, rows) => sumMoney(rows, 'amount') },
        { label: 'paid', kind: 'money', value: (_, rows) => sumMoney(rows, 'received') },
        { label: 'pending', kind: 'money', value: (_, rows) => sumMoney(rows, 'balance') },
      ],
      defaultSort: { field: 'date', order: 'desc' },
      // The app's amount sort of one customer's invoices is the 'net' column it used to have (reportPdfSort.ts: total -> net);
      // it is still accepted and sorts by the amount.
      sortAliases: { net: 'amount' },
      empty: 'emptyInvoices',
    },
    all: {
      // The app asks the same function with no customer for the all-customers view.
      rpc: request => ({ name: 'get_customer_invoice_summary', args: { p_customer_uuid: null, ...period(request) } }),
      // total_amount is the sum of the invoices' totals on every database, and it is the only amount printed. net_amount
      // was the sum of total + labour + tax - discount (the labour, the tax and the discount counted twice) until
      // migration 61 made it total_amount, so the PDF prints no net column or figure, which would repeat the amount.
      rows: body => list(body.by_customer).map(row => ({
        customer: row.customer_name, invoices: row.invoice_count, amount: row.total_amount, latest: row.latest_invoice_date,
      })),
      columns: [
        { key: 'customer', label: 'customer', kind: 'text' },
        { key: 'invoices', label: 'invoices', kind: 'number', total: true },
        { key: 'amount', label: 'amount', kind: 'money', total: true },
        { key: 'latest', label: 'latestInvoice', kind: 'date' },
      ],
      summary: [
        { label: 'invoices', kind: 'number', value: body => body.summary?.total_invoices },
        { label: 'customers', kind: 'number', value: body => body.summary?.total_customers },
        { label: 'amount', kind: 'money', value: body => body.summary?.total_amount },
      ],
      defaultSort: { field: 'amount', order: 'desc' },
      // The app's amount sort of the customers list is the 'net' column it used to have (reportPdfSort.ts: amount -> net);
      // it is still accepted and sorts by the amount.
      sortAliases: { net: 'amount' },
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
        { label: 'itemsOver364', kind: 'number', value: itemsOver364 },
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
        // A per-customer count of items older than 365 days (items_over_365_days): the answer carries no per-customer
        // count of the 364+ bucket (a customer's aging_distribution holds bags), so this column stays as it was.
        { key: 'over_one_year', label: 'overOneYear', kind: 'number', total: true },
      ],
      summary: [
        { label: 'customers', kind: 'number', value: body => body.summary?.total_customers },
        { label: 'unitsInStock', kind: 'number', value: body => body.summary?.total_quantity },
        { label: ['averageAge', 'daysUnit'], kind: 'number', value: body => body.summary?.average_age_days },
        { label: 'itemsOver364', kind: 'number', value: itemsOver364 },
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
      // The customer's month-by-month movement over the period. The amounts (invoice_amount, and the summary's
      // total_invoice_amount, total_paid_amount and total_pending_amount) are the RPC's own: the invoice amounts
      // were total + labour + tax - discount, which counts the labour, the tax and the discount twice, until
      // migration 61 made them the invoices' total. This answer holds no invoice total to work them out from, so
      // they are right from migration 61 on.
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
      // total_invoice_amount is the RPC's own, right from migration 61 on (see the one-customer level above).
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

/** The fields a request may sort the report by (every column of its level, and the aliases of the level). */
export function sortFields(request: ReportRequest): string[] {
  const level = reportLevel(request);
  return [...level.columns.map(column => column.key), ...Object.keys(level.sortAliases ?? {})];
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
const pad = (number: number, width = 2) => String(number).padStart(width, '0');

// The facility's books are kept in India (UTC+05:30, no summer time). The report RPCs return some dates as plain India
// days ("2026-10-01": a dispatch's disp_date, the stock summary's days) and others as moments (a timestamptz written in
// UTC: invoice_date, grn_date, latest_invoice_date, last_activity_date, the stock aging grn_date and last_dispatch_date).
// A date column prints the India day of a moment, as the app's screen does (src/utils/formatters.ts, indiaDay), and not
// its first ten characters, which for a receipt made at 02:30 India time on 1 October is 30 September. Nothing here
// uses toLocale* or Intl with a time zone, so the result does not depend on the zone the function runs in.
const indiaShiftMs = (5 * 60 + 30) * 60_000;
const plainDay = /^\d{4}-\d{2}-\d{2}$/;
// A moment as the database writes a timestamptz, with its offset: ISO ("2026-09-30T21:00:00+00:00", "...Z") or
// Postgres-style ("2026-09-30 21:00:00+00"). A time with no offset is not a moment: it cannot be placed on any calendar.
const momentText = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?(Z|[+-]\d{2}(?::?\d{2})?)$/i;

/** A moment moved to India time: the Date's UTC getters read the clock in India. Null for anything that is not a moment. */
function inIndia(value: unknown): Date | null {
  const match = typeof value === 'string' ? momentText.exec(value) : null;
  if (!match) return null;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(part => Number(part ?? 0));
  const wall = new Date(Date.UTC(year, month - 1, day, hour, minute, second, Number((match[7] ?? '').slice(0, 3).padEnd(3, '0'))));
  // Date.UTC rolls an impossible day or time over (30 February, hour 24): the numbers written must come back out.
  if (wall.getUTCFullYear() !== year || wall.getUTCMonth() !== month - 1 || wall.getUTCDate() !== day
    || wall.getUTCHours() !== hour || wall.getUTCMinutes() !== minute || wall.getUTCSeconds() !== second) return null;
  // The offset: Z, or +HH, +HHMM, +HH:MM.
  const zone = /^([+-])(\d{2}):?(\d{2})?$/.exec(match[8]);
  const [offsetHours, offsetMinutes] = [Number(zone?.[2] ?? 0), Number(zone?.[3] ?? 0)];
  if (offsetHours > 23 || offsetMinutes > 59) return null;
  const offset = (zone?.[1] === '-' ? -1 : 1) * (offsetHours * 60 + offsetMinutes);
  return new Date(wall.getTime() - offset * 60_000 + indiaShiftMs);
}

/**
 * The calendar day in India of a date from the database, as "YYYY-MM-DD" (the rule of the app's indiaDay): a plain
 * "2026-10-01" is already a day and is returned as it is; a moment ("2026-09-30T21:00:00+00:00", "2026-09-30
 * 21:00:00+00") is moved to India time (+05:30) and its year, month and day are read with the UTC getters, so that
 * moment is 1 October. Empty, null or unreadable (also a time with no offset) gives "", the empty cell of a missing date.
 */
export function indiaDay(value: unknown): string {
  if (typeof value === 'string' && plainDay.test(value)) return value;
  const india = inIndia(value);
  return india ? `${pad(india.getUTCFullYear(), 4)}-${pad(india.getUTCMonth() + 1)}-${pad(india.getUTCDate())}` : '';
}

/** A cell as printed. Numbers use Indian digit grouping, dates DD-MM-YYYY on India's calendar (see `indiaDay`). */
export function formatCell(kind: Kind, value: unknown, lang: ReportLang): string {
  if (value === null || value === undefined || value === '') return '';
  if (kind === 'number' || kind === 'money') {
    const number = num(value);
    return number === null ? '' : (kind === 'money' ? money : plain).format(number);
  }
  if (kind === 'date') {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(indiaDay(value));
    return match ? `${match[3]}-${match[2]}-${match[1]}` : '';
  }
  const text = String(value);
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

// A date that cannot be read is as good as no date: it prints empty, so it sorts last.
const missingValue = (kind: Kind, value: unknown) => value === null || value === undefined || value === '' ||
  ((kind === 'number' || kind === 'money') && num(value) === null) || (kind === 'date' && indiaDay(value) === '');

function compare(kind: Kind, left: unknown, right: unknown): number {
  if (kind === 'number' || kind === 'money') return num(left)! - num(right)!;
  if (kind === 'date') {
    // By the day that is printed (India's); within a day two moments keep their true order, whatever offsets they are written with.
    const a = indiaDay(left); const b = indiaDay(right);
    if (a !== b) return a < b ? -1 : 1;
    const earlier = inIndia(left); const later = inIndia(right);
    return earlier && later ? earlier.getTime() - later.getTime() : 0;
  }
  if (kind === 'month') return String(left) < String(right) ? -1 : String(left) > String(right) ? 1 : 0;
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
  const all = level.rows(body, request);
  // An alias names the column it sorts by (own keys only: a field such as "constructor" names nothing here).
  const sent = request.sort && level.sortAliases && Object.hasOwn(level.sortAliases, request.sort.field)
    ? { ...request.sort, field: level.sortAliases[request.sort.field] } : request.sort;
  const wanted = sent && level.columns.some(column => column.key === sent.field) ? sent : level.defaultSort;
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
    rows: shown.map(row => level.columns.map(item => item.cell ? item.cell(row, lang) : formatCell(item.kind, row[item.key], lang))),
    totals,
    summary: level.summary.map(figure => [columnLabel(lang, figure.label), formatCell(figure.kind, figure.value(body, all, request) ?? 0, lang)]),
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

/**
 * The choices a report was made with, printed under the title and again as the first header row of the
 * table: the customer, the period, the Paid / Pending choice when there is one, the sort and the time.
 */
export function reportFilters(request: ReportRequest, customerName: string | null, report: Pick<BuiltReport, 'sort'>, now: string): [string, string][] {
  const lang = request.lang;
  const filters: [string, string][] = [[label(lang, 'customer'), customerName ?? label(lang, 'allCustomers')]];
  if (request.from && request.to) {
    filters.push([label(lang, 'period'), label(lang, 'dateRange', { from: formatCell('date', request.from, lang), to: formatCell('date', request.to, lang) })]);
  }
  if (request.status) filters.push([label(lang, 'payment'), label(lang, request.status)]);
  filters.push([label(lang, 'sortBy'), report.sort.label]);
  // The time of the report is India's day and India's clock (it was the UTC day and the UTC clock, "12-10-2026 08:00 UTC"),
  // so a report made at 02:30 India time on 1 October says 1 October.
  const india = inIndia(now);
  const clock = india ? `${pad(india.getUTCHours())}:${pad(india.getUTCMinutes())}` : '';
  filters.push(['', label(lang, 'updated', { time: `${formatCell('date', now, lang)} ${clock} IST` })]);
  return filters;
}
