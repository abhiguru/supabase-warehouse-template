// What the pre-printed invoice form (print-invoice-preprinted) may print, and the tax fields it prints (WH-151, migration 173).
//
// With GST details saved, nothing is cut: a value longer than its field on the form refuses that invoice, naming the field, and it is
// printed on plain paper (the PDF) instead. An invoice made before the GST details (doc_type 'invoice', or none before migration 173)
// prints exactly as before WH-151 (WH-172, Product): an amount over 10 characters, the amount in words over 74 and the address over 81
// are cut, the GSTIN is cut at the state, and nothing is refused for its length. Text columns of the item table (item name, packaging, GRN reference) are abbreviated by the layout as before.
// The tax fields: an invoice saved before the facility's GST details ('invoice') prints SGST and CGST as half the tax each, exactly as
// before; a tax invoice or invoice-cum-bill of supply prints the CGST and SGST the database stored; a bill or bill of supply leaves SGST,
// CGST and the tax total blank. An IGST invoice has no field on the form and is not printed on it.
// This module imports nothing so that the node checks can load it directly.

export const IGST_PLAIN_PAPER = 'IGST invoices print on plain paper.';

/** A value that does not fit its field on the form. */
export class PrintFitError extends Error {
  field: string;
  value: string;
  width: number;
  constructor(field: string, value: string, width: number) {
    super(`The ${field} (${value}) does not fit its ${width}-character field on the form`);
    this.field = field;
    this.value = value;
    this.width = width;
  }
}

/** The value, when it fits `width` characters; otherwise PrintFitError names the field. */
export function fitted(value: string, width: number, field: string): string {
  if (value.length > width) throw new PrintFitError(field, value, width);
  return value;
}

/** Whether the invoice was made with the facility's GST details saved (any document type but 'invoice'): the WH-151 switch. */
export function madeWithGstDetails(invoice: { doc_type?: unknown }): boolean {
  return Boolean(invoice.doc_type) && invoice.doc_type !== 'invoice';
}

/** The value cut to `width` characters, as the form did before WH-151. */
export function cut(value: string, width: number): string {
  return value.length > width ? value.substring(0, width) : value;
}

/** How this invoice's values meet their fields: refused when they do not fit (GST details saved), else cut as before WH-151. */
export function preprintedFit(invoice: { doc_type?: unknown }): (value: string, width: number, field: string) => string {
  return madeWithGstDetails(invoice) ? fitted : (value, width) => cut(value, width);
}

/** Why an invoice is not printed on the form at all, or null. */
export function preprintedRefusal(invoice: { gst_tax_head?: unknown }): 'igst' | null {
  return invoice.gst_tax_head === 'igst' ? 'igst' : null;
}

const amount = (value: unknown): number => {
  const n = typeof value === 'number' ? value : typeof value === 'string' && value.trim() !== '' ? Number(value) : 0;
  return Number.isFinite(n) ? n : 0;
};

/**
 * The SGST, CGST and tax-total fields, formatted with `formatCurrency` and checked against `width`. '' leaves a field blank.
 */
export function preprintedTaxFields(invoice: { doc_type?: unknown; tax_amount?: unknown; cgst_amount?: unknown; sgst_amount?: unknown },
                                    formatCurrency: (n: number) => string, width: number): { sgst: string; cgst: string; taxTotal: string } {
  const doc = invoice.doc_type ?? 'invoice';
  if (doc === 'bill' || doc === 'bill_of_supply') return { sgst: '', cgst: '', taxTotal: '' };
  const tax = (invoice.tax_amount as number) || 0;
  if (doc === 'tax_invoice' || doc === 'invoice_cum_bos') {
    return {
      sgst: fitted(formatCurrency(amount(invoice.sgst_amount)), width, 'SGST'),
      cgst: fitted(formatCurrency(amount(invoice.cgst_amount)), width, 'CGST'),
      taxTotal: fitted(formatCurrency(tax), width, 'Tax total'),
    };
  }
  // 'invoice' (and a database before migration 173): half the tax each, cut to the field, as the form always printed.
  return {
    sgst: cut(formatCurrency(tax / 2), width),
    cgst: cut(formatCurrency(tax / 2), width),
    taxTotal: cut(formatCurrency(tax), width),
  };
}

/**
 * The first line of the form: the full invoice number from INVOICE_NO_OFFSET (never cut; WH-139 lets it run past the GSTIN offset and
 * moves the GSTIN right by the extra, after one space), the customer's GSTIN (at most `gstinWidth` characters) and the state at
 * STATE_OFFSET. A GSTIN that is longer than its width, or that would run into the state, is refused.
 */
export function headerFit(invoice: { invoice_label?: unknown; inv_no?: unknown; gstin?: unknown },
                          layout: { INVOICE_NO_OFFSET: number; GSTIN_OFFSET: number; STATE_OFFSET: number }, gstinWidth: number): void {
  const number = String(invoice.invoice_label ?? invoice.inv_no ?? '');
  const gstin = String(invoice.gstin || '');
  fitted(gstin, gstinWidth, 'GSTIN');
  const afterNumber = layout.INVOICE_NO_OFFSET + number.length;
  const gstinStart = afterNumber < layout.GSTIN_OFFSET ? layout.GSTIN_OFFSET : afterNumber + 1;
  if (gstinStart + gstin.length > layout.STATE_OFFSET) {
    throw new PrintFitError('GSTIN', gstin, Math.max(0, layout.STATE_OFFSET - gstinStart));
  }
}

/** The state field of the form's first line: the facility's state the invoice was made with (GST details), else GUJARAT as before. */
export function preprintedState(invoice: { doc_type?: unknown; supplier_state_name?: unknown }): string {
  const name = typeof invoice.supplier_state_name === 'string' ? invoice.supplier_state_name.trim() : '';
  return madeWithGstDetails(invoice) && name ? name.toUpperCase() : 'GUJARAT';
}

/** A reference that keeps its end: longer than `width`, it is cut at the front and starts with "..." (the form's latin1 ellipsis). */
export function keepEnd(text: string, width: number): string {
  return text.length > width ? '...' + text.slice(text.length - (width - 3)) : text;
}
