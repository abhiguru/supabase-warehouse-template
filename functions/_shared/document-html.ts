import { formatCell } from './report-definitions.ts';

export const escapeHtml = (value: unknown): string => String(value ?? '').replace(/[&<>"']/g,
  char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]!));

// The weight of one package as the document prints it: 0 means "not recorded" (docs/STAFF_GRN_POLICY.md), so 0, null,
// undefined and anything that is not a finite number print an em dash, like the app. Every other value is printed as it is.
export const kgEach = (value: unknown): unknown =>
  value === null || value === undefined || value === 0 || (typeof value === 'number' && !Number.isFinite(value)) ? '\u2014' : value;

// The Date line of a GRN, dispatch, invoice or stock document: DD-MM-YYYY on India's calendar, as the report PDFs print
// dates (a receipt's "2026-10-13T00:00:00+00:00" is 13-10-2026). A value that cannot be read as a date is printed as it is.
export const documentDate = (value: unknown): string => formatCell('date', value, 'en') || String(value ?? '');

export function documentHtml(title: string, company: string, metadata: Record<string, unknown>, columns: string[], rows: unknown[][]): string {
  return `<!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{font:12px 'Liberation Sans','Noto Sans Gujarati',sans-serif;color:#18212f}h1{font-size:24px}h2{font-size:18px}table{border-collapse:collapse;width:100%;margin-top:24px}th,td{padding:8px;border-bottom:1px solid #ddd;text-align:left}th{background:#edf1f5}tr{break-inside:avoid}small{color:#555}</style>
    </head><body><h1>${escapeHtml(company)}</h1><h2>${escapeHtml(title)}</h2>
    ${Object.entries(metadata).map(([key,value]) => `<p><strong>${escapeHtml(key)}:</strong> ${escapeHtml(value)}</p>`).join('')}
    <table><thead><tr>${columns.map(c => `<th>${escapeHtml(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(row => `<tr>${row.map(cell => `<td>${escapeHtml(cell)}</td>`).join('')}</tr>`).join('')}</tbody></table>
    <p><small>Open-source starter layout. Configure your business details and document terms before operational use.</small></p></body></html>`;
}

export interface ReportHtml {
  title: string;
  company: string;
  lang: 'en' | 'gu';
  /** Label and value of each choice the report was made with (customer, period, sort, time). */
  filters: [string, string][];
  summaryTitle: string;
  /** Label and printed value of each figure of the summary block. */
  summary: [string, string][];
  columns: { label: string; numeric: boolean }[];
  rows: string[][];
  /** The totals row, or null for none. */
  totals: string[] | null;
  /** Printed under the table, e.g. that rows were left out. */
  note?: string;
  /** Printed instead of the table when there are no rows. */
  empty: string;
}

// A report: the summary figures first, then one table. The choices the report
// was made with are printed in the header and again as the first header row
// of the table, which Chromium repeats on every page. Number columns are
// right-aligned with figures of one width, so digits line up.
export function reportHtml(report: ReportHtml): string {
  const cell = (tag: 'th' | 'td', value: string, numeric: boolean) =>
    `<${tag}${numeric ? ' class="num"' : ''}>${escapeHtml(value)}</${tag}>`;
  // A filter without a label (the time of the report) prints its value alone.
  const filters = report.filters.map(([key, value]) =>
    `<span class="filter">${key ? `<strong>${escapeHtml(key)}:</strong> ` : ''}${escapeHtml(value)}</span>`).join(' ');
  const width = Math.max(report.columns.length, 1);
  const table = report.rows.length === 0
    ? `<p class="empty">${escapeHtml(report.empty)}</p>`
    : `<table><thead><tr class="filters"><th colspan="${width}">${filters}</th></tr>
    <tr>${report.columns.map(column => cell('th', column.label, column.numeric)).join('')}</tr></thead>
    <tbody>${report.rows.map(row => `<tr>${row.map((value, index) => cell('td', value, report.columns[index]?.numeric ?? false)).join('')}</tr>`).join('')}
    ${report.totals ? `<tr class="totals">${report.totals.map((value, index) => cell('td', value, report.columns[index]?.numeric ?? false)).join('')}</tr>` : ''}</tbody></table>`;
  return `<!doctype html><html lang="${report.lang === 'gu' ? 'gu' : 'en'}"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{font:12px 'Liberation Sans','Noto Sans Gujarati',sans-serif;color:#18212f}h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:0 0 8px}
    .filters-block{margin:0 0 12px}.filter{display:inline-block;margin-right:16px}
    .summary{border:1px solid #cfd6de;border-radius:4px;padding:8px 12px;margin:0 0 16px;break-inside:avoid}.summary h3{font-size:13px;margin:0 0 6px}
    .kpis{display:flex;flex-wrap:wrap;gap:8px 24px;margin:0}.kpi{min-width:120px}.kpi dt{color:#555;font-size:11px}.kpi dd{margin:0;font-size:15px;font-weight:bold;font-variant-numeric:tabular-nums}
    table{border-collapse:collapse;width:100%}th,td{padding:6px 8px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}th{background:#edf1f5}
    thead{display:table-header-group}tr.filters th{background:#fff;font-weight:normal;font-size:10px;color:#555;border-bottom:1px solid #cfd6de}
    .num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}tr{break-inside:avoid}tr.totals td{font-weight:bold;border-top:2px solid #18212f;border-bottom:none}
    .note{color:#8a4b00}.empty{margin-top:24px;color:#555}small{color:#555}</style>
    </head><body><h1>${escapeHtml(report.company)}</h1><h2>${escapeHtml(report.title)}</h2>
    <div class="filters-block">${filters}</div>
    <section class="summary"><h3>${escapeHtml(report.summaryTitle)}</h3><dl class="kpis">${report.summary.map(([key, value]) =>
      `<div class="kpi"><dt>${escapeHtml(key)}</dt><dd>${escapeHtml(value)}</dd></div>`).join('')}</dl></section>
    ${table}
    ${report.note ? `<p class="note">${escapeHtml(report.note)}</p>` : ''}</body></html>`;
}
