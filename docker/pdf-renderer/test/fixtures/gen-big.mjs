// node gen-big.mjs <out.html> [images=22] : a fictional document of incompressible PNG images, about 2 MB of HTML per
// image and about as much PDF. 22 images give a PDF of roughly 30 MB from a body of roughly 40 MB.
import fs from 'node:fs';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

const [out, count = '22'] = process.argv.slice(2);
const W = 700;
const H = 700;

function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(body) >>> 0);
  return Buffer.concat([length, body, crc]);
}

function png() {
  const raw = Buffer.alloc((W * 3 + 1) * H);
  for (let y = 0; y < H; y += 1) crypto.randomFillSync(raw.subarray(y * (W * 3 + 1) + 1, (y + 1) * (W * 3 + 1)));
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 0 })), chunk('IEND', Buffer.alloc(0))]);
}

let html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Big fictional document</title><style>img{width:90mm;display:block;margin:2mm 0;break-inside:avoid}</style></head><body><h1>Big fictional document</h1>';
for (let i = 0; i < Number(count); i += 1) html += `<img alt="img ${i}" src="data:image/png;base64,${png().toString('base64')}">`;
html += '</body></html>';
fs.writeFileSync(out, html);
