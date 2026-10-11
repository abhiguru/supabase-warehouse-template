// Header columns each document function reads with the caller's token.
//
// `invoice` is granted to the app role column by column (migration 48): its
// discount record and zero-charge record are internal, and a customer account
// reads its own invoice rows. `select('*')` on it is refused, so the invoice
// header names what the document prints and nothing else. A field added to the
// invoice document is added here; tests/document-columns.test.mjs compares the
// list with the fields document-pdf.ts uses.
export const invoiceHeaderColumns = 'id,customer_name,inv_date,inv_fin_year,labour,tax_amount,discount,total';

export const headerColumns = (kind: 'grn' | 'dispatch' | 'invoice') =>
  kind === 'invoice' ? invoiceHeaderColumns : '*';
