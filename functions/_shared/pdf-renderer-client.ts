/**
 * PDF renderer client - HTML to PDF conversion
 *
 * Calls the `pdf-renderer` service (docker/pdf-renderer: chrome-headless-shell driven by
 * puppeteer-core). Supports full CSS (Flexbox, Grid, @page), headers/footers with page numbers.
 * API: POST /render (multipart) and GET /health; see docker/pdf-renderer/README.md.
 */

import { escapeHtml } from './document-html.ts';

const PDF_RENDERER_URL = Deno.env.get('PDF_RENDERER_URL') || 'http://pdf-renderer:3000';

const A4_WIDTH = 8.27;
const A4_HEIGHT = 11.69;

const CORPORATE_MARGINS = {
  top: 0.39,
  right: 0.55,
  bottom: 0.55,
  left: 0.55,
};

export interface PdfRendererOptions {
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
  options: PdfRendererOptions = {}
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

  const response = await fetch(`${PDF_RENDERER_URL}/render`, {
    method: 'POST',
    body: formData,
    signal: AbortSignal.timeout(30000),
    redirect: 'error',
  });

  if (!response.ok) {
    let detail = '';
    try {
      // The renderer answers errors as JSON {error, code}; log at most 2 KB of it.
      const reader = response.body?.getReader();
      const chunks: Uint8Array[] = [];
      let total = 0;
      while (reader && total < 2048) {
        const { done, value } = await reader.read();
        if (done || !value) break;
        chunks.push(value);
        total += value.length;
      }
      await reader?.cancel().catch(() => {});
      const bytes = new Uint8Array(Math.min(total, 2048));
      let offset = 0;
      for (const chunk of chunks) {
        const part = chunk.subarray(0, bytes.length - offset);
        bytes.set(part, offset);
        offset += part.length;
        if (offset >= bytes.length) break;
      }
      detail = ` ${new TextDecoder().decode(bytes)}`;
    } catch {
      // the status alone is enough
    }
    console.error(`PDF renderer returned HTTP ${response.status}${detail}`);
    throw new Error(`PDF generation failed: ${response.status}`);
  }

  return new Uint8Array(await response.arrayBuffer());
}

/**
 * Create a professional page footer HTML
 * Uses the renderer's special CSS classes (pageNumber, totalPages) for page numbers.
 * An empty docNumber prints the document type alone (a report has no number);
 * `note` adds a second line on the left of every page, e.g. that rows were left out.
 */
export function createFooterHtml(companyName: string, docType: string, docNumber: string, note = ''): string {
  const left = docNumber ? `${escapeHtml(docType)} #${escapeHtml(docNumber)}` : escapeHtml(docType);
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
      font-family: 'Helvetica Neue', Helvetica, Arial, 'Noto Sans Gujarati', sans-serif; font-size: 8pt;
      -webkit-print-color-adjust: exact; print-color-adjust: exact;
    }
    .footer-left { font-size: 7pt; color: #888; }
    .footer-center { font-size: 7pt; font-weight: 600; color: #333; }
    .footer-right { font-size: 8pt; color: #666; }
    .page-info { font-weight: 500; }
    .footer-note { display: block; color: #8a4b00; font-size: 7pt; }
  </style>
</head>
<body>
  <div class="footer-container">
    <div class="footer-text-content">
      <div class="footer-left">${left}${note ? `<span class="footer-note">${escapeHtml(note)}</span>` : ''}</div>
      <div class="footer-center">${escapeHtml(companyName)}</div>
      <div class="footer-right">
        <span class="page-info">Page <span class="pageNumber"></span> of <span class="totalPages"></span></span>
      </div>
    </div>
  </div>
</body>
</html>`;
}

/**
 * Check renderer health
 */
export async function isPdfRendererHealthy(): Promise<boolean> {
  try {
    const response = await fetch(`${PDF_RENDERER_URL}/health`);
    return response.ok;
  } catch {
    return false;
  }
}

export function getPdfRendererUrl(): string {
  return PDF_RENDERER_URL;
}
