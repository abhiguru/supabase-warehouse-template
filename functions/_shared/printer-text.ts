// Text and byte handling for the pre-printed forms on an Epson LQ-1310 (ESC/P2).
//
// The printer reads single bytes. Document text is mapped to printable ASCII first
// (sanitizeForPrinter, applied to the data before layout), and the finished job, text plus
// ESC/P control bytes, is then encoded one byte per character (encodeLatin1). UTF-8 encoding
// would turn a parameter byte such as the 136 in ESC Q 136 into the two bytes C2 88.

// Map data text to printable ASCII: accents are stripped, dashes, quotes and spaces are
// normalised, and anything else becomes '?'. Applied to DATA only; control bytes come later.
export function toPrinterText(s: string): string {
  return s
    .replace(/[\t\r\n]+/g, ' ')
    .normalize('NFKD').replace(/[̀-ͯ]/g, '')
    .replace(/[‐-―−]/g, '-')
    .replace(/[‘’‚′`]/g, "'")
    .replace(/[“”„″]/g, '"')
    .replace(/…/g, '...')
    .replace(/[  -​]/g, ' ')
    .replace(/[^\x20-\x7E]/g, '?');
}

// Apply toPrinterText to every string in a value (arrays and objects are walked).
export function sanitizeForPrinter(v: any): any {
  if (typeof v === 'string') return toPrinterText(v);
  if (Array.isArray(v)) return v.map(sanitizeForPrinter);
  if (v && typeof v === 'object') {
    const out: any = {};
    for (const k of Object.keys(v)) out[k] = sanitizeForPrinter(v[k]);
    return out;
  }
  return v;
}

// One byte per character. Throws on any character above 0xFF, because a silent
// truncation would corrupt the job (sanitizeForPrinter should have removed such characters).
export function encodeLatin1(str: string): Uint8Array {
  const out = new Uint8Array(str.length);
  for (let i = 0; i < str.length; i++) {
    const c = str.charCodeAt(i);
    if (c > 0xFF) {
      throw new Error(`encodeLatin1: character U+${c.toString(16).toUpperCase().padStart(4, '0')} at index ${i} is not a single byte`);
    }
    out[i] = c;
  }
  return out;
}
