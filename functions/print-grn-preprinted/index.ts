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

// Plain text layout based on React component spec
// Form dimensions: 831px × 633px
// At 12 CPI and 6 LPI: 136 chars × 36 lines per 6" slip
// 15-inch continuous paper @ 12 CPI = 136 characters width (matches old Clipper)

// Default layout profile: calibrated for the standard pre-printed GRN slip (two 6" slips per 12" sheet)
// on an Epson LQ-1310 at 12 CPI / 6 LPI. Adjust these values to suit a different form.
// Columns are character positions; *_180 values are fine vertical moves in 1/180 inch
// (30/180 = one line), taken from the line and given back after it so later lines do not move.
const LAYOUT = {
  // Page dimensions (2 slips per page)
  // Paper width: 15 inches @ 12 CPI = 136 characters (15×12 continuous paper)
  PAGE_WIDTH: 136,
  SLIPS_PER_PAGE: 2,         // 2 slips per physical page

  // Header section (using spaces for positioning)
  // Line numbers are 0-indexed within each slip
  HEADER_START_LINE: 0,      // No empty lines at start of page
  GRN_NUMBER_OFFSET: 73,     // Column position for GR No (moved 1 more char right)
  DATE_OFFSET: 85,           // Column position for Date (moved 1 more char right)
  SENDER_OFFSET: 75,         // Column position for Sender / "From"
  SENDER_DROP_180: 9,        // Sender line dropped 9/180" (30% of a line); remainder fed after it
  CUSTOMER_OFFSET: 75,       // Column position for Customer name (address stays at 73)
  ADDRESS_OFFSET: 73,        // Column position for Address (moved 1 more char right)

  // Items table
  ITEMS_START_LINE: 16,      // Items start at line 17 (moved down by 3 lines to clear headers)
  ITEMS_PER_SLIP: 6,         // Max 6 items per slip
  SLIP_INCHES: 6,            // Physical slip = half of a 12" sheet; sent as page length (ESC C NUL 6)

  // Column widths (matched to pre-printed form measurements in cm)
  // At 12 CPI: 1 char = 0.212 cm
  // Measurements: 0.5cm, 2.9cm, 2.9cm, 1.1cm, 1.7cm, 4.95cm, 4.9cm, 3.1cm
  COL_WIDTHS: {
    SRNO: 2,         // 0.5cm - Item No
    SPACE1: 0,       // No spacing - columns are adjacent
    ITEM_NAME: 14,   // 2.9cm - Item name: 1-char indent + 13 chars (took 1 from PACKAGING)
    SPACE2: 2,       // Packaging shifted 2 chars right...
    PACKAGING: 9,    // 2.9cm - Packaging type (data max 9 chars; gave 1 to ITEM_NAME)
    SPACE3: 0,       // ...taken from the gap before qty, so Qty onward stays put
    QTY: 5,          // 1.1cm - Quantity
    SPACE4: 2,       // 2 chars padding before weight column
    WEIGHT: 8,       // 1.7cm - Weight
    SPACE5: 0,       // No spacing
    RACK: 23,        // 4.95cm - Rack location
    SPACE6: 2,       // Party mark shifted 2 chars right; Our Mark column moves too, but
                     // its indent was dropped so its text moves only 1 char right
    PACKAGE_MARK: 23,// 4.9cm - Package marking
    SPACE7: 0,       // No spacing
    GRN_QTY: 15,     // 3.1cm - Our Mark (GRN/Qty)
  },

  // Footer
  TOTAL_LINE: 22,            // Total line after 6 items + spacing
  TOTAL_OFFSET: 27,          // Where total qty appears (5.5cm from start of serial number column + 1 char padding)
  TOTAL_WORDS_OFFSET: 14,    // Where total in words appears (3.0cm from start of serial number column)
  TOTAL_DROP_180: 9,         // Total line dropped 9/180" (0.3 line)
  WORDS_DROP_180: 9,         // Total in words dropped 9/180" (30% of a line); remainder fed after
  PAGE_NO_GAP: 12,           // Spaces between total qty and "(Page X of Y)"

  FOOTER_START_LINE: 32,     // Footer section
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
function generateSlip(grn: any, slipItems: any[], slipNumber: number, isLastSlip: boolean, totalItems: number, debug: boolean = false, totalSlips: number = 1): string {
  let output = '';

  // === HEADER SECTION ===
  // Start with empty lines to reach header position
  output += emptyLines(LAYOUT.HEADER_START_LINE);

  // DEBUG: Add slip markers
  if (debug) {
    output += `[SLIP ${slipNumber} START - GRN: ${grn.gr_no}]\n`;
  }

  // GR No (4x larger) and Date (normal size) on same line
  output += ' '.repeat(LAYOUT.GRN_NUMBER_OFFSET);  // Use full offset for leading spaces
  output += ESCP.DOUBLE_WIDTH_ON + ESCP.DOUBLE_HEIGHT_ON + grn.gr_no + ESCP.DOUBLE_WIDTH_OFF + ESCP.DOUBLE_HEIGHT_OFF;
  // Add spacing to date position (accounting for double-width GRN taking more space)
  const grNoDoubleWidth = grn.gr_no.length * 2;  // Double-width chars take 2x space
  const spacesToDate = LAYOUT.DATE_OFFSET - LAYOUT.GRN_NUMBER_OFFSET - grNoDoubleWidth;
  if (spacesToDate > 0) {
    output += ' '.repeat(spacesToDate);
  }
  output += formatDate(grn.date);
  output += '\n';

  // Sender Name ("From") - dropped SENDER_DROP_180/180", then the rest of the line is fed
  // so everything below stays put
  output += ESC + 'J' + String.fromCharCode(LAYOUT.SENDER_DROP_180);
  output += ' '.repeat(LAYOUT.SENDER_OFFSET) + truncateString(grn.sender_name || '', 30) + CR;
  output += ESC + 'J' + String.fromCharCode(30 - LAYOUT.SENDER_DROP_180);

  // Empty line
  output += '\n';

  // Customer Name (under GR No)
  output += createLine(truncateString(grn.customer_name || '', 30), LAYOUT.CUSTOMER_OFFSET);

  // Customer Address (NO empty line before, address only)
  if (grn.customer) {
    const address = grn.customer.address || '';
    output += createLine(truncateString(address, 30), LAYOUT.ADDRESS_OFFSET);

    // City and Pincode (on next line, NO empty line before)
    const cityPin = [grn.customer.city, grn.customer.pincode].filter(Boolean).join(', ');
    output += createLine(truncateString(cityPin, 30), LAYOUT.ADDRESS_OFFSET);
  } else {
    output += '\n\n';
  }

  // === ITEMS TABLE ===
  // Move to items start line (6 empty lines total)
  output += '\n\n\n\n\n\n';

  // Print each item
  const startItemNumber = (slipNumber - 1) * LAYOUT.ITEMS_PER_SLIP + 1;
  slipItems.forEach((item: any, idx: number) => {
    let line = '';
    const w = LAYOUT.COL_WIDTHS;

    // Text columns are LEFT aligned (1-char indent) so every row lines up — centering
    // shifted rows by value length. Numeric columns (qty, weight) are RIGHT aligned.

    // Sr No - "1."-"9."; from 10 the dot is dropped so it fits the 2-char column
    // (previously "10." was cut to "10" and ran straight into the item name)
    const srNo = startItemNumber + idx;
    line += padRight(srNo < 10 ? `${srNo}.` : String(srNo), w.SRNO);
    line += ' '.repeat(w.SPACE1);

    // Item Name - left aligned, 1-char indent
    line += padRight(' ' + truncateString(item.item_name || '', w.ITEM_NAME - 1), w.ITEM_NAME);
    line += ' '.repeat(w.SPACE2);

    // Packaging - left aligned (data max 9 = full width, so no indent)
    line += padRight(truncateString(item.packaging || '', w.PACKAGING), w.PACKAGING);
    line += ' '.repeat(w.SPACE3);

    // Qty - right aligned
    line += padLeft(String(item.qty || 0), w.QTY);
    line += ' '.repeat(w.SPACE4);

    // Weight - right aligned, units digit at column offset 4
    line += padRight(padLeft(String(item.weight || 0), 5), w.WEIGHT);
    line += ' '.repeat(w.SPACE5);

    // Rack - left aligned, 1-char indent
    line += padRight(' ' + truncateString(item.rack || '', w.RACK - 1), w.RACK);
    line += ' '.repeat(w.SPACE6);

    // Package Mark - left aligned, no indent (marks often fill all 23 chars; the rack
    // column before it always has trailing space)
    line += padRight(truncateString(item.package_mark || '', w.PACKAGE_MARK), w.PACKAGE_MARK);
    line += ' '.repeat(w.SPACE7);

    // GRN/Qty (Our Mark) - left aligned at the column edge (no indent; see SPACE6)
    const grnQty = `${grn.gr_no}/${item.qty}`;
    line += padRight(truncateString(grnQty, w.GRN_QTY), w.GRN_QTY);

    // Don't truncate - the line is 84 chars and should fit
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
  totalLine += padLeft(String(grn.total_qty || 0), 5);

  // Page X of Y on every slip (replaces "(Continued in next page)", same as dispatch)
  totalLine += ' '.repeat(LAYOUT.PAGE_NO_GAP) + `(Page ${slipNumber} of ${totalSlips})`;

  // Drop the total line TOTAL_DROP_180/180"; end with CR + only the remainder of the line
  // so the lines below don't move
  output += ESC + 'J' + String.fromCharCode(LAYOUT.TOTAL_DROP_180);
  output += totalLine + CR;
  if (30 - LAYOUT.TOTAL_DROP_180 > 0) output += ESC + 'J' + String.fromCharCode(30 - LAYOUT.TOTAL_DROP_180);

  // 1 empty line above total in words
  output += '\n';

  // Total in words - dropped WORDS_DROP_180/180", remainder fed after
  const qtyWords = truncateString(
    grn.total_qty_in_words || numberToIndianWords(grn.total_qty || 0),
    35
  );
  output += ESC + 'J' + String.fromCharCode(LAYOUT.WORDS_DROP_180);
  output += ' '.repeat(LAYOUT.TOTAL_WORDS_OFFSET) + qtyWords + CR;
  output += ESC + 'J' + String.fromCharCode(30 - LAYOUT.WORDS_DROP_180);

  // === FOOTER SECTION ===
  // Show footer on ALL slips (not just the last one)

  // 1 empty line after totals in words
  output += '\n';

  // Supervisor name (7.8cm from start of serial number column)
  const supervisorOffset = 37;  // 7.8cm = 37 chars @ 12 CPI
  output += createLine(truncateString(grn.supervisor_name || 'GCS', 20), supervisorOffset);

  // Empty line
  output += '\n';

  // Vehicle registration (2cm from start of serial number column)
  const registrationOffset = 9;  // 2cm = 9.4 chars @ 12 CPI, rounded to 9
  if (grn.registration) {
    output += createLine(grn.registration, registrationOffset);
  } else {
    output += '\n';
  }

  // 2 empty lines after registration
  output += '\n\n';

  // Note section (quarter page width = 34 chars, max 2 lines)
  const noteWidth = 34;  // Quarter of 136 chars page width
  if (isLastSlip && grn.note) {
    const noteText = grn.note || '';
    const line1 = truncateString(noteText, noteWidth);
    const remaining = noteText.length > noteWidth ? noteText.substring(noteWidth) : '';
    const line2 = truncateString(remaining, noteWidth);

    output += createLine(line1, registrationOffset);
    if (line2) {
      output += createLine(line2, registrationOffset);
    } else {
      output += '\n';  // Empty line if no second line
    }
  } else {
    output += '\n\n';  // 2 empty lines if no note
  }

  // End of slip: form feed to the next 6" perforation (page length set in the job header).
  // Replaces the 5 trailing blank lines + 1 slip-spacing line (same 6" total) but cannot
  // drift, and lets the printer's Auto Tear Off stop at every half-sheet perforation.
  output += ESCP.FORM_FEED;

  return output;
}

// Generate GRN document for pre-printed form using plain text spacing
function generatePrePrintedGRN(grnData: any, debug: boolean = false): string {
  const grn = grnData;
  const items = grn.trl || [];
  let output = '';

  // Initialize printer: 12 CPI, 6 LPI for 15-inch paper (RAW mode - no wrapping)
  output += ESCP.RESET;              // Reset printer to defaults
  output += ESCP.ELITE_12CPI;        // 12 characters per inch (136 chars @ 15")
  output += ESCP.LINE_SPACING_1_6;   // 6 lines per inch (standard)
  output += ESC + '\x6C' + '\x00';   // Left margin = 0 (no margin)
  output += ESC + '\x51' + String.fromCharCode(136); // Right margin = 136 chars
  // Page length = one slip (half of the 12" sheet) so FF / Auto Tear Off stop at every
  // 6" perforation. ESC C NUL n = n inches.
  output += ESC + 'C' + '\x00' + String.fromCharCode(LAYOUT.SLIP_INCHES);

  if (debug) {
    output += `[DEBUG: GRN ${grn.gr_no} - ${items.length} items = ${Math.ceil(items.length / LAYOUT.ITEMS_PER_SLIP)} slips]\n`;
  }

  // Calculate total slips needed
  const totalSlips = Math.ceil(items.length / LAYOUT.ITEMS_PER_SLIP);

  // Generate each slip sequentially (continuous form - no pages!)
  for (let slipNum = 1; slipNum <= totalSlips; slipNum++) {
    const startIdx = (slipNum - 1) * LAYOUT.ITEMS_PER_SLIP;
    const endIdx = Math.min(startIdx + LAYOUT.ITEMS_PER_SLIP, items.length);
    const slipItems = items.slice(startIdx, endIdx);
    const isLastSlip = (slipNum === totalSlips);

    // Generate slip content (one 6" slip, ends with FF)
    const slipContent = generateSlip(grn, slipItems, slipNum, isLastSlip, items.length, debug, totalSlips);
    output += slipContent;
    // (no inter-slip spacing line: each slip ends with FF to the next 6" perforation)
  }

  // Each slip ends with FF (see generateSlip) — page length is SLIP_INCHES

  if (debug) {
    output += `[DEBUG: GRN ${grn.gr_no} complete - ${totalSlips} slips printed]\n`;
  }

  return output;
}

Deno.serve(async (req) => {
  try {
    // 🔐 AUTHENTICATION & AUTHORIZATION: Validate JWT token and role-based access
    const authHeader = req.headers.get('Authorization');
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    console.log(`print-grn-preprinted: Init - URL: ${supabaseUrl ? 'set' : 'MISSING'}, Key: ${supabaseServiceKey ? 'set' : 'MISSING'}`)
    const supabase = restClient(supabaseUrl, supabaseServiceKey);

    // Validate user has print access (admin/supervisor only)
    const userProfile = await validatePrintAccess(req, supabase);
    const userName = userProfile.name;
    const userId = userProfile.auth_user_id;

    const { start_gr_no, end_gr_no, debug } = await req.json();

    if (!start_gr_no || !end_gr_no) {
      throw new Error('Missing required parameters: start_gr_no and end_gr_no');
    }

    console.log(`print-grn-preprinted: User ${userName} (${userProfile.role}) printing GRN range:`, start_gr_no, 'to', end_gr_no);
    console.log('Debug mode:', debug || false);

    // Call get_grn_range_for_print RPC
    const { data: printData, error: rpcError } = await supabase
      .rpc('get_grn_range_for_print', {
        start_gr_no: start_gr_no,
        end_gr_no: end_gr_no,
        limit_count: 100
      });

    if (rpcError || !printData) {
      console.error('print-grn-preprinted: RPC error:', rpcError);
      throw new Error(`Failed to fetch GRN range: ${rpcError?.message || 'No data'}`);
    }

    // RPC returns {data: [...], success: true, message: null} - extract the data array
    const rpcResponse = printData as any;
    const grnArray = rpcResponse.data || rpcResponse;
    const results = Array.isArray(grnArray) ? grnArray : [grnArray];

    if (results.length === 0) {
      throw new Error('No GRNs found in specified range');
    }

    console.log('print-grn-preprinted: Retrieved', results.length, 'GRNs');

    // Generate print content for all GRNs - simple continuous printing
    let printContent = '';

    results.forEach((grn: any, index: number) => {
      // Simply concatenate each GRN's output - continuous form handles positioning
      const grnContent = generatePrePrintedGRN(sanitizeForPrinter(grn), debug);
      printContent += grnContent;
    });

    console.log('print-grn-preprinted: Generated content, length:', printContent.length, 'bytes');

    // If debug mode, return the text preview
    if (debug) {
      // Remove control characters for display
      const preview = printContent
        .replace(/\x1B@/g, '[RESET]')
        .replace(/\x1B2/g, '[6LPI]')
        .replace(/\x1BP/g, '[10CPI]')
        .replace(/\x0C/g, '[FORM_FEED]\n')
        .replace(/\x1BE/g, '[BOLD_ON]')
        .replace(/\x1BF/g, '[BOLD_OFF]');

      return new Response(
        JSON.stringify({
          success: true,
          message: 'Debug mode - content preview',
          preview: preview,
          content_length: printContent.length,
          range: {
            start: start_gr_no,
            end: end_gr_no,
            count: results.length
          },
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

    console.log('print-grn-preprinted: Sending to printer...');

    const result = await submitRawJob({ bytes: contentBuffer, docName: `GRN-${start_gr_no}-to-${end_gr_no}`, jobType: 'GRN' });
    const outcome = jobOutcome(result);
    if (outcome.kind === 'failed') {
      console.error('print-grn-preprinted: print failed on the', result.transport, 'transport');
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
        job_type: 'GRN',
        document_range_start: start_gr_no,
        document_range_end: end_gr_no,
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
      console.error('print-grn-preprinted: Failed to log print job:', logError);
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
      console.log(`print-grn-preprinted: Background status monitoring started for job ${printJobRecord.id}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'GRN range print job submitted',
        range: {
          start: start_gr_no,
          end: end_gr_no,
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
    console.error('print-grn-preprinted ERROR:', error);

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
