// The PDF of a GST document (migration 173, WH-151): tax invoice, bill of supply, invoice-cum-bill of supply or bill. An invoice of type
// 'invoice' (saved before the facility's GST details existed) never comes here: documentHtml prints it exactly as before.
// English only, figures and dates in 0-9 (docs/INVOICE_RULES.md, "GST documents"). Every figure is the one the database stored at the
// save (get_invoice_detail's gst object and the invoice_trl columns of migration 173); nothing is worked out here but sums for display.
import { escapeHtml } from './document-html.ts';
import { isLetterheadUri } from './letterhead.ts';

export type GstDocType = 'bill' | 'bill_of_supply' | 'tax_invoice' | 'invoice_cum_bos';

export const GST_TITLES: Record<GstDocType, string> = {
  tax_invoice: 'TAX INVOICE',
  bill_of_supply: 'BILL OF SUPPLY',
  invoice_cum_bos: 'INVOICE-CUM-BILL OF SUPPLY',
  bill: 'BILL',
};

export const isGstDocType = (value: unknown): value is GstDocType =>
  typeof value === 'string' && Object.prototype.hasOwnProperty.call(GST_TITLES, value);

export const EXEMPT_LINE = 'Exempt supply, no GST charged';
export const REVERSE_CHARGE_LINE = 'Whether tax is payable on reverse charge: No';

interface Party { legal_name?: string | null; address?: string | null; gstin?: string | null; state_code?: string | null; state_name?: string | null }

/** get_invoice_detail's `invoice` object, the fields this layout uses. */
export interface GstInvoice {
  doc_type: GstDocType;
  inv_no: unknown;
  gr_no?: unknown;
  customer_name?: unknown;
  labour?: unknown;
  tax_amount?: unknown;
  discount?: unknown;
  total?: unknown;
  grn_pricing_mode?: unknown;
  gst: {
    supplier: Party;
    customer: Party;
    place_of_supply: { code: string; name: string | null } | null;
    tax_head: 'cgst_sgst' | 'igst' | null;
    sac_storage: string | null;
    sac_labour: string | null;
    cgst_amount: unknown;
    sgst_amount: unknown;
    igst_amount: unknown;
  };
}

/** One invoice_trl row read with invoiceGstLineColumns. */
export interface GstLine {
  duration?: unknown; labour_rate?: unknown; charge?: unknown; tax?: unknown; gst_treatment?: unknown;
  taxable_value?: unknown; cgst_amount?: unknown; sgst_amount?: unknown; igst_amount?: unknown;
  details_kept_at?: unknown; kept_item_name?: unknown; kept_disp_qty?: unknown; kept_disp_no?: unknown;
  dispatch_trl?: any;
}

const paise = (value: unknown): number => {
  const n = typeof value === 'number' ? value : typeof value === 'string' && value.trim() !== '' ? Number(value) : 0;
  return Number.isFinite(n) ? Math.round(n * 100) : 0;
};
/** An amount with two decimals and Indian grouping, digits 0-9: 123456.5 -> 1,23,456.50. */
export const money = (value: unknown): string =>
  (paise(value) / 100).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const percent = (value: number): string => `${Number.isInteger(value) ? value : value.toFixed(2).replace(/0$/, '')}%`;
const one = (value: any) => (Array.isArray(value) ? value[0] : value);
const stateText = (party: Party): string =>
  party.state_code ? `${party.state_name ?? 'Unknown state'} (${party.state_code})` : 'Not given';

/** The column headings of a document's line table. */
export function gstColumns(invoice: GstInvoice): string[] {
  const head = invoice.gst.tax_head;
  const columns = ['Description'];
  if (invoice.doc_type !== 'bill') columns.push('SAC');
  columns.push('Quantity', 'Months', 'Rate', 'Labour rate', 'Taxable value');
  if (head === 'cgst_sgst') columns.push('CGST rate', 'CGST', 'SGST rate', 'SGST');
  if (head === 'igst') columns.push('IGST rate', 'IGST');
  return columns;
}

/** The cells of each line, in the order of gstColumns. */
export function gstRows(invoice: GstInvoice, lines: GstLine[]): string[][] {
  const head = invoice.gst.tax_head;
  const oneTime = invoice.grn_pricing_mode === 'ONE_TIME';
  return lines.map(line => {
    const dispatch = one(line.dispatch_trl);
    const kept = line.details_kept_at != null;
    const item = kept ? line.kept_item_name : one(dispatch?.goodsreceived_trl)?.item_name;
    const dispNo = kept ? line.kept_disp_no : one(dispatch?.dispatch)?.disp_no;
    const quantity = kept ? line.kept_disp_qty : dispatch?.disp_qty;
    const exempt = line.gst_treatment === 'exempt_agri';
    const description = [item ?? 'Details not available', invoice.gr_no != null ? `GRN ${invoice.gr_no}` : '',
      dispNo != null ? `dispatch ${dispNo}` : ''].filter(Boolean).join(', ') + (exempt && invoice.doc_type === 'invoice_cum_bos' ? ' (exempt)' : '');
    const cells = [description];
    if (invoice.doc_type !== 'bill') {
      const labour = paise(line.labour_rate) > 0 && !oneTime;
      cells.push(labour ? `${invoice.gst.sac_storage ?? ''} (storage), ${invoice.gst.sac_labour ?? ''} (labour)` : String(invoice.gst.sac_storage ?? ''));
    }
    cells.push(String(quantity ?? ''), oneTime ? 'One-time' : String(line.duration ?? ''), money(line.charge),
      oneTime ? '' : money(line.labour_rate), money(line.taxable_value));
    const rate = Number(line.tax ?? 0);
    if (head === 'cgst_sgst') {
      cells.push(exempt ? 'Exempt' : percent(rate / 2), money(line.cgst_amount), exempt ? 'Exempt' : percent(rate / 2), money(line.sgst_amount));
    } else if (head === 'igst') {
      cells.push(exempt ? 'Exempt' : percent(rate), money(line.igst_amount));
    }
    return cells;
  });
}

/** The totals block: taxable value, the tax by head, discount, the rounding of the total, and the total. Every row adds up in paise. */
export function gstTotals(invoice: GstInvoice, lines: GstLine[]): [string, string][] {
  const taxable = lines.reduce((sum, line) => sum + paise(line.taxable_value), 0);
  const rows: [string, string][] = [['Taxable value', money(taxable / 100)]];
  const gst = invoice.gst;
  let tax = 0;
  if (gst.tax_head === 'cgst_sgst') {
    rows.push(['CGST', money(gst.cgst_amount)], ['SGST', money(gst.sgst_amount)]);
    tax = paise(gst.cgst_amount) + paise(gst.sgst_amount);
  } else if (gst.tax_head === 'igst') {
    rows.push(['IGST', money(gst.igst_amount)]);
    tax = paise(gst.igst_amount);
  }
  const discount = paise(invoice.discount);
  if (discount !== 0) rows.push([discount > 0 ? 'Discount' : 'Surcharge', money(Math.abs(discount) / 100)]);
  const rounding = paise(invoice.total) - (taxable + tax - discount);
  if (rounding !== 0) rows.push(['Rounded off', `${rounding < 0 ? '-' : ''}${money(Math.abs(rounding) / 100)}`]);
  rows.push(['Total', money(invoice.total)]);
  return rows;
}

export interface GstDocumentInput {
  invoice: GstInvoice;
  lines: GstLine[];
  /** The full invoice number as printed. */
  number: string;
  /** The invoice date as printed (documentDate). */
  date: string;
  financialYear: unknown;
  /** The company name, printed when the document has no legal name. */
  company: string;
  letterhead?: string;
}

export function gstDocumentHtml(input: GstDocumentInput): string {
  const { invoice } = input;
  const gst = invoice.gst;
  const image = isLetterheadUri(input.letterhead) ? input.letterhead : '';
  const legalName = String(gst.supplier.legal_name ?? '').trim() || input.company;
  const taxDocument = gst.tax_head !== null;
  const columns = gstColumns(invoice);
  const rows = gstRows(invoice, input.lines);
  const numeric = (index: number) => index >= columns.indexOf('Quantity');
  const p = (label: string, value: unknown) => `<p><strong>${escapeHtml(label)}:</strong> ${escapeHtml(value)}</p>`;
  const supplier = [
    gst.supplier.address ? `<p>${escapeHtml(gst.supplier.address)}</p>` : '',
    gst.supplier.gstin ? p('GSTIN', gst.supplier.gstin) : '',
    gst.supplier.gstin ? p('State', stateText(gst.supplier)) : '',
  ].join('');
  const customer = [
    p('Bill to', invoice.customer_name),
    p('Address', gst.customer.address || 'Not given'),
    gst.customer.gstin ? p('GSTIN', gst.customer.gstin) : '',
    p('State', stateText(gst.customer)),
  ].join('');
  const supply = taxDocument
    ? [p('Place of supply', gst.place_of_supply ? `${gst.place_of_supply.name ?? ''} (${gst.place_of_supply.code})` : 'Not given'),
       `<p>${escapeHtml(REVERSE_CHARGE_LINE)}</p>`].join('')
    : '';
  const totals = gstTotals(invoice, input.lines);
  return `<!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none';${image ? " img-src data:;" : ''} style-src 'unsafe-inline'">
    <style>body{font:12px 'Liberation Sans','Noto Sans Gujarati',sans-serif;color:#18212f}h1{font-size:22px;margin:0 0 4px}h2{font-size:18px}p{margin:2px 0}.parties{display:flex;gap:32px;margin-top:12px}.parties>div{flex:1}table{border-collapse:collapse;width:100%;margin-top:16px}th,td{padding:6px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}th{background:#edf1f5}.num{text-align:right;font-variant-numeric:tabular-nums}tr{break-inside:avoid}.totals{margin:12px 0 0 auto;width:auto}.totals td{border:none;padding:2px 8px}.totals tr:last-child td{font-weight:bold;border-top:2px solid #18212f}.sign{margin-top:48px;text-align:right}${image ? '.letterhead{width:100%;height:auto;display:block;margin-bottom:16px}' : ''}</style>
    </head><body>${image ? `<img class="letterhead" src="${image}" alt="">` : ''}<h1>${escapeHtml(legalName)}</h1>${supplier}<h2>${escapeHtml(GST_TITLES[invoice.doc_type])}</h2>
    ${p('Number', input.number)}${p('Date', input.date)}${p('Financial year', input.financialYear)}
    <div class="parties"><div>${customer}</div><div>${supply}</div></div>
    <table><thead><tr>${columns.map((c, i) => `<th${numeric(i) ? ' class="num"' : ''}>${escapeHtml(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(row => `<tr>${row.map((cell, i) => `<td${numeric(i) ? ' class="num"' : ''}>${escapeHtml(cell)}</td>`).join('')}</tr>`).join('')}</tbody></table>
    <table class="totals"><tbody>${totals.map(([label, value]) => `<tr><td>${escapeHtml(label)}</td><td class="num">${escapeHtml(value)}</td></tr>`).join('')}</tbody></table>
    ${invoice.doc_type === 'bill_of_supply' ? `<p><strong>${escapeHtml(EXEMPT_LINE)}</strong></p>` : ''}
    <div class="sign"><p>For ${escapeHtml(legalName)}</p><br><br><p>Authorised signatory</p></div></body></html>`;
}
