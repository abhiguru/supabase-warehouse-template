import { restClient } from '../_shared/supabase-rest.ts'
import { monitorPrintJobStatus } from '../_shared/print-status-monitor.ts'
import { submitRawJob, jobOutcome, printFailureBody, configuredPrinterName } from '../_shared/print-transport.ts'
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

// Plain text layout for dispatch pre-printed form
// Form dimensions: Same as GRN - 15-inch continuous paper
// At 12 CPI and 6 LPI: 136 chars × 36 lines per 6" slip
// 15-inch continuous paper @ 12 CPI = 136 characters width

// Default layout profile: calibrated for the standard pre-printed dispatch slip (two 6" slips per 12" sheet)
// on an Epson LQ-1310 at 12 CPI / 6 LPI. Adjust these values to suit a different form.
// Columns are character positions; *_180 values are fine vertical moves in 1/180 inch
// (30/180 = one line), taken from the line and given back after it so later lines do not move.
const LAYOUT = {
  // Page dimensions
  PAGE_WIDTH: 136,
  SLIP_INCHES: 6,            // Physical slip = half of a 12" sheet; sent as page length (ESC C NUL 6)

  // Header section
  HEADER_START_LINE: 0,      // No empty lines at start
  DISPATCH_NUMBER_OFFSET: 83,   // Column position for Dispatch No (17.5cm from left @ 12 CPI)
  DATE_OFFSET: 117,             // Column position for Date (unused now, same as dispatch)
  DISPNO_DROP_180: 9,           // Drop dispatch no. by 9/180" (30% of a line). Must be < DATE_DROP_180.
  DATE_DROP_180: 24,            // Extra drop of date below disp no, in 1/180" (30 = one full line). Must be 1..29.
  PARTY_NAME_OFFSET: 15,        // Party's Name offset
  PARTY_ADDRESS_OFFSET: 15,     // Party's Address offset
  DELIVERED_TO_OFFSET: 73,      // Delivered To offset

  // Items table
  ITEMS_START_LINE: 10,      // Items start at line 11
  ITEMS_PER_SLIP: 6,         // Max 6 items per slip

  // Column widths (measurements: 2.9, 1.9, 1.9, 2.3, 1.4, 3.9, 4.4, 2.6 cm)
  // At 12 CPI: 1 cm = 4.72 chars
  COL_WIDTHS: {
    DESCRIPTION: 14,      // 2.9cm - Description of Goods
    SPACE1: 0,
    PACKING: 9,           // 1.9cm - Nature of Packing
    SPACE2: 1,            // 1 char gap: shifts Date of Storage + Receipt No 1 char right
    DATE_STORAGE: 9,      // 1.9cm - Date of Storage
    SPACE3: 0,
    RECEIPT_NO: 11,       // 2.3cm - Storage Receipt No. & Vakal
    SPACE4: 1,            // 1 char before Qty Delivered (was 2; SPACE2 took 1 so Qty onward stays put)
    QTY_DELIVERED: 7,     // 1.4cm - No. of Items Delivered
    SPACE5: 0,
    RACK_ROOM: 18,        // 3.9cm - Rack/Room No.
    SPACE6: 1,            // Party's Mark shifted 1 char right...
    PARTY_MARK: 20,       // 4.4cm - Party's Mark (...and 1 narrower so Our Mark stays put)
    SPACE7: 0,
    OUR_MARK: 12,         // 2.6cm - Our Mark
  },

  // Footer
  TOTAL_LINE: 18,               // Total line after 7 items + spacing
  TOTAL_OFFSET: 44,             // Where total qty appears (moved 1 char left from 45)
  PAGE_NO_GAP: 6,               // Spaces between total qty and "(Page X of Y)"
  TOTAL_DROP_180: 30,           // Extra drop of total-qty line, in 1/180" (30 = one line). Must be 1..30.
  TOTAL_WORDS_OFFSET: 18,       // Where total in words appears
  WORDS_DROP_180: 15,           // Extra drop of total-in-words, in 1/180" (30 = one line). Must be 1..29.
  REMARKS_OFFSET: 73,           // Remarks field offset
  REMARKS_RAISE_180: 15,        // Raise remarks above its normal line, in 1/180". WORDS_DROP_180 + this must be <= 30.
  TRANSPORT_LINE: 19,           // Transport line
  TRANSPORT_OFFSET: 25,         // Transport mode offset
  REGN_NO_OFFSET: 71,           // Registration number offset (15cm from left @ 12 CPI)
  REGN_DROP_180: 15,            // Extra drop of registration line, in 1/180" (30 = one line). Must be 0..29.
  RECEIVER_LINE: 22,            // Receiver name line
  RECEIVER_OFFSET: 18,          // Receiver offset
};

// Helper functions for plain text layout
function padRight(text: string, width: number): string {
  const str = text.substring(0, width);
  return str + ' '.repeat(Math.max(0, width - str.length));
}

function padLeft(text: string, width: number): string {
  const str = text.substring(0, width);
  return ' '.repeat(Math.max(0, width - str.length)) + str;
}

function padCenter(text: string, width: number): string {
  const str = text.substring(0, width);
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
  return `${day}-${month}-${year}`;
}

function truncateString(str: string, maxLength: number): string {
  if (!str) return '';
  return str.length > maxLength ? str.substring(0, maxLength) : str;
}

function numberToIndianWords(num: number): string {
  if (num === 0) return 'Zero only';

  const ones = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine'];
  const tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  const teens = ['Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];

  function convertBelowThousand(n: number): string {
    if (n === 0) return '';
    if (n < 10) return ones[n];
    if (n < 20) return teens[n - 10];
    if (n < 100) return tens[Math.floor(n / 10)] + (n % 10 ? ' ' + ones[n % 10] : '');
    return ones[Math.floor(n / 100)] + ' Hundred' + (n % 100 ? ' ' + convertBelowThousand(n % 100) : '');
  }

  if (num < 1000) return convertBelowThousand(num) + ' only';
  if (num < 100000) {
    const thousands = Math.floor(num / 1000);
    const remainder = num % 1000;
    return convertBelowThousand(thousands) + ' Thousand' +
           (remainder ? ' ' + convertBelowThousand(remainder) : '') + ' only';
  }

  const lakhs = Math.floor(num / 100000);
  let remainder = num % 100000;
  let result = convertBelowThousand(lakhs) + ' Lakh';

  if (remainder >= 1000) {
    const thousands = Math.floor(remainder / 1000);
    result += ' ' + convertBelowThousand(thousands) + ' Thousand';
    remainder = remainder % 1000;
  }

  if (remainder > 0) {
    result += ' ' + convertBelowThousand(remainder);
  }

  return result + ' only';
}

// Generate a single slip (6 items max)
function generateSlip(dispatch: any, slipItems: any[], slipNumber: number, isLastSlip: boolean, totalItems: number, totalSlips: number): string {
  let output = '';

  // === HEADER SECTION ===
  // Start with empty lines to reach header position
  output += emptyLines(LAYOUT.HEADER_START_LINE);

  // Add 2 blank lines before dispatch number
  output += '\n\n';

  // Dispatch No on first line (double-width only for 2x size), dropped DISPNO_DROP_180/180"
  // (taken back from the date's drop below, so the date doesn't move)
  output += ESC + 'J' + String.fromCharCode(LAYOUT.DISPNO_DROP_180);
  output += ' '.repeat(LAYOUT.DISPATCH_NUMBER_OFFSET);
  output += ESCP.DOUBLE_WIDTH_ON + dispatch.disp_no + ESCP.DOUBLE_WIDTH_OFF;
  output += '\n';

  // Fine vertical feed before the date (ESC J n = n/180 inch; 1 line @ 6 LPI = 30/180).
  // Date sits DATE_DROP_180/180" lower than a normal next line; the remainder of the
  // full line is fed after it so the names below stay at their original position.
  output += ESC + 'J' + String.fromCharCode(LAYOUT.DATE_DROP_180 - LAYOUT.DISPNO_DROP_180);

  // Date (same column as dispatch number)
  output += createLine(formatDate(dispatch.disp_date), LAYOUT.DISPATCH_NUMBER_OFFSET);

  // Feed the rest of the borrowed line so names are unaffected
  output += ESC + 'J' + String.fromCharCode(30 - LAYOUT.DATE_DROP_180);

  // Party's Name and Delivered To Name on same line
  const partyName = truncateString(dispatch.customer_name || '', 50);
  const nameLine = ' '.repeat(LAYOUT.PARTY_NAME_OFFSET) + partyName +
                   ' '.repeat(LAYOUT.DELIVERED_TO_OFFSET - LAYOUT.PARTY_NAME_OFFSET - partyName.length) +
                   truncateString(dispatch.customer_name || '', 50);
  output += nameLine + '\n';

  // Party's Address and Delivered To Address on same line
  const partyAddress = dispatch.customer ? truncateString(dispatch.customer.address || '', 50) : '';
  const addressLine = ' '.repeat(LAYOUT.PARTY_ADDRESS_OFFSET) + partyAddress +
                      ' '.repeat(LAYOUT.DELIVERED_TO_OFFSET - LAYOUT.PARTY_ADDRESS_OFFSET - partyAddress.length) +
                      (dispatch.customer ? truncateString(dispatch.customer.address || '', 50) : '');
  output += addressLine + '\n';

  // === ITEMS TABLE ===
  // 5 blank lines between address and items (4 + 1 additional)
  output += '\n\n\n\n\n';

  // Print each item
  const startItemNumber = (slipNumber - 1) * LAYOUT.ITEMS_PER_SLIP + 1;
  slipItems.forEach((item: any, idx: number) => {
    let line = '';
    const w = LAYOUT.COL_WIDTHS;

    // Description of Goods (Item Name) - left aligned at the column start (col 0, where
    // full-width 14-char names already printed) so all rows line up
    line += padRight(truncateString(item.grn_items_item_name || '', w.DESCRIPTION), w.DESCRIPTION);
    line += ' '.repeat(w.SPACE1);

    // All item columns are LEFT aligned so every row lines up (centering shifted rows by
    // value length). Columns whose data can fill the full width start at the column edge;
    // the rest get a 1-char indent.

    // Nature of Packing - left aligned (values up to 9 = full width, so no indent)
    line += padRight(truncateString(item.grn_items_packaging || '', w.PACKING), w.PACKING);
    line += ' '.repeat(w.SPACE2);

    // Date of Storage (GRN Date) - left aligned (always 8 chars)
    line += padRight(formatDate(item.grns_date), w.DATE_STORAGE);
    line += ' '.repeat(w.SPACE3);

    // Storage Receipt No. & Vakal (GRN No/Qty) - LEFT aligned after a 1-char indent so every
    // row lines up on the GRN no. regardless of vakal digits (centering shifted 4-digit
    // vakals 1 char left). The SPACE4 gap is absorbed so an 11-char value still fits.
    const receiptRef = `${item.grns_gr_no}/${item.grn_items_quantity || 0}`;
    const receiptW = w.RECEIPT_NO + w.SPACE4;
    line += padRight(' ' + truncateString(receiptRef, receiptW - 1), receiptW);

    // No. of Items Delivered (Dispatch Quantity) - RIGHT aligned (numbers), units digit at
    // column offset 4 so up to 4 digits fit with a 1-char lead
    line += padRight(padLeft(String(item.disp_quantity || 0), 5), w.QTY_DELIVERED);
    line += ' '.repeat(w.SPACE5);

    // Rack/Room No. - left aligned (values up to 18 = full width, so no indent)
    line += padRight(truncateString(item.grn_items_rack || '', w.RACK_ROOM), w.RACK_ROOM);
    line += ' '.repeat(w.SPACE6);

    // Party's Mark (Package Mark) - left aligned (often longer than the column, so no indent)
    line += padRight(truncateString(item.grn_items_package_mark || '', w.PARTY_MARK), w.PARTY_MARK);
    line += ' '.repeat(w.SPACE7);

    // Our Mark (GRN/Qty) - LEFT aligned after a 1-char indent (same reason as Receipt No.)
    const ourMark = `${item.grns_gr_no}/${item.grn_items_quantity || 0}`;
    line += padRight(' ' + truncateString(ourMark, w.OUR_MARK - 1), w.OUR_MARK);

    output += line + '\n';
  });

  // === FILL EMPTY ITEM ROWS ===
  const emptyRowCount = LAYOUT.ITEMS_PER_SLIP - slipItems.length;
  output += emptyLines(emptyRowCount);

  // === TOTALS SECTION ===
  // Show totals on ALL slips (not just the last one)
  output += '\n';

  // Total quantity line
  let totalLine = ' '.repeat(LAYOUT.TOTAL_OFFSET);
  totalLine += padLeft(String(dispatch.total_qty || 0), 5);

  // Page X of Y on every slip (including single-slip dispatches)
  totalLine += ' '.repeat(LAYOUT.PAGE_NO_GAP) + `(Page ${slipNumber} of ${totalSlips})`;

  // Drop the total line TOTAL_DROP_180/180"; end it with CR + the remainder of the line
  // instead of a full LF so the total-in-words line below stays put.
  output += ESC + 'J' + String.fromCharCode(LAYOUT.TOTAL_DROP_180);
  output += totalLine + CR;
  if (30 - LAYOUT.TOTAL_DROP_180 > 0) output += ESC + 'J' + String.fromCharCode(30 - LAYOUT.TOTAL_DROP_180);

  // 1 blank line before total in words
  output += '\n';

  // Total in words
  const qtyWords = truncateString(
    dispatch.total_qty_in_words || numberToIndianWords(dispatch.total_qty || 0),
    50
  );
  // Drop the words line by WORDS_DROP_180/180" (30 = one line), then end it with a CR and
  // a short feed of the remainder instead of a full LF, so Remarks below doesn't move.
  output += ESC + 'J' + String.fromCharCode(LAYOUT.WORDS_DROP_180);
  output += ' '.repeat(LAYOUT.TOTAL_WORDS_OFFSET) + qtyWords + CR;
  const gapToRemarks = 30 - LAYOUT.WORDS_DROP_180 - LAYOUT.REMARKS_RAISE_180;
  if (gapToRemarks > 0) output += ESC + 'J' + String.fromCharCode(gapToRemarks);

  // Remarks — raised REMARKS_RAISE_180/180" from its normal line; the raise is added
  // back after it so the Registration line below stays put.
  const remarks = truncateString(dispatch.note || '', 50);
  output += ' '.repeat(LAYOUT.REMARKS_OFFSET) + remarks + CR;
  output += ESC + 'J' + String.fromCharCode(30 + LAYOUT.REMARKS_RAISE_180 + LAYOUT.REGN_DROP_180);

  // Registration Number (15cm from left) — dropped REGN_DROP_180/180"; only the remainder
  // of the line is fed after it so the slip height (and next slip's start) is unchanged.
  output += ' '.repeat(LAYOUT.REGN_NO_OFFSET) + truncateString(dispatch.registration || '', 30) + CR;
  output += ESC + 'J' + String.fromCharCode(30 - LAYOUT.REGN_DROP_180);

  // End of slip: form feed to the next 6" perforation (page length set in the job header).
  // Replaces 12 blank lines (same 6" total), but cannot drift, and the FF is what lets the
  // printer's Auto Tear Off advance the perforation to the tear bar after the job and pull
  // it back to top-of-form when the next job arrives.
  output += ESCP.FORM_FEED;

  return output;
}

// Generate dispatch document for pre-printed form using plain text spacing
function generatePrePrintedDispatch(dispatchData: any): string {
  const dispatch = dispatchData;
  const items = dispatch.items || [];
  let output = '';

  // Initialize printer: 12 CPI, 6 LPI for 15-inch paper (RAW mode - no wrapping)
  output += ESCP.RESET;              // Reset printer to defaults
  output += ESCP.ELITE_12CPI;        // 12 characters per inch (136 chars @ 15")
  output += ESCP.LINE_SPACING_1_6;   // 6 lines per inch (standard)
  output += ESC + '\x6C' + '\x00';   // Left margin = 0 (no margin)
  output += ESC + '\x51' + String.fromCharCode(136); // Right margin = 136 chars
  // Page length = one slip (half of the 12" sheet), so FF and Auto Tear Off stop at every
  // 6" perforation, not just at full-sheet boundaries. ESC C NUL n = n inches.
  output += ESC + 'C' + '\x00' + String.fromCharCode(LAYOUT.SLIP_INCHES);

  // Calculate total slips needed
  const totalSlips = Math.ceil(items.length / LAYOUT.ITEMS_PER_SLIP);

  // Generate each slip sequentially (continuous form - no pages!)
  for (let slipNum = 1; slipNum <= totalSlips; slipNum++) {
    const startIdx = (slipNum - 1) * LAYOUT.ITEMS_PER_SLIP;
    const endIdx = Math.min(startIdx + LAYOUT.ITEMS_PER_SLIP, items.length);
    const slipItems = items.slice(startIdx, endIdx);
    const isLastSlip = (slipNum === totalSlips);

    // Generate slip content (one 6" slip, ends with FF)
    const slipContent = generateSlip(dispatch, slipItems, slipNum, isLastSlip, items.length, totalSlips);
    output += slipContent;

  }

  // Each slip ends with FF (see generateSlip) — page length is SLIP_INCHES

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

    const { start_disp_no, end_disp_no } = await req.json();

    if (!start_disp_no || !end_disp_no) {
      throw new Error('Missing required parameters: start_disp_no and end_disp_no');
    }

    console.log(`print-dispatch-preprinted: User ${userName} (${userProfile.role}) printing Dispatch range:`, start_disp_no, 'to', end_disp_no);

    // Call get_dispatch_range_for_print RPC
    const { data: printData, error: rpcError } = await supabase
      .rpc('get_dispatch_range_for_print', {
        start_disp_no: start_disp_no,
        end_disp_no: end_disp_no,
        limit_count: 100
      });

    if (rpcError || !printData) {
      console.error('print-dispatch-preprinted: RPC error:', rpcError);
      throw new Error(`Failed to fetch Dispatch range: ${rpcError?.message || 'No data'}`);
    }

    // RPC returns {data: [...], success: true, message: null} - extract the data array
    const rpcResponse = printData as any;
    const dispatchArray = rpcResponse.data || rpcResponse;
    const results = Array.isArray(dispatchArray) ? dispatchArray : [dispatchArray];

    if (results.length === 0) {
      throw new Error('No Dispatches found in specified range');
    }

    console.log('print-dispatch-preprinted: Retrieved', results.length, 'Dispatches');

    // Generate print content for all Dispatches - simple continuous printing
    let printContent = '';

    results.forEach((dispatch: any, index: number) => {
      // Simply concatenate each Dispatch's output - continuous form handles positioning
      const dispatchContent = generatePrePrintedDispatch(sanitizeForPrinter(dispatch));
      printContent += dispatchContent;
    });

    console.log('print-dispatch-preprinted: Generated content, length:', printContent.length, 'bytes');

    // Hand the finished printer bytes to the transport (CUPS or the Windows print bridge, PRINT_TRANSPORT).
    // The bytes are the encoded document and nothing else: the layout and the character encoding above this
    // line are the document's own; the transport neither changes nor translates them.
    const contentBuffer = encodeLatin1(printContent);

    console.log('print-dispatch-preprinted: Sending to printer...');

    const result = await submitRawJob({ bytes: contentBuffer, docName: `Dispatch-${start_disp_no}-to-${end_disp_no}`, jobType: 'Dispatch' });
    const outcome = jobOutcome(result);
    if (outcome.kind === 'failed') {
      console.error('print-dispatch-preprinted: print failed on the', result.transport, 'transport');
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
        job_type: 'Dispatch',
        document_range_start: start_disp_no,
        document_range_end: end_disp_no,
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
      console.error('print-dispatch-preprinted: Failed to log print job:', logError);
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
      console.log(`print-dispatch-preprinted: Background status monitoring started for job ${printJobRecord.id}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Dispatch range print job submitted',
        range: {
          start: start_disp_no,
          end: end_disp_no,
          count: results.length
        },
        print_job: {
          print_job_id: printJobRecord?.id || null,
          cups_job_id: jobId,
          job_uri: jobUri,
          transport: result.transport,
          printer: 'LQ1310_RAW (12 CPI, 136 chars width)',
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
    console.error('print-dispatch-preprinted ERROR:', error);

    // Handle auth errors with proper status codes
    if (error.status && (error.status === 401 || error.status === 403)) {
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
