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

// Plain text layout based on React component spec
// Form dimensions: 831px × 633px
// At 12 CPI and 6 LPI: 136 chars × 39 lines per form
// 15-inch continuous paper @ 12 CPI = 136 characters width (matches old Clipper)

const LAYOUT = {
  // Page dimensions (2 slips per page)
  // Paper width: 15 inches @ 12 CPI = 136 characters (15×12 continuous paper)
  PAGE_WIDTH: 136,
  SLIP_HEIGHT: 39,           // Each slip is ~39 lines tall
  SLIPS_PER_PAGE: 2,         // 2 slips per physical page
  SLIP_SPACING: 1,           // Lines between slip 1 and slip 2

  // Header section (using spaces for positioning)
  // Line numbers are 0-indexed within each slip
  HEADER_START_LINE: 0,      // No empty lines at start of page
  GRN_NUMBER_OFFSET: 73,     // Column position for GR No (moved 1 more char right)
  DATE_OFFSET: 85,           // Column position for Date (moved 1 more char right)
  SENDER_OFFSET: 73,         // Column position for Sender (moved 1 more char right)
  CUSTOMER_OFFSET: 73,       // Column position for Customer (moved 1 more char right)
  ADDRESS_OFFSET: 73,        // Column position for Address (moved 1 more char right)

  // Items table
  ITEMS_START_LINE: 16,      // Items start at line 17 (moved down by 3 lines to clear headers)
  ITEMS_PER_SLIP: 6,         // Max 6 items per slip

  // Column widths (matched to pre-printed form measurements in cm)
  // At 12 CPI: 1 char = 0.212 cm
  // Measurements: 0.5cm, 2.9cm, 2.9cm, 1.1cm, 1.7cm, 4.95cm, 4.9cm, 3.1cm
  COL_WIDTHS: {
    SRNO: 2,         // 0.5cm - Item No
    SPACE1: 0,       // No spacing - columns are adjacent
    ITEM_NAME: 13,   // 2.9cm - Item name (reduced by 1 char)
    SPACE2: 0,       // No spacing
    PACKAGING: 10,   // 2.9cm - Packaging type (reduced by 2 more chars)
    SPACE3: 2,       // 2 chars padding before qty column
    QTY: 5,          // 1.1cm - Quantity
    SPACE4: 2,       // 2 chars padding before weight column
    WEIGHT: 8,       // 1.7cm - Weight
    SPACE5: 0,       // No spacing
    RACK: 23,        // 4.95cm - Rack location
    SPACE6: 0,       // No spacing
    PACKAGE_MARK: 23,// 4.9cm - Package marking
    SPACE7: 0,       // No spacing
    GRN_QTY: 15,     // 3.1cm - Our Mark (GRN/Qty)
  },

  // Footer
  TOTAL_LINE: 22,            // Total line after 6 items + spacing
  TOTAL_OFFSET: 27,          // Where total qty appears (5.5cm from start of serial number column + 1 char padding)
  TOTAL_WORDS_OFFSET: 14,    // Where total in words appears (3.0cm from start of serial number column)

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
  const remainder = num % 100000;
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
function generateSlip(grn: any, slipItems: any[], slipNumber: number, isLastSlip: boolean, totalItems: number, debug: boolean = false): string {
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

  // Sender Name (right-aligned at column 65) - NO empty line before
  output += createLine(truncateString(grn.sender_name || '', 30), LAYOUT.SENDER_OFFSET);

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

    // Sr No - left aligned
    line += padRight(String(startItemNumber + idx) + '.', w.SRNO);
    line += ' '.repeat(w.SPACE1);

    // Item Name - center aligned
    line += padCenter(truncateString(item.item_name || '', w.ITEM_NAME), w.ITEM_NAME);
    line += ' '.repeat(w.SPACE2);

    // Packaging - center aligned
    line += padCenter(truncateString(item.packaging || '', w.PACKAGING), w.PACKAGING);
    line += ' '.repeat(w.SPACE3);

    // Qty - right aligned
    line += padLeft(String(item.qty || 0), w.QTY);
    line += ' '.repeat(w.SPACE4);

    // Weight - center aligned
    line += padCenter(String(item.weight || 0), w.WEIGHT);
    line += ' '.repeat(w.SPACE5);

    // Rack - center aligned
    line += padCenter(truncateString(item.rack || '', w.RACK), w.RACK);
    line += ' '.repeat(w.SPACE6);

    // Package Mark - center aligned
    line += padCenter(truncateString(item.package_mark || '', w.PACKAGE_MARK), w.PACKAGE_MARK);
    line += ' '.repeat(w.SPACE7);

    // GRN/Qty - center aligned
    const grnQty = `${grn.gr_no}/${item.qty}`;
    line += padCenter(truncateString(grnQty, w.GRN_QTY), w.GRN_QTY);

    // Don't truncate - the line is 84 chars and should fit
    output += line + '\n';
  });

  // === FILL EMPTY ITEM ROWS ===
  const emptyRowCount = LAYOUT.ITEMS_PER_SLIP - slipItems.length;
  output += emptyLines(emptyRowCount);

  // === TOTALS SECTION ===
  // Show totals on ALL slips (not just the last one)
  output += '\n';

  // Total quantity on first line with continuation message if not last slip
  let totalLine = ' '.repeat(LAYOUT.TOTAL_OFFSET);
  totalLine += padLeft(String(grn.total_qty || 0), 5);

  // Add continuation message if not the last slip
  if (!isLastSlip) {
    totalLine += '  (Continued in next page)';
  }

  output += totalLine + '\n';

  // 1 empty line above total in words
  output += '\n';

  // Total in words
  const qtyWords = truncateString(
    grn.total_qty_in_words || numberToIndianWords(grn.total_qty || 0),
    35
  );
  output += createLine(qtyWords, LAYOUT.TOTAL_WORDS_OFFSET);

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

  // 5 empty lines after note section (adjusted to maintain slip height)
  output += emptyLines(5);

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
  // RAW mode - CUPS will NOT wrap lines, printer gets full ESC/P control

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

    // Generate slip content (39 lines)
    const slipContent = generateSlip(grn, slipItems, slipNum, isLastSlip, items.length, debug);
    output += slipContent;

    // Add spacing between slips (always 1 line between slips)
    // Even after the last slip of a GRN, we add spacing for the next GRN
    output += emptyLines(LAYOUT.SLIP_SPACING);
  }

  // NO FORM FEEDS! Continuous paper flows naturally

  if (debug) {
    output += `[DEBUG: GRN ${grn.gr_no} complete - ${totalSlips} slips printed]\n`;
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
    console.log(`print-grn-preprinted: Init - URL: ${supabaseUrl ? 'set' : 'MISSING'}, Key: ${supabaseServiceKey ? 'set' : 'MISSING'}`)
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

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
      const grnContent = generatePrePrintedGRN(grn, debug);
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
        "requesting-user-name": "grn-preprint",
        "job-name": `GRN-${start_gr_no}-to-${end_gr_no}`,
        "document-format": "application/vnd.cups-raw"  // CUPS RAW - bypasses filters
      },
      data: contentBuffer
    };

    console.log('print-grn-preprinted: Sending to printer...');

    const result: any = await new Promise((resolve, reject) => {
      printer.execute("Print-Job", msg, (err: any, res: any) => {
        if (err) {
          console.error('print-grn-preprinted: IPP error:', err);
          reject(err);
        } else {
          console.log('print-grn-preprinted: IPP success');
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
        job_type: 'GRN',
        document_range_start: start_gr_no,
        document_range_end: end_gr_no,
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
      console.error('print-grn-preprinted: Failed to log print job:', logError);
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
          printer: 'LQ1310_RAW (12 CPI, 136 chars width)',
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
    console.error('print-grn-preprinted ERROR:', error);

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
