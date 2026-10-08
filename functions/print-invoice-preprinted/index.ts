import { serve } from "https://deno.land/std@0.192.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3'
import { monitorPrintJobStatus } from '../_shared/print-status-monitor.ts'
import { validatePrintAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// ESC/P Control Codes for Epson LQ 1310
const ESC = '\x1B';
const LF = '\x0A';
const FF = '\x0C';
const CR = '\x0D';

const ESCP = {
  RESET: ESC + '@',
  // Font selection
  PICA_10CPI: ESC + 'P',           // 10 characters per inch (default)
  ELITE_12CPI: ESC + 'M',          // 12 characters per inch
  CONDENSED_17CPI: ESC + '\x0F',   // 17 characters per inch
  CONDENSED_OFF: ESC + '\x12',

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
  DOUBLE_WIDTH_OFF: ESC + '\x14',     // DC4 - Double-width off
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

const LAYOUT = {
  // Page dimensions
  PAGE_WIDTH: 91,            // 23.2cm @ 10 CPI = 91.3 chars
  FORM_HEIGHT: 47,           // 20cm @ 6 LPI = 47.2 lines
  ITEMS_PER_PAGE: 20,        // Max 20 items per invoice page (increased from 16)

  // Header section (positions scaled for 10 CPI)
  HEADER_START_LINE: 0,      // No empty lines at start
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
    SPACE7: 0,            // Stays at 0 - no space between DURATION and WEIGHT
    WEIGHT: 6,            // Weight column with 2 decimal precision (e.g., 5.00)
    SPACE8: 2,            // Back to 2 - moves RATE 1 char left
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

// Generate a single invoice page (14 items max)
function generateInvoicePage(
  invoice: any,
  pageItems: any[],
  cumulativeItems: any[],  // All items from page 1 to current page for cumulative totals
  pageNum: number,
  totalPages: number,
  isLastPage: boolean
): string {
  let output = '';

  // === HEADER SECTION ===
  // No blank lines before header

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
  output += createLine(fullAddress, LAYOUT.ADDRESS_OFFSET);

  // === ITEMS TABLE ===
  // Add 2 more blank lines after customer address (3 total before items)
  output += '\n\n\n';

  // Print each item - GRN header row followed by dispatch detail rows
  let previousGrnItemId = null;
  let printedLines = 0;
  pageItems.forEach((item: any, index: number) => {
    const w = LAYOUT.COL_WIDTHS;
    const currentGrnItemId = item.grn_items_id;
    const isFirstInGroup = currentGrnItemId !== previousGrnItemId;

    // If first in group, print GRN header row first
    if (isFirstInGroup) {
      let headerLine = '';

      // GRN Header: Item Name, Packaging, Inward Qty, GRN Date, (empty dispatch cols), GRN No
      headerLine += padRight(truncateString(item.grn_items_item_name || '', w.ITEM_NAME), w.ITEM_NAME);
      headerLine += ' '.repeat(w.SPACE1);

      const packingDetails = item.grn_items_packaging || item.grn_items_package_mark || '';
      headerLine += padCenter(truncateString(packingDetails, w.PACKAGING), w.PACKAGING);
      headerLine += ' '.repeat(w.SPACE2);

      headerLine += padLeft(String(item.grn_items_quantity || 0), w.INW_QTY);
      headerLine += ' '.repeat(w.SPACE3);

      headerLine += padCenter(formatDate(item.grns_date), w.DEPOSIT_DATE);
      headerLine += ' '.repeat(w.SPACE4);

      // Empty dispatch columns on header row
      headerLine += ' '.repeat(w.OUT_QTY);
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
      printedLines++;
    }

    previousGrnItemId = currentGrnItemId;

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

    detailLine += padLeft(String(item.duration || ''), w.DURATION);
    detailLine += ' '.repeat(w.SPACE7);

    // Weight - show on every dispatch row
    const weight = item.grn_items_weight ? parseFloat(item.grn_items_weight).toFixed(2) : '';
    detailLine += padLeft(truncateString(weight, w.WEIGHT), w.WEIGHT);
    detailLine += ' '.repeat(w.SPACE8);

    detailLine += padLeft(formatCurrency(item.charge || 0), w.RATE);
    detailLine += ' '.repeat(w.SPACE9);

    const duration = parseFloat(item.duration) || 0;
    const dispatchQty = item.dispatches_items_disp_qty || 0;
    const rate = item.charge || 0;
    const calculatedAmount = duration * dispatchQty * rate;
    detailLine += padLeft(formatCurrency(calculatedAmount), w.AMOUNT);
    detailLine += ' '.repeat(w.SPACE10);

    // Empty GRN No column
    detailLine += ' '.repeat(w.GRN_NO);

    output += detailLine + '\n';
    printedLines++;
  });

  // === FILL EMPTY ITEM ROWS ===
  // Account for extra header rows (printedLines includes both header + detail rows)
  const emptyRowCount = Math.max(0, LAYOUT.ITEMS_PER_PAGE - printedLines);
  output += emptyLines(emptyRowCount);

  // === TOTALS SECTION ===
  // No blank lines before totals (removed to make room for 4 more item lines)

  // === CUMULATIVE TOTALS (from page 1 to current page) ===

  // Calculate cumulative unique GRN qty total (sum only first item in each grn_items_id group)
  const uniqueGrnQtyTotal = cumulativeItems.reduce((total: number, item: any, index: number) => {
    if (index === 0 || item.grn_items_id !== cumulativeItems[index - 1].grn_items_id) {
      return total + (item.grn_items_quantity || 0);
    }
    return total;
  }, 0);

  // Calculate cumulative total dispatch qty (sum ALL rows from page 1 to current page)
  const totalDispQty = cumulativeItems.reduce((sum: number, item: any) => sum + (item.dispatches_items_disp_qty || 0), 0);

  // Calculate cumulative total amount (sum all item amounts from page 1 to current page)
  const totalAmount = cumulativeItems.reduce((sum: number, item: any) => {
    const duration = parseFloat(item.duration) || 0;
    const dispatchQty = item.dispatches_items_disp_qty || 0;
    const rate = item.charge || 0;
    return sum + (duration * dispatchQty * rate);
  }, 0);

  // Totals row (always show on every page)
  // Calculate exact position of INW_QTY column: ITEM_NAME + SPACE1 + PACKAGING + SPACE2
  const inwQtyColStart = LAYOUT.COL_WIDTHS.ITEM_NAME + LAYOUT.COL_WIDTHS.SPACE1 +
                         LAYOUT.COL_WIDTHS.PACKAGING + LAYOUT.COL_WIDTHS.SPACE2;
  let totalsLine = ' '.repeat(inwQtyColStart);
  totalsLine += padLeft(String(uniqueGrnQtyTotal), LAYOUT.COL_WIDTHS.INW_QTY);

  // Calculate exact position of OUT_QTY column
  const outQtyColStart = inwQtyColStart + LAYOUT.COL_WIDTHS.INW_QTY + LAYOUT.COL_WIDTHS.SPACE3 +
                         LAYOUT.COL_WIDTHS.DEPOSIT_DATE + LAYOUT.COL_WIDTHS.SPACE4;
  totalsLine += ' '.repeat(outQtyColStart - totalsLine.length);
  totalsLine += padLeft(String(totalDispQty), LAYOUT.COL_WIDTHS.OUT_QTY);

  // Add continuation message if not last page
  if (!isLastPage) {
    // Calculate exact position of AMOUNT column
    const amountColEnd = inwQtyColStart + LAYOUT.COL_WIDTHS.INW_QTY + LAYOUT.COL_WIDTHS.SPACE3 +
                         LAYOUT.COL_WIDTHS.DEPOSIT_DATE + LAYOUT.COL_WIDTHS.SPACE4 +
                         LAYOUT.COL_WIDTHS.OUT_QTY + LAYOUT.COL_WIDTHS.SPACE5 +
                         LAYOUT.COL_WIDTHS.DELIVERY_DATE + LAYOUT.COL_WIDTHS.SPACE6 +
                         LAYOUT.COL_WIDTHS.DURATION + LAYOUT.COL_WIDTHS.SPACE7 +
                         LAYOUT.COL_WIDTHS.WEIGHT + LAYOUT.COL_WIDTHS.SPACE8 +
                         LAYOUT.COL_WIDTHS.RATE + LAYOUT.COL_WIDTHS.SPACE9 +
                         LAYOUT.COL_WIDTHS.AMOUNT;
    totalsLine += ' '.repeat(amountColEnd - totalsLine.length - LAYOUT.COL_WIDTHS.AMOUNT);
    totalsLine += padLeft(formatCurrency(totalAmount), LAYOUT.COL_WIDTHS.AMOUNT);
    totalsLine += '   Continued...';
  } else {
    // On last page, show amount total in amount column
    const amountColEnd = inwQtyColStart + LAYOUT.COL_WIDTHS.INW_QTY + LAYOUT.COL_WIDTHS.SPACE3 +
                         LAYOUT.COL_WIDTHS.DEPOSIT_DATE + LAYOUT.COL_WIDTHS.SPACE4 +
                         LAYOUT.COL_WIDTHS.OUT_QTY + LAYOUT.COL_WIDTHS.SPACE5 +
                         LAYOUT.COL_WIDTHS.DELIVERY_DATE + LAYOUT.COL_WIDTHS.SPACE6 +
                         LAYOUT.COL_WIDTHS.DURATION + LAYOUT.COL_WIDTHS.SPACE7 +
                         LAYOUT.COL_WIDTHS.WEIGHT + LAYOUT.COL_WIDTHS.SPACE8 +
                         LAYOUT.COL_WIDTHS.RATE + LAYOUT.COL_WIDTHS.SPACE9 +
                         LAYOUT.COL_WIDTHS.AMOUNT;
    totalsLine += ' '.repeat(amountColEnd - totalsLine.length - LAYOUT.COL_WIDTHS.AMOUNT);
    totalsLine += padLeft(formatCurrency(totalAmount), LAYOUT.COL_WIDTHS.AMOUNT);
  }

  output += totalsLine + '\n';

  // === FOOTER SECTION (fixed height = 23 lines @ 6 LPI for continuous form alignment) ===
  if (isLastPage) {
    // Last page: Print actual tax and grand total
    // Spacing before tax section - 2 blank lines
    output += '\n\n';

    // Tax breakdown (SGST and CGST)
    const sgst = (invoice.tax_amount || 0) / 2;
    const cgst = (invoice.tax_amount || 0) / 2;

    // Calculate positions: 3cm from left = 11.82 chars @ 10 CPI
    const taxLeftOffset = 12; // 3cm from left
    // Amount column position (where item amounts appear)
    const amountColEnd = inwQtyColStart + LAYOUT.COL_WIDTHS.INW_QTY + LAYOUT.COL_WIDTHS.SPACE3 +
                         LAYOUT.COL_WIDTHS.DEPOSIT_DATE + LAYOUT.COL_WIDTHS.SPACE4 +
                         LAYOUT.COL_WIDTHS.OUT_QTY + LAYOUT.COL_WIDTHS.SPACE5 +
                         LAYOUT.COL_WIDTHS.DELIVERY_DATE + LAYOUT.COL_WIDTHS.SPACE6 +
                         LAYOUT.COL_WIDTHS.DURATION + LAYOUT.COL_WIDTHS.SPACE7 +
                         LAYOUT.COL_WIDTHS.WEIGHT + LAYOUT.COL_WIDTHS.SPACE8 +
                         LAYOUT.COL_WIDTHS.RATE + LAYOUT.COL_WIDTHS.SPACE9 +
                         LAYOUT.COL_WIDTHS.AMOUNT;

    // SGST line - SGST at 3cm, Labour under amount column
    let sgstLine = ' '.repeat(taxLeftOffset);
    sgstLine += padLeft(formatCurrency(sgst), 10);
    const labourPos = amountColEnd - 10; // Right align in amount column
    sgstLine += ' '.repeat(labourPos - sgstLine.length);
    sgstLine += padLeft(formatCurrency(invoice.labour || 0), 10);
    output += sgstLine + '\n';

    // CGST line - CGST at 3cm, Tax Total under amount column
    let cgstLine = ' '.repeat(taxLeftOffset);
    cgstLine += padLeft(formatCurrency(cgst), 10);
    cgstLine += ' '.repeat(labourPos - cgstLine.length);
    cgstLine += padLeft(formatCurrency(invoice.tax_amount || 0), 10);
    output += cgstLine + '\n';

    // Grand total line - just value, no label or "Rs.", aligned under amount column
    let grandTotalLine = ' '.repeat(labourPos);
    grandTotalLine += padLeft(formatCurrency(invoice.total || 0), 10);
    output += grandTotalLine + '\n';

    // Total in words on next line - 12 chars from left margin
    const totalWordsOffset = 12;
    let amountInWords = invoice.inwords || '';
    // Remove "Rupees " if it exists at the start, ensure "only" at end
    amountInWords = amountInWords.replace(/^Rupees\s+/i, '');
    if (!amountInWords.toLowerCase().endsWith('only')) {
      amountInWords = amountInWords + ' only';
    }
    const truncatedWords = truncateString(amountInWords, LAYOUT.PAGE_WIDTH - totalWordsOffset - 5);
    output += createLine(truncatedWords, totalWordsOffset);

    // Additional spacing to reach total footer height (16 more blank lines = 2 + 8 + 1 + 1)
    output += '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n';
  } else {
    // Non-last page: Empty lines to maintain same footer height (22 lines total)
    // 2 blank + SGST + CGST + Grand total + Total in words + 16 blank = 22 lines
    output += '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n';
  }

  return output;
}

// Generate complete invoice document for pre-printed form
function generatePrePrintedInvoice(invoiceData: any): string {
  const invoice = invoiceData;
  const rawItems = invoice.trl || []; // trl array contains denormalized items

  // Group items by grn_items_id (keep all items, just sort them by group)
  const groupedItemsMap = new Map<string, any[]>();
  rawItems.forEach((item: any) => {
    const grnItemId = item.grn_items_id;
    if (!groupedItemsMap.has(grnItemId)) {
      groupedItemsMap.set(grnItemId, []);
    }
    groupedItemsMap.get(grnItemId)!.push(item);
  });

  // Flatten back to array (groups stay together)
  const items: any[] = [];
  groupedItemsMap.forEach((groupItems) => {
    items.push(...groupItems);
  });

  let output = '';

  // Initialize printer: 10 CPI (larger font), 6 LPI for 23.2cm paper (RAW mode)
  output += ESCP.RESET;              // Reset printer to defaults
  output += ESCP.PICA_10CPI;         // 10 characters per inch (91 chars @ 23.2cm) - LARGER FONT
  output += ESCP.LINE_SPACING_1_6;   // 6 lines per inch (standard)
  output += ESC + '\x6C' + '\x00';   // Left margin = 0 (no margin)
  output += ESC + '\x51' + String.fromCharCode(110); // Right margin = 110 chars for 10 CPI
  // RAW mode - CUPS will NOT wrap lines, printer gets full ESC/P control

  // Calculate total pages needed
  const totalPages = Math.ceil(items.length / LAYOUT.ITEMS_PER_PAGE);

  // Generate each page - simply concatenate like GRN/Dispatch (continuous form handles positioning)
  for (let pageNum = 1; pageNum <= totalPages; pageNum++) {
    const startIdx = (pageNum - 1) * LAYOUT.ITEMS_PER_PAGE;
    const endIdx = Math.min(startIdx + LAYOUT.ITEMS_PER_PAGE, items.length);
    const pageItems = items.slice(startIdx, endIdx);
    const cumulativeItems = items.slice(0, endIdx);  // All items from page 1 to current page
    const isLastPage = (pageNum === totalPages);

    // Simply concatenate each page's output - continuous form handles positioning
    const pageContent = generateInvoicePage(invoice, pageItems, cumulativeItems, pageNum, totalPages, isLastPage);
    output += pageContent;
  }

  return output;
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // 🔐 AUTHENTICATION & AUTHORIZATION: Validate JWT token and role-based access
    const authHeader = req.headers.get('Authorization');
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Validate user has print access (admin/supervisor only)
    const userProfile = await validatePrintAccess(req, supabase);
    const userName = userProfile.name;
    const userId = userProfile.auth_user_id;

    const { start_inv_no_str, end_inv_no_str, inv_fin_year, limit_count, debug } = await req.json();

    if (!start_inv_no_str || !end_inv_no_str) {
      throw new Error('Missing required parameters: start_inv_no_str and end_inv_no_str');
    }

    console.log(`print-invoice-preprinted: User ${userName} (${userProfile.role}) printing Invoice range:`, start_inv_no_str, 'to', end_inv_no_str, 'FY:', inv_fin_year);
    console.log('Debug mode:', debug || false);

    // Call get_invoice_range_for_print RPC
    const { data: printData, error: rpcError } = await supabase
      .rpc('get_invoice_range_for_print', {
        start_inv_no_str: start_inv_no_str,
        end_inv_no_str: end_inv_no_str,
        inv_fin_year: inv_fin_year || new Date().getFullYear(),
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

    if (results.length === 0) {
      throw new Error('No Invoices found in specified range');
    }

    console.log('print-invoice-preprinted: Retrieved', results.length, 'Invoices');

    // Generate print content for all Invoices - simple continuous printing
    let printContent = '';

    results.forEach((invoice: any, index: number) => {
      // Simply concatenate each invoice's output - continuous form handles positioning
      const invoiceContent = generatePrePrintedInvoice(invoice);
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
        .replace(/\x1B\x14/g, '[DOUBLE_WIDTH_OFF]')
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
            fin_year: inv_fin_year || new Date().getFullYear(),
            count: results.length
          },
          timestamp: new Date().toISOString()
        }, null, 2),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200
        }
      );
    }

    // Import IPP and send to printer in RAW mode
    const ipp = await import("npm:ipp");
    const printer = ipp.Printer("http://cups:631/printers/LQ1310_RAW");

    const Buffer = (await import("node:buffer")).Buffer;
    const contentBuffer = Buffer.from(printContent);

    const msg = {
      "operation-attributes-tag": {
        "requesting-user-name": "invoice-preprint",
        "job-name": `Invoice-${start_inv_no_str}-to-${end_inv_no_str}`,
        "document-format": "application/vnd.cups-raw"  // CUPS RAW - bypasses filters
      },
      data: contentBuffer
    };

    console.log('print-invoice-preprinted: Sending to printer...');

    const result: any = await new Promise((resolve, reject) => {
      printer.execute("Print-Job", msg, (err: any, res: any) => {
        if (err) {
          console.error('print-invoice-preprinted: IPP error:', err);
          reject(err);
        } else {
          console.log('print-invoice-preprinted: IPP success');
          resolve(res);
        }
      });
    });

    const jobId = result?.["job-attributes-tag"]?.["job-id"] || 'unknown';
    const jobUri = result?.["job-attributes-tag"]?.["job-uri"] || '';

    // Log print job to database
    const { data: printJobRecord, error: logError } = await supabase
      .from('print_jobs')
      .insert({
        cups_job_id: typeof jobId === 'number' ? jobId : null,
        job_type: 'Invoice',
        document_range_start: start_inv_no_str,
        document_range_end: end_inv_no_str,
        document_count: results.length,
        user_id: userId,
        user_name: userName,
        status: 'printing',
        content_size: contentBuffer.length,
        printer_name: 'LQ1310_RAW'
      })
      .select()
      .single();

    if (logError) {
      console.error('print-invoice-preprinted: Failed to log print job:', logError);
    }

    // Start background status monitoring (non-blocking)
    if (printJobRecord?.id && typeof jobId === 'number') {
      EdgeRuntime.waitUntil(
        monitorPrintJobStatus(
          printJobRecord.id,
          jobId,
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
          fin_year: inv_fin_year || new Date().getFullYear(),
          count: results.length
        },
        print_job: {
          print_job_id: printJobRecord?.id || null,
          cups_job_id: jobId,
          job_uri: jobUri,
          printer: 'LQ1310_RAW (12 CPI, 103 chars width)',
          content_size: contentBuffer.length
        },
        timestamp: new Date().toISOString()
      }, null, 2),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 200
      }
    )
  } catch (error) {
    console.error('print-invoice-preprinted ERROR:', error);

    // Handle auth errors with proper status codes
    if (error.status && (error.status === 401 || error.status === 403)) {
      return createAuthErrorResponse(error, corsHeaders);
    }

    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || 'Internal server error',
        timestamp: new Date().toISOString()
      }, null, 2),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500
      }
    )
  }
})
