// The request body of generate-report-pdf, checked before anything is read.
// Every refusal is a 400 with a fixed message; no part of the body is echoed.
import type { ReportLang } from './report-labels.ts';

export const reportNames = ['grn-activity', 'dispatch-activity', 'invoice-history', 'stock-summary', 'stock-aging',
  'item-stock-summary', 'customer-activity'] as const;
export type ReportName = typeof reportNames[number];

/** Reports that cover a chosen period: `from` and `to` are required for them and refused for the others. */
export const periodReports: ReadonlySet<ReportName> = new Set(['grn-activity', 'dispatch-activity', 'invoice-history', 'customer-activity']);

/** The longest period one PDF covers, both days included. */
export const maxPeriodDays = 450;

export interface ReportRequest {
  report: ReportName;
  customerId: string | null;
  from: string | null;
  to: string | null;
  /** As sent; the report decides whether the field is one it sorts by. */
  sort: { field: string; order: 'asc' | 'desc' } | null;
  lang: ReportLang;
}

const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const allowedKeys = new Set(['report', 'customer_id', 'from', 'to', 'sort', 'lang']);
const bad = (message: string) => ({ status: 400, message });

/** Day number of a real calendar date written YYYY-MM-DD, or null. */
export function dayNumber(value: unknown): number | null {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const [year, month, day] = value.split('-').map(Number);
  const time = Date.UTC(year, month - 1, day);
  const date = new Date(time);
  if (year < 2000 || date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return time / 86_400_000;
}

export function parseReportRequest(body: unknown): ReportRequest {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw bad('Invalid report request');
  const input = body as Record<string, unknown>;
  for (const key of Object.keys(input)) {
    if (!allowedKeys.has(key)) throw bad('Unknown field in report request');
  }
  if (typeof input.report !== 'string' || !(reportNames as readonly string[]).includes(input.report)) throw bad('Unknown report');
  const report = input.report as ReportName;

  let customerId: string | null = null;
  if (input.customer_id !== undefined && input.customer_id !== null) {
    if (typeof input.customer_id !== 'string' || !uuid.test(input.customer_id)) throw bad('customer_id must be a UUID');
    customerId = input.customer_id.toLowerCase();
  }

  let from: string | null = null;
  let to: string | null = null;
  if (periodReports.has(report)) {
    if (input.from === undefined || input.to === undefined) throw bad('from and to are required for this report');
    const start = dayNumber(input.from);
    const end = dayNumber(input.to);
    if (start === null || end === null) throw bad('from and to must be dates written YYYY-MM-DD');
    if (start > end) throw bad('from must not be after to');
    if (end - start + 1 > maxPeriodDays) throw bad(`The period must not be longer than ${maxPeriodDays} days`);
    from = input.from as string;
    to = input.to as string;
  } else if (input.from !== undefined || input.to !== undefined) {
    throw bad('This report has no period; leave out from and to');
  }

  let sort: ReportRequest['sort'] = null;
  if (input.sort !== undefined && input.sort !== null) {
    const value = input.sort as Record<string, unknown>;
    if (typeof value !== 'object' || Array.isArray(value)) throw bad('sort must be an object');
    for (const key of Object.keys(value)) {
      if (key !== 'field' && key !== 'order') throw bad('Unknown field in sort');
    }
    if (typeof value.field !== 'string' || !/^[a-z_]{1,40}$/.test(value.field)) throw bad('sort.field must be a short lower-case name');
    if (value.order !== 'asc' && value.order !== 'desc') throw bad("sort.order must be 'asc' or 'desc'");
    sort = { field: value.field, order: value.order };
  }

  let lang: ReportLang = 'en';
  if (input.lang !== undefined && input.lang !== null) {
    if (input.lang !== 'en' && input.lang !== 'gu') throw bad("lang must be 'en' or 'gu'");
    lang = input.lang;
  }
  return { report, customerId, from, to, sort, lang };
}
