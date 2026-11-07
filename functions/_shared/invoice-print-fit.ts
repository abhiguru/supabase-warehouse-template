// What the pre-printed invoice form (print-invoice-preprinted) may print, and the tax fields it prints (WH-151, migration 173).
//
// Nothing is cut: a value longer than its field on the form refuses that invoice, naming the field, and it is printed on plain paper
// (the PDF) instead. Before WH-151 an amount over 10 characters, the amount in words over 74 and the address over 81 were cut without a
// word. Text columns of the item table (item name, packaging, GRN reference) are abbreviated by the layout as before.
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
  // 'invoice' (and a database before migration 173): half the tax each, as the form always printed.
  return {
    sgst: fitted(formatCurrency(tax / 2), width, 'SGST'),
    cgst: fitted(formatCurrency(tax / 2), width, 'CGST'),
    taxTotal: fitted(formatCurrency(tax), width, 'Tax total'),
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
