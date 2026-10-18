// The form fields functions/_shared/pdf-renderer-client.ts sends for a set of htmlToPdf options, written out again
// here so that the golden-PDF job renders exactly as the functions do: the full default field set (paper size,
// margins with the 1.0 inch bottom margin when a footer is present, printBackground, emulatedMediaType,
// preferCssPageSize), with the case's options.json on top. tests/golden-pdf-fields.test.mjs fails if this and the
// client ever disagree. The header and footer HTML travel as files, not fields.
//
//   node fields.mjs <path to options.json>     one `name=value` per line
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const A4_WIDTH = 8.27;
const A4_HEIGHT = 11.69;
const MARGINS = { top: 0.39, right: 0.55, bottom: 0.55, left: 0.55 };
const FOOTER_BOTTOM_MARGIN = 1.0;

export function fieldsFor(options = {}) {
  const fields = [];
  fields.push(['paperWidth', options.paperWidth ?? A4_WIDTH]);
  fields.push(['paperHeight', options.paperHeight ?? A4_HEIGHT]);
  const bottom = options.footerHtml ? (options.marginBottom ?? FOOTER_BOTTOM_MARGIN) : (options.marginBottom ?? MARGINS.bottom);
  fields.push(['marginTop', options.marginTop ?? MARGINS.top]);
  fields.push(['marginRight', options.marginRight ?? MARGINS.right]);
  fields.push(['marginBottom', bottom]);
  fields.push(['marginLeft', options.marginLeft ?? MARGINS.left]);
  if (options.landscape) fields.push(['landscape', 'true']);
  fields.push(['printBackground', options.printBackground !== false ? 'true' : 'false']);
  if (options.scale) fields.push(['scale', options.scale]);
  if (options.waitDelay) fields.push(['waitDelay', options.waitDelay]);
  fields.push(['emulatedMediaType', options.emulatedMediaType ?? 'print']);
  fields.push(['preferCssPageSize', options.preferCssPageSize !== false ? 'true' : 'false']);
  return fields.map(([key, value]) => [key, String(value)]);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const options = JSON.parse(readFileSync(process.argv[2], 'utf8'));
  for (const [key, value] of fieldsFor(options)) console.log(`${key}=${value}`);
}
