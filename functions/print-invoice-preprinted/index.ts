import { restClient } from '../_shared/supabase-rest.ts'
import { monitorPrintJobStatus } from '../_shared/print-status-monitor.ts'
import { submitRawJob, jobOutcome, printFailureBody, configuredPrinterName } from '../_shared/print-transport.ts'
import { groupInvoiceLines, paginateInvoiceRows } from '../_shared/invoice-print-layout.ts'
import type { InvoicePrintPage } from '../_shared/invoice-print-layout.ts'
import { lineStorageAmount, cumulativeStorageAmount, resolveInvoiceFinYear } from '../_shared/invoice-print-amounts.ts'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'
import { sanitizeForPrinter, encodeLatin1 } from '../_shared/printer-text.ts'

// ESC/P Control Codes for Epson LQ 1310
const ESC = '\x1B';
const LF = '\x0A';
const FF = '\x0C';
const CR = '\x0D';
const DC4 = '\x14';

const ESCP = {
  RESET: ESC + '@',
  // Font selection
  PICA_10CPI: ESC + 'P',           // 10 characters per inch (default)
  ELITE_12CPI: ESC + 'M',          // 12 characters per inch
  CONDENSED_17CPI: ESC + '\x0F',   // 17 characters per inch

  // Line spacing
  LINE_SPACING_1_8: ESC + '0',     // 1/8 inch (8 lines per inch)
  LINE_SPACING_1_6: ESC + '2',     // 1/6 inch (6 lines per inch) - default
  LINE_SPACING_N_216: ESC + '3',   // n/216 inch (custom spacing)

  // Positioning
  ABSOLUTE_POSITION: ESC + '$',    // Absolute horizontal position
  RELATIVE_POSITION: ESC + '\\',   // Relative horizontal position

  // Text attributes
  BOLD_ON: ESC + 'E',
  BOLD_OFF: ESC + 'F',
  UNDERLINE_ON: ESC + '-1',
  UNDERLINE_OFF: ESC + '-0',
  DOUBLE_WIDTH_ON: ESC + '\x0E',      // SO - Double-width on
  DOUBLE_WIDTH_OFF: DC4,              // DC4 (bare, no ESC) - Double-width off
  DOUBLE_HEIGHT_ON: ESC + 'w1',       // Double-height on
  DOUBLE_HEIGHT_OFF: ESC + 'w0',      // Double-height off

  // Page control
  FORM_FEED: FF,
  LINE_FEED: LF,
  CARRIAGE_RETURN: CR,
};

// Plain text layout for invoice pre-printed form
// Form dimensions: 20cm height × 23.2cm width
// At 10 CPI and 6 LPI: 91 chars × 47 lines per invoice
// 23.2cm continuous paper @ 10 CPI = 91 characters width

// Default layout profile: calibrated for the standard pre-printed invoice form (fanfold stationery,
// 23 cm tall x 23.2 cm wide) on an Epson LQ-1310 at 10 CPI / 6 LPI. Adjust these values to suit a
// different form. Columns are character positions; *_180 values are fine vertical moves in 1/180 inch
// (30/180 = one line), taken from a line and given back after it so later lines do not move.
const LAYOUT = {
  // Page dimensions
  PAGE_WIDTH: 91,            // 23.2cm @ 10 CPI = 91.3 chars
  FORM_HEIGHT: 47,           // 20cm @ 6 LPI = 47.2 lines
  ITEMS_PER_PAGE: 20,        // Item ROWS per invoice page: group headers count (invoice-print-layout.ts)

  // Header section (positions scaled for 10 CPI)
  HEADER_START_LINE: 0,      // No empty lines at start

  // Paper: fanfold continuous stationery on the push tractor. Each page feeds from top-of-form
  // (where the printer parks the paper, and returns it after tear-off) down to the first print
  // line, and ends with FF to the next form's top-of-form, so no manual positioning is needed.
  HEADER_DROP_180: 6,        // Invoice-no + name lines dropped 6/180" (20% of a line)
  TAX_DROP_180: 15,          // SGST/CGST amounts dropped 15/180" (50% of a line)
  TOP_OFFSET_MM: 34,         // First print line below the form's top perforation
  LOAD_POSITION_MM: 10.5,    // Top-of-form below the perforation
  FORM_LENGTH_MM: 203.2,     // Perforation-to-perforation pitch = 8", sent as page length in 1/360" units
  INVOICE_NO_OFFSET: 8,      // Invoice number (2cm from left @ 10 CPI = 7.87 chars)
  GSTIN_OFFSET: 21,          // GSTIN field offset (5.3cm from left @ 10 CPI = 20.9 chars)
  STATE_OFFSET: 51,          // State field offset (13cm from left @ 10 CPI = 51.2 chars)
  DATE_OFFSET: 78,           // Date field offset (19.8cm from left @ 10 CPI = 78 chars)

  // Customer details
  ADDRESS_OFFSET: 5,         // Left margin for customer address

  // Items table
  ITEMS_START_LINE: 12,      // Items start at line 12

  // Column widths (measurements in cm: 2.2, 2.1, 1.2, 2.15, 1.2, 2.2, 1.3, 1.9, 1.6, 2.7, 2.5)
  // At 10 CPI: 1 cm = 3.94 chars (23.2cm / 10 CPI = 91.3 chars / 23.2cm = 3.94)
  COL_WIDTHS: {
    ITEM_NAME: 9,         // 2.2cm @ 10 CPI = 8.67 chars
    SPACE1: 1,
    PACKAGING: 6,         // Reduced from 8 to 6 - truncates 2 more chars
    SPACE2: 0,            // Reduced from 1 to 0 - moves INW_QTY left by 1 more char (total 3 left)
    INW_QTY: 5,           // 1.2cm @ 10 CPI = 4.73 chars - moved 3 chars left
    SPACE3: 1,            // Reduced from 2 to 1 - moves DEPOSIT_DATE 1 char left
    DEPOSIT_DATE: 8,      // Increased from 7 to 8 - fix truncation
    SPACE4: 0,            // Reduced from 1 to 0 - moves OUT_QTY 2 chars left (with DEPOSIT_DATE reduction)
    OUT_QTY: 5,           // 1.2cm @ 10 CPI = 4.73 chars - moved 2 chars left
    SPACE5: 2,            // Reduced from 3 to 2 - moves DELIVERY_DATE 1 char left
    DELIVERY_DATE: 9,     // 2.2cm @ 10 CPI = 8.67 chars - moved 1 char left
    SPACE6: 0,            // Stays at 0
    DURATION: 4,          // Back to 4 - moves WEIGHT 1 char right
    SPACE7: 1,            // 1 char before WEIGHT: weight moved 1 char right...
    WEIGHT: 6,            // Weight column with 2 decimal precision (e.g., 5.00)
    SPACE8: 1,            // ...taken from this gap, so RATE onward stays put
    RATE: 6,              // 1.6cm @ 10 CPI = 6.30 chars
    SPACE9: 0,            // Reduced from 1 to 0 - moves AMOUNT 1 char left
    AMOUNT: 10,           // Reduced from 11 to 10 - moves AMOUNT 1 more char left (total 2 left)
    SPACE10: 3,           // Increased from 2 to 3 - moves GRN_NO 1 more char right (total 2 right)
    GRN_NO: 10,           // 2.5cm @ 10 CPI = 9.85 chars - moved 2 chars right
  },

  // Footer section
  TOTALS_LINE: 28,          // Total row after 14 items + spacing
  INW_TOTAL_COL: 22,        // Column for total inward qty
  OUT_TOTAL_COL: 44,        // Column for total outward qty
  AMOUNT_TOTAL_COL: 78,     // Column for total amount
  CONTINUATION_COL: 95,     // "Continued..." message column

  // Tax and grand total
  TAX_SECTION_LINE: 32,     // Tax breakdown section
  TAX_LABEL_OFFSET: 10,     // Left margin for tax labels
  TAX_VALUE_OFFSET: 40,     // Tax amount values column
  LABOUR_LABEL_OFFSET: 55,  // Labour label offset
  LABOUR_VALUE_OFFSET: 75,  // Labour amount column

  GRAND_TOTAL_LINE: 38,     // Grand total line
  GRAND_TOTAL_LABEL_OFFSET: 55,
  GRAND_TOTAL_VALUE_OFFSET: 75,

  TOTAL_WORDS_LINE: 42,     // Total in words line
  TOTAL_WORDS_OFFSET: 10,   // Left margin for amount in words
};

// Helper functions for plain text layout
function padRight(text: any, width: number): string {
  const str = String(text || '').substring(0, width);
  return str + ' '.repeat(Math.max(0, width - str.length));
}

function padLeft(text: any, width: number): string {
  const str = String(text || '').substring(0, width);
  return ' '.repeat(Math.max(0, width - str.length)) + str;
}

function padCenter(text: any, width: number): string {
  const str = String(text || '').substring(0, width);
  const totalPadding = Math.max(0, width - str.length);
  const leftPadding = Math.floor(totalPadding / 2);
  const rightPadding = totalPadding - leftPadding;
  return ' '.repeat(leftPadding) + str + ' '.repeat(rightPadding);
}

function createLine(content: string, offset: number): string {
  return ' '.repeat(offset) + content + '\n';
}

function emptyLines(count: number): string {
  return '\n'.repeat(count);
}

function formatDate(dateStr: string): string {
  if (!dateStr) return '';
  const date = new Date(dateStr);
  const day = String(date.getDate()).padStart(2, '0');
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const year = String(date.getFullYear()).slice(-2);
  return `${day}/${month}/${year}`;
}

function truncateString(str: string, maxLength: number): string {
  if (!str) return '';
  return str.length > maxLength ? str.substring(0, maxLength) : str;
}

function formatCurrency(amount: number): string {
  if (!amount && amount !== 0) return '';
  return amount.toFixed(2);
}

// Marks a group header repeated at the top of a page, inside the item-name width.
const CONTINUED = ' contd.';

// Generate a single invoice page: the rows paginateInvoiceRows gave it
function generateInvoicePage(
  invoice: any,
  page: InvoicePrintPage<any>,
  allItems: any[],  // Every line of the invoice (for the Invoice total row)
  pageNum: number,
  totalPages: number,
  isLastPage: boolean
): string {
  let output = '';

  // === TOP OFFSET ===
  // Feed from top-of-form down to TOP_OFFSET_MM (ESC J n = n/180", at most 255 per command).
  // HEADER_DROP_180 is added: the invoice-no and name lines sit that much lower, and it is
  // taken back after the name line so the item table does not move.
  let topFeed = Math.max(0, Math.round((LAYOUT.TOP_OFFSET_MM - LAYOUT.LOAD_POSITION_MM) / 25.4 * 180)) + LAYOUT.HEADER_DROP_180;
  while (topFeed > 0) {
    const n = Math.min(255, topFeed);
    output += ESC + 'J' + String.fromCharCode(n);
    topFeed -= n;
  }

  // === HEADER SECTION ===

  // Line 1: Invoice No, GSTIN, State (GUJARAT), and Date ALL on same line
  // Build header using absolute positioning to avoid overlaps
  let headerLine = '';

  // Invoice Number at position 9 (2cm)
  headerLine = padRight('', LAYOUT.INVOICE_NO_OFFSET);  // Start with spaces to position 9
  headerLine += invoice.inv_no;

  // GSTIN at position 25 (5.3cm) - use absolute positioning
  const currentLength = headerLine.length;
  if (currentLength < LAYOUT.GSTIN_OFFSET) {
    headerLine += ' '.repeat(LAYOUT.GSTIN_OFFSET - currentLength);
  } else {
    // If invoice number is too long, ensure at least 1 space separator
    headerLine = headerLine.substring(0, LAYOUT.GSTIN_OFFSET - 1) + ' ';
  }
  headerLine += truncateString(invoice.gstin || '', 25);

  // STATE at position 61 (13cm) - use absolute positioning
  const lengthAfterGSTIN = headerLine.length;
  if (lengthAfterGSTIN < LAYOUT.STATE_OFFSET) {
    headerLine += ' '.repeat(LAYOUT.STATE_OFFSET - lengthAfterGSTIN);
  } else {
    // Truncate if too long
    headerLine = headerLine.substring(0, LAYOUT.STATE_OFFSET);
  }
  headerLine += 'GUJARAT';

  // DATE at position 93 (19.8cm) - use absolute positioning
  const lengthAfterState = headerLine.length;
  if (lengthAfterState < LAYOUT.DATE_OFFSET) {
    headerLine += ' '.repeat(LAYOUT.DATE_OFFSET - lengthAfterState);
  } else {
    // Truncate if too long
    headerLine = headerLine.substring(0, LAYOUT.DATE_OFFSET);
  }
  headerLine += formatDate(invoice.inv_date);

  output += headerLine + '\n';

  // Line 2: Customer full address (Name, Address, City, Mobile) - immediately on next line
  const addressParts = [
    invoice.customer_name,
    invoice.address,
    invoice.city,
    invoice.mobile
  ].filter(part => part).join(', ');
  const fullAddress = truncateString(addressParts, LAYOUT.PAGE_WIDTH - LAYOUT.ADDRESS_OFFSET - 5);
  // End the name line with CR + only the rest of a line, giving back HEADER_DROP_180
  output += ' '.repeat(LAYOUT.ADDRESS_OFFSET) + fullAddress + CR;
  output += ESC + 'J' + String.fromCharCode(30 - LAYOUT.HEADER_DROP_180);

  // === ITEMS TABLE ===
  // Add 2 more blank lines after customer address (3 total before items)
  output += '\n\n\n';

  // Print each row - a GRN group header row, or a dispatch detail row
  page.rows.forEach((row) => {
    const w = LAYOUT.COL_WIDTHS;
    const item: any = row.line;

    if (row.kind === 'group') {
      let headerLine = '';

      // GRN Header: Item Name, Packaging, Inward Qty, GRN Date, (empty dispatch cols), GRN No
      const itemName = row.continued
        ? truncateString(item.grn_items_item_name || '', w.ITEM_NAME - CONTINUED.length) + CONTINUED
        : truncateString(item.grn_items_item_name || '', w.ITEM_NAME);
      headerLine += padRight(itemName, w.ITEM_NAME);
      headerLine += ' '.repeat(w.SPACE1);

      const packingDetails = item.grn_items_packaging || item.grn_items_package_mark || '';
      headerLine += padCenter(truncateString(packingDetails, w.PACKAGING), w.PACKAGING);
      headerLine += ' '.repeat(w.SPACE2);

      headerLine += padLeft(String(item.grn_items_quantity || 0), w.INW_QTY);
      headerLine += ' '.repeat(w.SPACE3);

      // Date of deposit, 1 char right. Only header rows print it, and their Out Qty cell is
      // always blank, so the extra char comes out of that blank cell: dispatch rows and the
      // totals row (which share these widths) do not move.
      headerLine += ' ' + padCenter(formatDate(item.grns_date), w.DEPOSIT_DATE);
      headerLine += ' '.repeat(w.SPACE4);

      // Empty dispatch columns on header row (Out Qty 1 narrower: see the date above)
      headerLine += ' '.repeat(w.OUT_QTY - 1);
      headerLine += ' '.repeat(w.SPACE5);
      headerLine += ' '.repeat(w.DELIVERY_DATE);
      headerLine += ' '.repeat(w.SPACE6);
      headerLine += ' '.repeat(w.DURATION);
      headerLine += ' '.repeat(w.SPACE7);
      headerLine += ' '.repeat(w.WEIGHT);
      headerLine += ' '.repeat(w.SPACE8);
      headerLine += ' '.repeat(w.RATE);
      headerLine += ' '.repeat(w.SPACE9);
      headerLine += ' '.repeat(w.AMOUNT);
      headerLine += ' '.repeat(w.SPACE10);

      // GRN No at the end
      const grnRef = `${item.grns_gr_no}/${item.grn_items_quantity || 0}`;
      headerLine += padRight(truncateString(grnRef, w.GRN_NO), w.GRN_NO);

      output += headerLine + '\n';
      return;
    }

    // Dispatch detail row: (empty GRN cols), Out Qty, Dispatch Date, Duration, Weight, Rate, Amount
    let detailLine = '';

    // Empty GRN columns
    detailLine += ' '.repeat(w.ITEM_NAME);
    detailLine += ' '.repeat(w.SPACE1);
    detailLine += ' '.repeat(w.PACKAGING);
    detailLine += ' '.repeat(w.SPACE2);
    detailLine += ' '.repeat(w.INW_QTY);
    detailLine += ' '.repeat(w.SPACE3);
    detailLine += ' '.repeat(w.DEPOSIT_DATE);
    detailLine += ' '.repeat(w.SPACE4);

    // Dispatch details
    detailLine += padLeft(String(item.dispatches_items_disp_qty || 0), w.OUT_QTY);
    detailLine += ' '.repeat(w.SPACE5);

    detailLine += padCenter(formatDate(item.dispatches_date), w.DELIVERY_DATE);
    detailLine += ' '.repeat(w.SPACE6);

    // Months charged, always 1 decimal (1.0, 2.5, 12.0) so the column lines up
    const months = parseFloat(item.duration);
    detailLine += padLeft(Number.isFinite(months) ? months.toFixed(1) : '', w.DURATION);
    detailLine += ' '.repeat(w.SPACE7);

    // Weight - show on every dispatch row
    const weight = item.grn_items_weight ? parseFloat(item.grn_items_weight).toFixed(2) : '';
    detailLine += padLeft(truncateString(weight, w.WEIGHT), w.WEIGHT);
    detailLine += ' '.repeat(w.SPACE8);

    detailLine += padLeft(formatCurrency(item.charge || 0), w.RATE);
    detailLine += ' '.repeat(w.SPACE9);

    // The storage amount the database computed (migration 72): a ONE_TIME line is charged once.
    detailLine += padLeft(formatCurrency(lineStorageAmount(item)), w.AMOUNT);
    detailLine += ' '.repeat(w.SPACE10);

    // Empty GRN No column
    detailLine += ' '.repeat(w.GRN_NO);

    output += detailLine + '\n';
  });

  // === FILL EMPTY ITEM ROWS ===
  // The page never holds more rows than the form (header rows included).
  const emptyRowCount = Math.max(0, LAYOUT.ITEMS_PER_PAGE - page.rows.length);
  output += emptyLines(emptyRowCount);

  // === TOTALS: this page's rows only, then the whole invoice ===
  // Inward qty counts each GRN group once per page (a group continued onto the next page counts
  // on both pages); out qty and amount sum the page's dispatch rows. A multi-page invoice labels
  // the row "Page N:" and adds an "Invoice total" row (all pages) below it on every page.
  const sumRows = (rows: any[]) => {
    let inw = 0, out = 0;
    rows.forEach((item: any, index: number) => {
      if (index === 0 || item.grn_items_id !== rows[index - 1].grn_items_id) {
        inw += item.grn_items_quantity || 0;
      }
      out += item.dispatches_items_disp_qty || 0;
    });
    // The storage amounts the database computed, added in paise
    return { inw, out, amt: cumulativeStorageAmount(rows) };
  };
  const pageSums = sumRows(page.lines);

  // Column positions: INW_QTY, OUT_QTY and the right edge of AMOUNT
  const W = LAYOUT.COL_WIDTHS;
  const inwQtyColStart = W.ITEM_NAME + W.SPACE1 + W.PACKAGING + W.SPACE2;
  const outQtyColStart = inwQtyColStart + W.INW_QTY + W.SPACE3 + W.DEPOSIT_DATE + W.SPACE4;
  const amountColEnd = outQtyColStart + W.OUT_QTY + W.SPACE5 + W.DELIVERY_DATE + W.SPACE6 +
                       W.DURATION + W.SPACE7 + W.WEIGHT + W.SPACE8 + W.RATE + W.SPACE9 + W.AMOUNT;

  // A totals row: label, inward qty, outward qty, amount (right aligned in the amount column)
  const totalsRow = (label: string, sums: { inw: number; out: number; amt: number }) => {
    let row = padRight(label, inwQtyColStart);
    row += padLeft(String(sums.inw), W.INW_QTY);
    row += ' '.repeat(Math.max(0, outQtyColStart - row.length));
    row += padLeft(String(sums.out), W.OUT_QTY);
    row += ' '.repeat(Math.max(0, amountColEnd - W.AMOUNT - row.length));
    row += padLeft(formatCurrency(sums.amt), W.AMOUNT);
    return row;
  };

  let totalsLine = totalsRow(totalPages > 1 ? `Page ${pageNum}:` : '', pageSums);
  if (!isLastPage) totalsLine += '   Continued...';
  output += totalsLine + '\n';

  // Invoice total (whole invoice) under the page total on EVERY page of a multi-page invoice.
  // On the last page it takes the first of the 2 spacing lines before the tax block, so the
  // tax and grand-total lines do not move.
  const printInvoiceTotal = totalPages > 1;
  if (printInvoiceTotal) {
    output += totalsRow('Invoice total', sumRows(allItems)) + '\n';
  }

  // === FOOTER SECTION (last page only; every page ends with FF) ===
  if (isLastPage) {
    // Spacing before tax section - 2 lines (1 if the Invoice total row used one)
    output += printInvoiceTotal ? '\n' : '\n\n';

    // Tax breakdown (SGST and CGST)
    const sgst = (invoice.tax_amount || 0) / 2;
    const cgst = (invoice.tax_amount || 0) / 2;
    const taxLeftOffset = 12; // 3cm from left @ 10 CPI

    // SGST/CGST amounts (left, at 3cm) sit TAX_DROP_180/180" below their lines; Labour and
    // Tax Total (amount column) stay on the lines. The printer cannot feed backwards, so each
    // line prints in two passes, top to bottom:
    //   Y      : Labour            Y+drop    : SGST
    //   Y+30   : Tax total         Y+30+drop : CGST
    //   Y+60   : Grand total (unchanged)
    const labourPos = amountColEnd - 10; // Right align in amount column
    const drop = LAYOUT.TAX_DROP_180;
    output += ' '.repeat(labourPos) + padLeft(formatCurrency(invoice.labour || 0), 10) + CR;
    output += ESC + 'J' + String.fromCharCode(drop);
    output += ' '.repeat(taxLeftOffset) + padLeft(formatCurrency(sgst), 10) + CR;
    output += ESC + 'J' + String.fromCharCode(30 - drop);
    output += ' '.repeat(labourPos) + padLeft(formatCurrency(invoice.tax_amount || 0), 10) + CR;
    output += ESC + 'J' + String.fromCharCode(drop);
    output += ' '.repeat(taxLeftOffset) + padLeft(formatCurrency(cgst), 10) + CR;
    output += ESC + 'J' + String.fromCharCode(30 - drop);

    // Grand total line - just value, no label or "Rs.", aligned under amount column
    let grandTotalLine = ' '.repeat(labourPos);
    grandTotalLine += padLeft(formatCurrency(invoice.total || 0), 10);
    output += grandTotalLine + '\n';

    // Total in words, one line below the grand total - 12 chars from left margin
    const totalWordsOffset = 12;
    let amountInWords = invoice.inwords || '';
    // Remove "Rupees " if it exists at the start, ensure "only" at end
    amountInWords = amountInWords.replace(/^Rupees\s+/i, '');
    if (!amountInWords.toLowerCase().endsWith('only')) {
      amountInWords = amountInWords + ' only';
    }
    const truncatedWords = truncateString(amountInWords, LAYOUT.PAGE_WIDTH - totalWordsOffset - 5);
    output += '\n';
    output += createLine(truncatedWords, totalWordsOffset);
  }

  // End of page: FF to the next form's top-of-form (the page length is set in the job header)
  output += ESCP.FORM_FEED;

  return output;
}

// Generate complete invoice document for pre-printed form
function generatePrePrintedInvoice(invoiceData: any): string {
  const invoice = invoiceData;
  const rawItems = invoice.trl || []; // trl array contains denormalized items

  // Lines of the same GRN item together (the groups in the order first seen)
  const items: any[] = groupInvoiceLines(rawItems);

  let output = '';

  // Initialize printer: 10 CPI (larger font), 6 LPI for 23.2cm paper (RAW mode)
  output += ESCP.RESET;              // Reset printer to defaults
  output += ESCP.PICA_10CPI;         // 10 characters per inch (91 chars @ 23.2cm) - LARGER FONT
  output += ESCP.LINE_SPACING_1_6;   // 6 lines per inch (standard)
  output += ESC + '\x6C' + '\x00';   // Left margin = 0 (no margin)
  output += ESC + '\x51' + String.fromCharCode(110); // Right margin = 110 chars for 10 CPI
  // Page length = one invoice form, so FF lands exactly on the next form's top-of-form.
  // 8" is not a whole number of lines at the default units, so use ESC/P2 fine units:
  //   ESC ( U 01 00 10      -> unit = 10/3600" = 1/360"
  //   ESC ( C 02 00 mL mH   -> page length = (mH*256 + mL) units
  const formUnits = Math.round(LAYOUT.FORM_LENGTH_MM / 25.4 * 360);   // 203.2mm -> 2880
  output += ESC + '(U' + '\x01\x00' + String.fromCharCode(10);
  output += ESC + '(C' + '\x02\x00' + String.fromCharCode(formUnits & 0xFF) + String.fromCharCode(formUnits >> 8);

  // Pages by printed rows: a group header takes a row, is repeated (contd.) when
  // its group goes on to the next page, and never ends a page on its own.
  const pages = paginateInvoiceRows(items, LAYOUT.ITEMS_PER_PAGE);
  const totalPages = pages.length;

  // Generate each page - simply concatenate like GRN/Dispatch (continuous form handles positioning)
  for (let pageNum = 1; pageNum <= totalPages; pageNum++) {
    const page = pages[pageNum - 1];
    const isLastPage = (pageNum === totalPages);

    // Simply concatenate each page's output - continuous form handles positioning
    const pageContent = generateInvoicePage(invoice, page, items, pageNum, totalPages, isLastPage);
    output += pageContent;
  }

  return output;
}

Deno.serve(async (req) => {
  try {
    // 🔐 AUTHENTICATION & AUTHORIZATION: Validate JWT token and role-based access
    const authHeader = req.headers.get('Authorization');
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const supabase = restClient(supabaseUrl, supabaseServiceKey);

    // Validate user has print access (admin/supervisor only)
    const userProfile = await validatePrintAccess(req, supabase);
    const userName = userProfile.name;
    const userId = userProfile.auth_user_id;

    const { start_inv_no_str, end_inv_no_str, inv_fin_year, limit_count, debug } = await req.json();

    if (!start_inv_no_str || !end_inv_no_str) {
      throw new Error('Missing required parameters: start_inv_no_str and end_inv_no_str');
    }
    // The financial year asked for, or India's current one (1 April to 31 March); used for the query and both answers.
    const finYear = resolveInvoiceFinYear(inv_fin_year, new Date());

    console.log(`print-invoice-preprinted: User ${userName} (${userProfile.role}) printing Invoice range:`, start_inv_no_str, 'to', end_inv_no_str, 'FY:', finYear);
    console.log('Debug mode:', debug || false);

    // Call get_invoice_range_for_print RPC
    const { data: printData, error: rpcError } = await supabase
      .rpc('get_invoice_range_for_print', {
        start_inv_no_str: start_inv_no_str,
        end_inv_no_str: end_inv_no_str,
        inv_fin_year: finYear,
        limit_count: limit_count || 100
      });

    if (rpcError || !printData) {
      console.error('print-invoice-preprinted: RPC error:', rpcError);
      throw new Error(`Failed to fetch Invoice range: ${rpcError?.message || 'No data'}`);
    }

    // RPC returns {data: [...], success: true, message: null} - extract the data array
    const rpcResponse = printData as any;
    const invoiceArray = rpcResponse.data || rpcResponse;
    const results = Array.isArray(invoiceArray) ? invoiceArray : [invoiceArray];

    // Cancelled invoices (migration 134) are not printed: the RPC leaves them out and names them here as skipped with the reason 'cancelled'.
    const skipped = Array.isArray(rpcResponse.skipped) ? rpcResponse.skipped : [];

    if (results.length === 0) {
      throw new Error(skipped.length > 0
        ? `All ${skipped.length} Invoices in the range are cancelled and were skipped (${skipped.map((item: any) => item.inv_no).join(', ')})`
        : 'No Invoices found in specified range');
    }

    console.log('print-invoice-preprinted: Retrieved', results.length, 'Invoices');

    // Generate print content for all Invoices - simple continuous printing
    let printContent = '';

    results.forEach((invoice: any, index: number) => {
      // Simply concatenate each invoice's output - continuous form handles positioning
      const invoiceContent = generatePrePrintedInvoice(sanitizeForPrinter(invoice));
      printContent += invoiceContent;
    });

    console.log('print-invoice-preprinted: Generated content, length:', printContent.length, 'bytes');

    // If debug mode, return the text preview
    if (debug) {
      // Remove control characters for display
      const preview = printContent
        .replace(/\x1B@/g, '[RESET]')
        .replace(/\x1B2/g, '[6LPI]')
        .replace(/\x1BP/g, '[10CPI]')
        .replace(/\x1BM/g, '[12CPI]')
        .replace(/\x0C/g, '[FORM_FEED]\n')
        .replace(/\x1BE/g, '[BOLD_ON]')
        .replace(/\x1BF/g, '[BOLD_OFF]')
        .replace(/\x1B\x0E/g, '[DOUBLE_WIDTH_ON]')
        .replace(/\x14/g, '[DOUBLE_WIDTH_OFF]')
        .replace(/\x1Bw1/g, '[DOUBLE_HEIGHT_ON]')
        .replace(/\x1Bw0/g, '[DOUBLE_HEIGHT_OFF]');

      return new Response(
        JSON.stringify({
          success: true,
          message: 'Debug mode - content preview',
          preview: preview,
          content_length: printContent.length,
          range: {
            start: start_inv_no_str,
            end: end_inv_no_str,
            fin_year: finYear,
            count: results.length
          },
          skipped,
          timestamp: new Date().toISOString()
        }, null, 2),
        {
          headers: { 'Content-Type': 'application/json' },
          status: 200
        }
      );
    }

    // Hand the finished printer bytes to the transport (CUPS or the Windows print bridge, PRINT_TRANSPORT).
    // The bytes are the encoded document and nothing else: the layout and the character encoding above this
    // line are the document's own; the transport neither changes nor translates them.
    const contentBuffer = encodeLatin1(printContent);

    console.log('print-invoice-preprinted: Sending to printer...');

    const result = await submitRawJob({ bytes: contentBuffer, docName: `Invoice-${start_inv_no_str}-to-${end_inv_no_str}`, jobType: 'Invoice' });
    const outcome = jobOutcome(result);
    if (outcome.kind === 'failed') {
      console.error('print-invoice-preprinted: print failed on the', result.transport, 'transport');
      return new Response(
        JSON.stringify(printFailureBody(outcome, null), null, 2),
        { headers: { 'Content-Type': 'application/json' }, status: 502 }
      );
    }
    const jobId = result.jobId;
    const jobUri = result.jobUri ?? '';

    // Log print job to database
    const { data: printJobRecord, error: logError } = await supabase
      .from('print_jobs')
      .insert({
        job_type: 'Invoice',
        document_range_start: start_inv_no_str,
        document_range_end: end_inv_no_str,
        document_count: results.length,
        user_id: userId,
        user_name: userName,
        ...outcome.row,
        content_size: contentBuffer.length,
        printer_name: configuredPrinterName()
      })
      .select()
      .single();

    if (logError) {
      console.error('print-invoice-preprinted: Failed to log print job:', logError);
    }

    if (outcome.kind === 'unconfirmed') {
      return new Response(
        JSON.stringify(printFailureBody(outcome, printJobRecord?.id || null), null, 2),
        {
          headers: { 'Content-Type': 'application/json' },
          status: 502
        }
      );
    }

    // Start background status monitoring (non-blocking)
    if (outcome.kind === 'tracked' && printJobRecord?.id) {
      EdgeRuntime.waitUntil(
        monitorPrintJobStatus(
          printJobRecord.id,
          outcome.row.cups_job_id,
          Deno.env.get('SUPABASE_URL') ?? '',
          Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
        )
      );
      console.log(`print-invoice-preprinted: Background status monitoring started for job ${printJobRecord.id}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Invoice range print job submitted',
        range: {
          start: start_inv_no_str,
          end: end_inv_no_str,
          fin_year: finYear,
          count: results.length
        },
        skipped,
        print_job: {
          print_job_id: printJobRecord?.id || null,
          cups_job_id: jobId,
          job_uri: jobUri,
          transport: result.transport,
          printer: 'LQ1310_RAW (12 CPI, 103 chars width)',
          content_size: contentBuffer.length
        },
        timestamp: new Date().toISOString()
      }, null, 2),
      {
        headers: { 'Content-Type': 'application/json' },
        status: 200
      }
    )
  } catch (error) {
    console.error('print-invoice-preprinted ERROR:', error);

    // Handle auth errors and a refused request (400) with proper status codes
    if (error.status && (error.status === 400 || error.status === 401 || error.status === 403)) {
      return createAuthErrorResponse(error, {}, req);
    }

    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || 'Internal server error',
        timestamp: new Date().toISOString()
      }, null, 2),
      {
        headers: { 'Content-Type': 'application/json' },
        status: 500
      }
    )
  }
})
