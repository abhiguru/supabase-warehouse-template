// The optional letterhead image of the GRN, dispatch, invoice and customer stock PDFs (setup.sh --letterhead-file).
// setup copies the image to <state>/public/letterhead.jpg or letterhead.png and records its name in compose.env
// (LETTERHEAD_FILE); the functions router reads it from the read-only public directory. The rules here are the ones
// setup, doctor and watch share; functions/_shared/letterhead.ts applies the same limits when it reads the file.
export const LETTERHEAD_MAX_BYTES = 2 * 1024 * 1024;
export const LETTERHEAD_NAMES = { jpg: 'letterhead.jpg', png: 'letterhead.png' };
export const LETTERHEAD_NAME_PATTERN = /^letterhead\.(?:jpg|png)$/;

const JPEG = [0xff, 0xd8, 0xff];
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const startsWith = (bytes, signature) => bytes.length >= signature.length && signature.every((byte, index) => bytes[index] === byte);

// 'jpg' or 'png' from the first bytes of a file, else null. Only the signature is read: the renderer decodes the image.
export function letterheadKind(bytes) {
  if (startsWith(bytes, JPEG)) return 'jpg';
  if (startsWith(bytes, PNG)) return 'png';
  return null;
}
