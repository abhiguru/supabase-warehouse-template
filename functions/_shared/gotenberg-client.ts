/**
 * Gotenberg Client - HTML to PDF Conversion
 *
 * Professional PDF generation using Gotenberg's Chromium engine.
 * Supports full CSS (Flexbox, Grid, @page), headers/footers with page numbers.
 *
 * @see https://gotenberg.dev/docs/routes
 */

const GOTENBERG_URL = Deno.env.get('GOTENBERG_URL') || 'http://gotenberg:3000';

const A4_WIDTH = 8.27;
const A4_HEIGHT = 11.69;

const CORPORATE_MARGINS = {
  top: 0.39,
  right: 0.55,
  bottom: 0.55,
  left: 0.55,
};

export interface GotenbergOptions {
  paperWidth?: number;
  paperHeight?: number;
  marginTop?: number;
  marginRight?: number;
  marginBottom?: number;
  marginLeft?: number;
  landscape?: boolean;
  printBackground?: boolean;
  scale?: number;
  waitDelay?: string;
  emulatedMediaType?: 'screen' | 'print';
  preferCssPageSize?: boolean;
  headerHtml?: string;
  footerHtml?: string;
}

/**
 * Convert HTML to PDF with optional header/footer
 */
export async function htmlToPdf(
  html: string,
  options: GotenbergOptions = {}
): Promise<Uint8Array> {
  const formData = new FormData();

  formData.append('files', new Blob([html], { type: 'text/html' }), 'index.html');

  if (options.headerHtml) {
    formData.append('files', new Blob([options.headerHtml], { type: 'text/html' }), 'header.html');
  }

  if (options.footerHtml) {
    formData.append('files', new Blob([options.footerHtml], { type: 'text/html' }), 'footer.html');
  }

  formData.append('paperWidth', String(options.paperWidth ?? A4_WIDTH));
  formData.append('paperHeight', String(options.paperHeight ?? A4_HEIGHT));

  const bottomMargin = options.footerHtml
    ? (options.marginBottom ?? 1.0)
    : (options.marginBottom ?? CORPORATE_MARGINS.bottom);

  formData.append('marginTop', String(options.marginTop ?? CORPORATE_MARGINS.top));
  formData.append('marginRight', String(options.marginRight ?? CORPORATE_MARGINS.right));
  formData.append('marginBottom', String(bottomMargin));
  formData.append('marginLeft', String(options.marginLeft ?? CORPORATE_MARGINS.left));

  if (options.landscape) {
    formData.append('landscape', 'true');
  }

  formData.append('printBackground', options.printBackground !== false ? 'true' : 'false');

  if (options.scale) {
    formData.append('scale', String(options.scale));
  }

  if (options.waitDelay) {
    formData.append('waitDelay', options.waitDelay);
  }

  formData.append('emulatedMediaType', options.emulatedMediaType ?? 'print');
  formData.append('preferCssPageSize', options.preferCssPageSize !== false ? 'true' : 'false');

  const response = await fetch(`${GOTENBERG_URL}/forms/chromium/convert/html`, {
    method: 'POST',
    body: formData,
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`Gotenberg error: ${response.status} - ${errorText}`);
    throw new Error(`PDF generation failed: ${response.status}`);
  }

  return new Uint8Array(await response.arrayBuffer());
}

/**
 * Create a professional page footer HTML
 * Uses Gotenberg's special CSS classes for page numbers
 */
export function createFooterHtml(companyName: string, docType: string, docNumber: string): string {
  return `<!DOCTYPE html>
<html>
<head>
  <style>
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; position: relative; }
    .footer-container { height: 0.25in; width: 100%; position: absolute; bottom: 0; left: 0; right: 0; }
    .footer-text-content {
      position: absolute; bottom: 3mm; left: 14mm; right: 14mm;
      display: flex; justify-content: space-between; align-items: center;
      border-top: 2px solid #333; padding-top: 4px;
      font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 8pt;
      -webkit-print-color-adjust: exact; print-color-adjust: exact;
    }
    .footer-left { font-size: 7pt; color: #888; }
    .footer-center { font-size: 7pt; font-weight: 600; color: #333; }
    .footer-right { font-size: 8pt; color: #666; }
    .page-info { font-weight: 500; }
  </style>
</head>
<body>
  <div class="footer-container">
    <div class="footer-text-content">
      <div class="footer-left">${docType} #${docNumber}</div>
      <div class="footer-center">${companyName}</div>
      <div class="footer-right">
        <span class="page-info">Page <span class="pageNumber"></span> of <span class="totalPages"></span></span>
      </div>
    </div>
  </div>
</body>
</html>`;
}

/**
 * Check Gotenberg health
 */
export async function isGotenbergHealthy(): Promise<boolean> {
  try {
    const response = await fetch(`${GOTENBERG_URL}/health`);
    return response.ok;
  } catch {
    return false;
  }
}

export function getGotenbergUrl(): string {
  return GOTENBERG_URL;
}
