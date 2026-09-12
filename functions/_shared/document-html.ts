export const escapeHtml = (value: unknown): string => String(value ?? '').replace(/[&<>"']/g,
  char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]!));

export function documentHtml(title: string, company: string, metadata: Record<string, unknown>, columns: string[], rows: unknown[][]): string {
  return `<!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{font:12px sans-serif;color:#18212f}h1{font-size:24px}h2{font-size:18px}table{border-collapse:collapse;width:100%;margin-top:24px}th,td{padding:8px;border-bottom:1px solid #ddd;text-align:left}th{background:#edf1f5}tr{break-inside:avoid}small{color:#555}</style>
    </head><body><h1>${escapeHtml(company)}</h1><h2>${escapeHtml(title)}</h2>
    ${Object.entries(metadata).map(([key,value]) => `<p><strong>${escapeHtml(key)}:</strong> ${escapeHtml(value)}</p>`).join('')}
    <table><thead><tr>${columns.map(c => `<th>${escapeHtml(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(row => `<tr>${row.map(cell => `<td>${escapeHtml(cell)}</td>`).join('')}</tr>`).join('')}</tbody></table>
    <p><small>Open-source starter layout. Configure your business details and document terms before operational use.</small></p></body></html>`;
}
