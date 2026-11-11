// generate-temperature-report-pdf: one sensor's temperature report for a period, as an English PDF (WH-157, migration 186).
//
// The figures are get_temperature_report's, called with the caller's own token, so warehouse_security.authorize_rpc decides access
// (administrators, supervisors, staff and customer accounts, for every sensor). Nothing is worked out here except the drawing: every
// figure, stretch and time is printed as the server answered it, in India time. The chart is an inline SVG built below (no script;
// the content policy stays default-src 'none'). The server key is used only after the read, for the warehouse name and the private
// upload. The answer has the shape of the other PDFs: { success, pdf_url, expires_in, document }.
import { restClient } from './supabase-rest.ts';
import { validateUserAccess, createAuthErrorResponse, requestId } from './auth-helpers.ts';
import { securityHeaders } from './security-headers.ts';
import { createFooterHtml, renderDocumentPdf } from './pdf-renderer-client.ts';
import { escapeHtml } from './document-html.ts';
import { isLetterheadUri } from './letterhead.ts';
import { documentRequestBody } from './request-body.ts';
import { publicBaseUrl } from './public-url.ts';
import { estimatePages, MAX_PDF_PAGES, SOLO_PDF_PAGES } from './document-pages.ts';

const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const isoDay = /^\d{4}-\d{2}-\d{2}$/;

type Num = number | string | null;
interface Triple { min: Num; max: Num; avg: Num }
export interface TemperatureStretch {
  kind: 'too_warm' | 'too_cold' | 'no_readings';
  started_at: string; ended_at: string | null; began_before_period?: boolean;
  worst?: Num; limit?: Num; beyond?: Num; source?: 'raw' | 'hourly'; before_upgrade?: boolean;
  // `reason` 'failed' (a post was tried and failed) is not in the design's §5 yet: WH-157 open with Development/B3.
  alert?: { posted_at: string | null; reason: null | 'shorter' | 'no_channel' | 'not_recorded' | 'not_posted' | 'failed'; minutes?: number | null };
}
export interface TemperatureReport {
  made_at: string; made_by: string; record_started_at: string; silent_minutes: number;
  device: { id: string; name: string; location?: string | null; active?: boolean };
  period: { from_date: string; to_date: string; from: string; to: string; timezone: string; to_is_now?: boolean };
  hourly_part: null | { from: string; to: string };
  limits: {
    at_start: { min: Num; max: Num; since?: string | null; since_before?: boolean } | null;
    changes: { at: string; min: Num; max: Num; by?: string | null }[];
    not_recorded_before: string | null;
  };
  summary: { temperature: Triple; humidity: Triple; readings: number; too_warm_s: number; too_cold_s: number; no_readings_s: number; covered_share: number };
  chart: { bucket_s: number; points: { t: string; min: Num; max: Num; source: 'raw' | 'hourly' }[]; limit_steps: { from: string; min: Num; max: Num }[] };
  stretches: TemperatureStretch[];
  changes: { at: string; op: 'update' | 'delete' | 'insert' | 'truncate'; count: number }[];
  changes_not_recorded_before: string | null;
}

// ---- India time and number text -------------------------------------------------------------------------------------------------
const IST = 'Asia/Kolkata';
const parts = (value: string | number) => Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
  timeZone: IST, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
}).formatToParts(new Date(value)).map(part => [part.type, part.value]));
const valid = (value: unknown) => typeof value === 'string' && !Number.isNaN(new Date(value).getTime());
/** 11-11-2026 14:05 on India's clock. */
export const timeText = (value: string): string => { if (!valid(value)) return String(value ?? ''); const p = parts(value); return `${p.day}-${p.month}-${p.year} ${p.hour}:${p.minute}`; };
/** 11-11-2026 on India's calendar. */
export const dayText = (value: string): string => { if (!valid(value)) return String(value ?? ''); const p = parts(value); return `${p.day}-${p.month}-${p.year}`; };
const isoDayText = (value: string) => isoDay.test(value) ? `${value.slice(8, 10)}-${value.slice(5, 7)}-${value.slice(0, 4)}` : value;

const toNumber = (value: unknown): number | null => { if (value === null || value === undefined || value === '') return null; const n = Number(value); return Number.isFinite(n) ? n : null; };
const temp = (value: unknown) => { const n = toNumber(value); return n === null ? '—' : `${n.toFixed(1)} °C`; };
const humid = (value: unknown) => { const n = toNumber(value); return n === null ? '—' : `${n.toFixed(1)} %`; };
const count = (value: unknown) => { const n = toNumber(value); return n === null ? '' : new Intl.NumberFormat('en-IN').format(n); };
/** 1 h 10 min / 2 d 3 h / 40 min. */
export function lengthText(seconds: number): string {
  const total = Math.max(0, Math.round(seconds / 60));
  const days = Math.floor(total / 1440), hours = Math.floor((total % 1440) / 60), minutes = total % 60;
  const out = [days ? `${days} d` : '', hours ? `${hours} h` : '', minutes || !total ? `${minutes} min` : ''].filter(Boolean);
  return out.join(' ');
}
const seconds = (a: string, b: string) => (new Date(b).getTime() - new Date(a).getTime()) / 1000;

// ---- The words ------------------------------------------------------------------------------------------------------------------
const KIND: Record<TemperatureStretch['kind'], string> = { too_warm: 'Too warm', too_cold: 'Too cold', no_readings: 'No readings' };
/** Step 13, word for word (criterion 17 checks these and the absence of the word "tamper"). */
export const RECORD_SENTENCES_BEFORE = [
  'Readings are sent by the sensor automatically, about every 5 minutes. They are not typed by a person.',
  'The app has no function to change or delete a reading.',
  'Readings older than 90 days are kept as the lowest, highest and average of each hour.',
  "The server records any reading that is added, changed or deleted other than by the sensor's own feed.",
] as const;
export const RECORD_NONE = 'None is recorded for this period.';
export const RECORD_SENTENCE_LAST = 'This report shows what the sensor reported. It is not a calibration certificate for the sensor.';
const changeLine = (change: TemperatureReport['changes'][number]) => change.op === 'insert'
  ? `${timeText(change.at)}: ${count(change.count)} readings added outside the sensor's feed.`
  : `${timeText(change.at)}: ${count(change.count)} readings changed or deleted.`;

/** The Alert column: the posting time, or the reason there was none. */
export function alertText(row: TemperatureStretch): string {
  const alert = row.alert;
  if (alert?.posted_at) return timeText(alert.posted_at);
  switch (alert?.reason) {
    case 'shorter': return `No alert: shorter than ${count(alert.minutes)} minutes`;
    case 'no_channel': return 'No alert: no alert channel set up';
    // Product, 2026-11-11 (spec step 2): a post that was tried and failed has its own text.
    case 'failed': return 'The alert could not be posted.';
    // Product, 2026-11-11 (spec step 2): any other case without a posting time, including a stretch from before the upgrade.
    default: return 'No alert was posted.';
  }
}

/** The rows of the stretch table, for the page estimate and the HTML. */
export function stretchRows(report: TemperatureReport): string[][] {
  return report.stretches.map(row => {
    const hourly = row.source === 'hourly' ? ' *' : '';
    const start = `${timeText(row.started_at)}${hourly}${row.began_before_period ? ' (began before this period)' : ''}`;
    const end = row.ended_at ? `${timeText(row.ended_at)}${hourly}` : 'still continuing';
    const endForLength = row.ended_at ?? (report.period.to_is_now ? report.made_at : report.period.to);
    const worst = row.kind === 'no_readings' ? '—' : `${temp(row.worst)}, ${temp(row.beyond)} beyond the ${row.kind === 'too_warm' ? 'highest' : 'lowest'} limit (${temp(row.limit)})`;
    return [KIND[row.kind], start, end, lengthText(seconds(row.started_at, endForLength)), worst, alertText(row)];
  });
}

// ---- The chart ------------------------------------------------------------------------------------------------------------------
const W = 720, H = 280, L = 52, R = 12, T = 12, B = 34;
const f = (n: number) => (Math.round(n * 10) / 10).toString();

export function chartSvg(report: TemperatureReport): string {
  const from = new Date(report.period.from).getTime();
  const to = Math.max(from + 1, new Date(report.period.to_is_now && valid(report.made_at) ? report.made_at : report.period.to).getTime());
  const x = (t: string | number) => L + ((Math.min(Math.max(new Date(t).getTime(), from), to) - from) / (to - from)) * (W - L - R);
  const points = report.chart.points.filter(p => toNumber(p.min) !== null && toNumber(p.max) !== null);
  const steps = report.chart.limit_steps;
  const values: number[] = [];
  for (const p of points) values.push(Number(p.min), Number(p.max));
  for (const s of steps) for (const v of [toNumber(s.min), toNumber(s.max)]) if (v !== null) values.push(v);
  for (const s of report.stretches) { const v = toNumber(s.worst); if (v !== null) values.push(v); }
  let lo = values.length ? Math.min(...values) : 0, hi = values.length ? Math.max(...values) : 10;
  if (hi - lo < 2) { lo -= 1; hi += 1; }
  const pad = (hi - lo) * 0.08; lo -= pad; hi += pad;
  const y = (v: number) => T + (1 - (v - lo) / (hi - lo)) * (H - T - B);
  const out: string[] = [];
  out.push(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="Temperature over the period">`);
  out.push('<defs><pattern id="gap" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="6" height="6" fill="#ffffff"/><line x1="0" y1="0" x2="0" y2="6" stroke="#8a94a0" stroke-width="2"/></pattern></defs>');
  out.push(`<rect x="${L}" y="${T}" width="${W - L - R}" height="${H - T - B}" fill="#ffffff" stroke="#cfd6de"/>`);
  // Stretches first, behind the lines.
  for (const s of report.stretches) {
    const x1 = x(s.started_at), x2 = s.ended_at ? x(s.ended_at) : x(to);
    const fill = s.kind === 'too_warm' ? '#f6c9c4' : s.kind === 'too_cold' ? '#c4daf6' : 'url(#gap)';
    if (new Date(s.ended_at ?? to).getTime() < from || new Date(s.started_at).getTime() > to) continue;
    out.push(`<rect x="${f(x1)}" y="${T}" width="${f(Math.max(x2 - x1, 1.5))}" height="${H - T - B}" fill="${fill}" opacity="0.85"/>`);
  }
  // Y axis.
  for (let i = 0; i <= 4; i++) {
    const v = lo + ((hi - lo) * i) / 4;
    out.push(`<line x1="${L}" y1="${f(y(v))}" x2="${W - R}" y2="${f(y(v))}" stroke="#e6eaef"/>`);
    out.push(`<text x="${L - 5}" y="${f(y(v) + 3)}" font-size="9" text-anchor="end" fill="#444">${escapeHtml(v.toFixed(1))}</text>`);
  }
  out.push(`<text x="10" y="${(T + H - B) / 2}" font-size="9" fill="#444" text-anchor="middle" transform="rotate(-90 10 ${(T + H - B) / 2})">°C</text>`);
  // X axis labels in India time.
  const long = to - from > 2 * 86400000;
  for (let i = 0; i <= 6; i++) {
    const t = from + ((to - from) * i) / 6;
    const text = long ? dayText(new Date(t).toISOString()) : timeText(new Date(t).toISOString()).slice(0, 16).replace(/^(\d\d)-(\d\d)-\d{4} /, '$1-$2 ');
    out.push(`<text x="${f(x(t))}" y="${H - B + 14}" font-size="9" fill="#444" text-anchor="${i === 0 ? 'start' : i === 6 ? 'end' : 'middle'}">${escapeHtml(text)}</text>`);
  }
  out.push(`<text x="${W - R}" y="${H - 4}" font-size="9" fill="#444" text-anchor="end">India time</text>`);
  // Min-max band, one sub-path per run of buckets (a gap of more than 2.5 buckets starts a new run). Raw and hourly parts differ in colour.
  const bucket = Math.max(60, report.chart.bucket_s) * 1000;
  for (const source of ['hourly', 'raw'] as const) {
    const mine = points.filter(p => p.source === source);
    const runs: typeof mine[] = [];
    for (const p of mine) {
      const run = runs[runs.length - 1];
      if (run && new Date(p.t).getTime() - new Date(run[run.length - 1].t).getTime() <= bucket * 2.5) run.push(p); else runs.push([p]);
    }
    const d = runs.map(run => {
      const w = Math.max(bucket, 3600000) * (source === 'hourly' ? 1 : 0) / 2 || 0;
      const px = (p: typeof run[number]) => f(x(new Date(p.t).getTime() + w));
      const top = run.map((p, i) => `${i ? 'L' : 'M'}${px(p)} ${f(y(Number(p.max)))}`).join('');
      const bottom = [...run].reverse().map(p => `L${px(p)} ${f(y(Number(p.min)))}`).join('');
      // A run of one bucket would have no area: give it a short vertical stroke.
      return run.length === 1 ? `${top}L${px(run[0])} ${f(y(Number(run[0].min)))}` : `${top}${bottom}Z`;
    }).join('');
    if (d) out.push(`<path d="${d}" fill="${source === 'raw' ? '#3b6ea8' : '#7a8fa6'}" fill-opacity="0.55" stroke="${source === 'raw' ? '#1f4f86' : '#566b82'}" stroke-width="0.8"/>`);
  }
  // Limit lines as step paths.
  for (const key of ['max', 'min'] as const) {
    let d = '';
    steps.forEach((s, i) => {
      const v = toNumber(s[key]);
      const x1 = x(s.from), x2 = i + 1 < steps.length ? x(steps[i + 1].from) : x(to);
      if (v === null) return;
      d += `M${f(x1)} ${f(y(v))}L${f(x2)} ${f(y(v))}`;
    });
    if (d) out.push(`<path d="${d}" fill="none" stroke="${key === 'max' ? '#b3261e' : '#1b5fb3'}" stroke-width="1.4" stroke-dasharray="5 3"/>`);
  }
  out.push('</svg>');
  return out.join('');
}

// ---- The page -------------------------------------------------------------------------------------------------------------------
export function periodText(report: TemperatureReport): string {
  const end = report.period.to_is_now ? `${timeText(report.made_at)} (when this report was made)` : timeText(report.period.to);
  return `${timeText(report.period.from)} to ${end}, India time`;
}

export function temperatureReportHtml(report: TemperatureReport, company: string, letterhead?: string): string {
  const image = isLetterheadUri(letterhead) ? letterhead : '';
  const upgrade = dayText(report.record_started_at);
  const s = report.summary;
  const e = escapeHtml;
  // The whole-UTC-hour windows of the hourly part (design §6): the exact India-time window is printed, not hidden.
  const hourlyNote = report.hourly_part
    ? `From ${timeText(report.hourly_part.from)} to ${timeText(report.hourly_part.to)} India time, readings are kept as the lowest, highest and average of each hour; those hours start at half past the hour, India time.`
    : '';
  const at = report.limits.at_start;
  const limitText = (min: Num, max: Num) => toNumber(min) === null && toNumber(max) === null ? 'No limits set'
    : `Lowest ${toNumber(min) === null ? 'not set' : temp(min)}, highest ${toNumber(max) === null ? 'not set' : temp(max)}`;
  const limitLines: string[] = [];
  if (at) limitLines.push(`${limitText(at.min, at.max)}${at.since_before ? ` (in force since before ${upgrade})` : at.since ? ` (in force since ${timeText(at.since)})` : ''}`);
  else limitLines.push('No limits set');
  for (const change of report.limits.changes) limitLines.push(`${timeText(change.at)}: changed to ${limitText(change.min, change.max).toLowerCase()}${change.by ? `, by ${change.by}` : ''}`);
  if (report.limits.not_recorded_before) limitLines.push(`Limits before ${isoDayText(report.limits.not_recorded_before)} were not recorded.`);

  const rows = stretchRows(report);
  const anyBeforeUpgrade = report.stretches.some(r => r.before_upgrade);
  const anyHourly = report.stretches.some(r => r.source === 'hourly');
  const table = rows.length === 0
    ? `<p>No reading was outside the limits and no gap was longer than ${e(count(report.silent_minutes))} minutes.</p>`
    : `${anyBeforeUpgrade ? `<p class="note">Before ${e(upgrade)}: worked out from stored readings using the limits of ${e(upgrade)}; alert times were not recorded.</p>` : ''}
    <table><thead><tr>${['Kind', 'Start', 'End', 'Length', 'Worst reading', 'Alert'].map(h => `<th>${e(h)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(row => `<tr>${row.map(cell => `<td>${e(cell)}</td>`).join('')}</tr>`).join('')}</tbody></table>
    ${anyHourly ? '<p class="note">* Worked out from hourly readings: this time is a whole hour.</p>' : ''}`;

  const recordLines = [
    ...RECORD_SENTENCES_BEFORE.map(t => `<li>${e(t)}</li>`),
    ...(report.changes.length === 0 ? [`<li class="sub">${e(RECORD_NONE)}</li>`] : report.changes.map(c => `<li class="sub">${e(changeLine(c))}</li>`)),
    ...(report.changes_not_recorded_before ? [`<li>${e(`Changes before ${isoDayText(report.changes_not_recorded_before)} were not recorded.`)}</li>`] : []),
    `<li>${e(RECORD_SENTENCE_LAST)}</li>`,
  ].join('');
  const summaryRows: [string, string][] = [
    ['Lowest temperature', temp(s.temperature.min)], ['Highest temperature', temp(s.temperature.max)], ['Average temperature', temp(s.temperature.avg)],
    ['Lowest humidity', humid(s.humidity.min)], ['Highest humidity', humid(s.humidity.max)], ['Average humidity', humid(s.humidity.avg)],
    ['Number of readings', count(s.readings)],
    ['Total time too warm', lengthText(s.too_warm_s)], ['Total time too cold', lengthText(s.too_cold_s)], ['Total time with no readings', lengthText(s.no_readings_s)],
    ['Share of the period covered by readings', `${(Number(s.covered_share) * 100).toFixed(1)} %`],
  ];
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none';${image ? ' img-src data:;' : ''} style-src 'unsafe-inline'">
    <style>body{font:12px 'Liberation Sans','Noto Sans Gujarati',sans-serif;color:#18212f}h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:0 0 4px}
    h3{font-size:14px;margin:20px 0 6px;break-after:avoid}.meta{margin:0 0 4px}.note{color:#555}svg{width:100%;height:auto}.legend{color:#333;margin:4px 0}
    .figures{border:1px solid #cfd6de;border-radius:4px;padding:6px 12px;margin:0 0 8px;break-inside:avoid}.figure{display:flex;justify-content:space-between;gap:16px;padding:2px 0}
    .figure dd{margin:0;font-weight:bold;white-space:nowrap}.figure dt{margin:0}
    table{border-collapse:collapse;width:100%}th,td{padding:5px 6px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}th{background:#edf1f5}
    thead{display:table-header-group}tr{break-inside:avoid}ul{margin:0;padding-left:18px}li{margin:3px 0}li.sub{margin-left:16px}${image ? '.letterhead{width:100%;height:auto;display:block;margin-bottom:16px}' : ''}</style>
    </head><body>${image ? `<img class="letterhead" src="${image}" alt="">` : ''}<h1>${e(company)}</h1><h2>Temperature report</h2>
    <p class="meta"><strong>${e(report.device.name)}</strong>${report.device.location ? `, ${e(report.device.location)}` : ''}${report.device.active === false ? ' (Deactivated)' : ''}</p>
    <p class="meta">Period: ${e(periodText(report))}</p>
    <p class="meta">Made on ${e(timeText(report.made_at))} by ${e(report.made_by)}</p>
    <h3>Limits in force</h3><ul>${limitLines.map(l => `<li>${e(l)}</li>`).join('')}</ul>
    <h3>Summary</h3><dl class="figures">${summaryRows.map(([k, v]) => `<div class="figure"><dt>${e(k)}</dt><dd>${e(v)}</dd></div>`).join('')}</dl>
    ${hourlyNote ? `<p class="note">${e(hourlyNote)}</p>` : ''}
    <h3>Chart</h3>${chartSvg(report)}
    <p class="legend">Blue band: lowest to highest reading in each interval. Dashed red line: highest limit. Dashed blue line: lowest limit. Red shading: too warm. Blue shading: too cold. Hatched: no readings.</p>
    ${report.hourly_part ? `<p class="note">${e(`Before ${dayText(report.hourly_part.to)}: hourly lowest and highest.`)}</p><p class="note">${e(hourlyNote)}</p>` : ''}
    <h3>Every time out of range or without readings</h3>${table}
    <h3>How this record is kept</h3><ul>${recordLines}</ul>
    </body></html>`;
}

export function footerNote(report: TemperatureReport): string {
  return `${report.device.name} | ${dayText(report.period.from)} to ${report.period.to_is_now ? dayText(report.made_at) : dayText(report.period.to)}`;
}

// The read's refusals, as the screen maps them to its own texts.
const REFUSALS: Record<string, string> = {
  INVALID_PERIOD: 'Choose a period that ends today or earlier.',
  PERIOD_TOO_LONG: 'Choose a period of 12 months or less.',
  PERIOD_TOO_OLD: 'Readings are kept for 2 years. Choose a later start date.',
  DEVICE_NOT_FOUND: 'Sensor unavailable',
  NO_READINGS: 'This sensor has no readings in this period.',
};

export async function temperatureReportPdf(req: Request): Promise<Response> {
  try {
    if (req.method !== 'POST') throw { status: 405, message: 'POST required' };
    await validateUserAccess(req);
    const body = await documentRequestBody(req) as Record<string, unknown>;
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw { status: 400, message: 'Invalid document request' };
    if (typeof body.device_id !== 'string' || !uuid.test(body.device_id)) throw { status: 400, message: 'device_id must be a UUID' };
    for (const key of ['from_date', 'to_date']) {
      if (typeof body[key] !== 'string' || !isoDay.test(body[key] as string) || Number.isNaN(Date.parse(body[key] as string))) throw { status: 400, message: `${key} must be a date (YYYY-MM-DD)` };
    }
    const internal = Deno.env.get('SUPABASE_URL')!;
    const publicUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    // The business read uses the caller's token: the RPC guard decides access.
    const reader = restClient(internal, Deno.env.get('SUPABASE_ANON_KEY')!, { authorization: req.headers.get('Authorization')! });
    const answer = await reader.rpc('get_temperature_report', { p_device_id: body.device_id, p_from: body.from_date, p_to: body.to_date });
    if (answer.error) {
      if (answer.error.code === '42501') throw { status: 403, message: 'Temperature report not available to this account' };
      throw { status: 503, message: 'Temperature report data unavailable' };
    }
    if (answer.data?.success !== true) {
      const code = String(answer.data?.error_code ?? '');
      if (REFUSALS[code]) throw { status: code === 'DEVICE_NOT_FOUND' ? 404 : 400, message: REFUSALS[code], code };
      throw { status: 503, message: 'Temperature report data unavailable' };
    }
    const report = answer.data.data as TemperatureReport;
    const pages = estimatePages([...stretchRows(report), ...report.changes.map(c => [changeLine(c)])]) + 2;
    if (pages > MAX_PDF_PAGES) throw { status: 400, message: `Document is too long to print (about ${pages} pages; the limit is ${MAX_PDF_PAGES})` };

    const writer = restClient(internal, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const company = await writer.from('system_settings').select('value').eq('key', 'app_name').single();
    if (company.error || typeof company.data?.value !== 'string' || !company.data.value.trim()) throw { status: 503, message: 'Warehouse branding unavailable' };
    const html = temperatureReportHtml(report, company.data.value, Deno.env.get('LETTERHEAD_DATA_URI') || undefined);
    const pdf = await renderDocumentPdf(html, { solo: pages > SOLO_PDF_PAGES, requestId: requestId(req),
      footerHtml: createFooterHtml(company.data.value, 'Temperature report', '', footerNote(report)) });
    // Upload uses server authority only after the report read was authorized.
    const path = `temperature-report/${report.device.id}/${crypto.randomUUID()}.pdf`;
    const upload = await writer.storage.from('documents').upload(path, pdf, { contentType: 'application/pdf', upsert: false });
    if (upload.error) throw { status: 503, message: 'Document storage unavailable' };
    const signed = await writer.storage.from('documents').createSignedUrl(path, 3600);
    if (signed.error || !signed.data) throw { status: 503, message: 'Document link unavailable' };
    const signedUrl = new URL(signed.data.signedUrl);
    return new Response(JSON.stringify({ success: true, pdf_url: publicUrl + signedUrl.pathname + signedUrl.search, expires_in: 3600,
      document: { type: 'temperature-report', sensor: report.device.name, from: report.period.from_date, to: report.period.to_date } }), {
      headers: { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  } catch (error) { return createAuthErrorResponse(error, securityHeaders, req); }
}
