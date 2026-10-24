// The optional letterhead image of the GRN, dispatch, invoice and customer stock PDFs (setup.sh --letterhead-file;
// docs/PDF_GENERATION.md, "Letterhead"). The rules a worker needs: the data URI the router hands it as LETTERHEAD_DATA_URI
// and the exact shape documentHtml accepts. The router's file reader is functions/main/letterhead-reader.ts, like the central key
// file: the router reads the file, the worker gets the result (and tests/worker-env.test.mjs keeps LETTERHEAD_FILE out of the worker lists).
// scripts/letterhead.mjs holds the limits for setup, doctor and watch; keep the two in step.
export const LETTERHEAD_MAX_BYTES = 2 * 1024 * 1024;
const URI = /^data:image\/(?:jpeg|png);base64,[A-Za-z0-9+/]+=*$/;

/** True for a data URI of exactly the shape this module builds. Everything else is ignored by documentHtml. */
export const isLetterheadUri = (value: unknown): value is string => typeof value === 'string' && URI.test(value);

const startsWith = (bytes: Uint8Array, signature: number[]) => bytes.length >= signature.length && signature.every((byte, index) => bytes[index] === byte);

/** The data URI for the bytes of a JPEG or PNG of at most 2 MiB, else null. */
export function letterheadDataUri(bytes: Uint8Array): string | null {
  if (bytes.length === 0 || bytes.length > LETTERHEAD_MAX_BYTES) return null;
  const type = startsWith(bytes, [0xff, 0xd8, 0xff]) ? 'jpeg'
    : startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) ? 'png' : null;
  if (!type) return null;
  let binary = '';
  for (let index = 0; index < bytes.length; index += 0x8000) binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return `data:image/${type};base64,${btoa(binary)}`;
}
