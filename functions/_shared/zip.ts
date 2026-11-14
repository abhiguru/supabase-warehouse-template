// A zip writer for small generated files (WH-158, the accountant pack). Every entry is stored, not compressed (method 0), with its
// name in UTF-8 (flag bit 11), a CRC-32 (IEEE) and the same DOS date and time, taken from `made` on India's clock. No data descriptors,
// no ZIP64, no comment, no extra fields: the same files and the same moment always give the same bytes. Runs under Deno and Node alike
// (only Uint8Array, DataView and TextEncoder).

export interface ZipFile { name: string; bytes: Uint8Array }

const LOCAL_HEADER = 0x04034b50;
const CENTRAL_HEADER = 0x02014b50;
const END_OF_CENTRAL_DIRECTORY = 0x06054b50;
const VERSION = 20; // 2.0, the version that reads a stored entry with UTF-8 names; host 0 (MS-DOS), so no Unix mode bits are claimed
const FLAG_UTF8_NAMES = 0x0800;
const METHOD_STORED = 0;
const MAX_ENTRIES = 0xffff;
const MAX_OFFSET = 0xffffffff;
const INDIA_OFFSET_MS = 330 * 60 * 1000; // UTC+05:30, no daylight saving

let crcTable: Uint32Array | null = null;

function table(): Uint32Array {
  if (crcTable) return crcTable;
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  crcTable = t;
  return t;
}

/** CRC-32 (IEEE 802.3, the zip checksum) of the bytes. */
export function crc32(bytes: Uint8Array): number {
  const t = table();
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = t[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** The DOS time and date fields of a moment on India's clock (years before 1980 are written as 1980-01-01 00:00:00). */
function dosDateTime(made: Date): { time: number; date: number } {
  const ms = made.getTime();
  if (!Number.isFinite(ms)) throw new Error('zipStored: the time of the files is not a valid date');
  const india = new Date(ms + INDIA_OFFSET_MS);
  const year = india.getUTCFullYear();
  if (year < 1980) return { time: 0, date: (1 << 5) | 1 };
  if (year > 2107) throw new Error('zipStored: a zip cannot hold a date after 2107');
  return {
    time: (india.getUTCHours() << 11) | (india.getUTCMinutes() << 5) | (india.getUTCSeconds() >> 1),
    date: ((year - 1980) << 9) | ((india.getUTCMonth() + 1) << 5) | india.getUTCDate(),
  };
}

/** One zip holding the files in the order given, each stored as it is. Throws when the set does not fit a zip without ZIP64. */
export function zipStored(files: ZipFile[], made: Date): Uint8Array {
  if (files.length > MAX_ENTRIES) throw new Error('zipStored: too many files for one zip');
  const { time, date } = dosDateTime(made);
  const encoder = new TextEncoder();
  const seen = new Set<string>();
  const entries = files.map(file => {
    if (typeof file.name !== 'string' || file.name === '' || file.name.startsWith('/') || file.name.includes('\\') ||
      file.name.split('/').includes('..')) throw new Error('zipStored: a file name must be a relative path');
    if (seen.has(file.name)) throw new Error(`zipStored: the name ${file.name} is given twice`);
    seen.add(file.name);
    const name = encoder.encode(file.name);
    if (name.length > 0xffff) throw new Error('zipStored: a file name is too long');
    return { name, bytes: file.bytes, crc: crc32(file.bytes) };
  });

  let localSize = 0;
  for (const e of entries) localSize += 30 + e.name.length + e.bytes.length;
  let centralSize = 0;
  for (const e of entries) centralSize += 46 + e.name.length;
  if (localSize > MAX_OFFSET || centralSize > MAX_OFFSET || localSize + centralSize + 22 > MAX_OFFSET) {
    throw new Error('zipStored: the files are too large for a zip without ZIP64');
  }

  const out = new Uint8Array(localSize + centralSize + 22);
  const view = new DataView(out.buffer);
  const offsets: number[] = [];
  let p = 0;
  for (const e of entries) {
    offsets.push(p);
    view.setUint32(p, LOCAL_HEADER, true);
    view.setUint16(p + 4, VERSION, true);
    view.setUint16(p + 6, FLAG_UTF8_NAMES, true);
    view.setUint16(p + 8, METHOD_STORED, true);
    view.setUint16(p + 10, time, true);
    view.setUint16(p + 12, date, true);
    view.setUint32(p + 14, e.crc, true);
    view.setUint32(p + 18, e.bytes.length, true);
    view.setUint32(p + 22, e.bytes.length, true);
    view.setUint16(p + 26, e.name.length, true);
    view.setUint16(p + 28, 0, true);
    out.set(e.name, p + 30);
    out.set(e.bytes, p + 30 + e.name.length);
    p += 30 + e.name.length + e.bytes.length;
  }
  const centralStart = p;
  entries.forEach((e, i) => {
    view.setUint32(p, CENTRAL_HEADER, true);
    view.setUint16(p + 4, VERSION, true);
    view.setUint16(p + 6, VERSION, true);
    view.setUint16(p + 8, FLAG_UTF8_NAMES, true);
    view.setUint16(p + 10, METHOD_STORED, true);
    view.setUint16(p + 12, time, true);
    view.setUint16(p + 14, date, true);
    view.setUint32(p + 16, e.crc, true);
    view.setUint32(p + 20, e.bytes.length, true);
    view.setUint32(p + 24, e.bytes.length, true);
    view.setUint16(p + 28, e.name.length, true);
    // extra length, comment length, disk number, internal and external attributes: all 0
    view.setUint32(p + 42, offsets[i], true);
    out.set(e.name, p + 46);
    p += 46 + e.name.length;
  });
  view.setUint32(p, END_OF_CENTRAL_DIRECTORY, true);
  view.setUint16(p + 8, entries.length, true);
  view.setUint16(p + 10, entries.length, true);
  view.setUint32(p + 12, p - centralStart, true);
  view.setUint32(p + 16, centralStart, true);
  // disk numbers and comment length: 0
  return out;
}
