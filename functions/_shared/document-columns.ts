// Header columns each document function reads with the caller's token.
//
// `invoice` is granted to the app role column by column (migration 48): its
// discount record and zero-charge record are internal, and a customer account
// reads its own invoice rows. `select('*')` on it is refused, so the invoice
// header names what the document prints and nothing else. A field added to the
// invoice document is added here; tests/document-columns.test.mjs compares the
// list with the fields document-pdf.ts uses.
export const invoiceHeaderColumns = 'id,customer_name,inv_date,inv_fin_year,inv_prefix,labour,tax_amount,discount,total';

// A cancelled invoice prints one more line (migration 134). Its two columns are read apart from the header, so the header list above stays
// the fields every invoice prints.
export const invoiceCancelColumns = 'cancelled_at,cancel_reason';

// The GST document type (migration 173), read apart from the header too: an invoice of type 'invoice' (every invoice saved before the
// facility's GST details) prints exactly as before; any other type prints the GST layout (gst-document-html.ts).
export const invoiceDocTypeColumns = 'doc_type';

// The lines of a GST document: the stored figures of migration 173 and what describes the line (a cancelled invoice's kept copy, migration 143).
export const invoiceGstLineColumns = 'duration,no_of_days,labour_rate,charge,tax,gst_treatment,taxable_value,line_tax,cgst_amount,sgst_amount,igst_amount,'
  + 'details_kept_at,kept_item_name,kept_disp_qty,kept_disp_no,dispatch_trl(disp_qty,dispatch(disp_no),goodsreceived_trl(item_name))';

export const headerColumns = (kind: 'grn' | 'dispatch' | 'invoice') =>
  kind === 'invoice' ? invoiceHeaderColumns : '*';
