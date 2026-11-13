// WH-158 criterion 9: functions/_shared/zip.ts, zipStored(files: {name: string; bytes: Uint8Array}[], made: Date): Uint8Array (contract D5):
// method 0 (stored), flag bit 11 (UTF-8 names), CRC-32 (IEEE), DOS time of `made` in India time, no ZIP64, no comment.
// Written BEFORE the build: fails today because the module does not exist.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { crc32 } from 'node:zlib';
import { zipStored } from '../functions/_shared/zip.ts';

const enc = new TextEncoder();
const files = [
  { name: 'README.txt', bytes: enc.encode('Accountant pack\r\nline two\r\n') },
  { name: 'sales-register.csv', bytes: enc.encode('﻿a,b\r\n1,2\r\n') },
  { name: 'ગુરુ.txt', bytes: enc.encode('નામ') },
  { name: 'empty.txt', bytes: new Uint8Array(0) },
];
// 2026-10-31 20:00:10 UTC = 2026-11-01 01:30:10 in India.
const made = new Date(Date.UTC(2026, 9, 31, 20, 0, 10));
const zip = zipStored(files, made);
const view = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);

function entries() {
  // The end of central directory: signature 0x06054b50, no comment, so it is the last 22 bytes.
  const eocd = zip.length - 22;
  assert.equal(view.getUint32(eocd, true), 0x06054b50, 'the end of central directory is the last 22 bytes (no comment)');
  assert.equal(view.getUint16(eocd + 20, true), 0, 'no zip comment');
  const count = view.getUint16(eocd + 10, true);
  assert.equal(view.getUint16(eocd + 8, true), count);
  let p = view.getUint32(eocd + 16, true);
  const out = [];
  for (let i = 0; i < count; i++) {
    assert.equal(view.getUint32(p, true), 0x02014b50, 'central directory entry');
    const e = {
      flags: view.getUint16(p + 8, true), method: view.getUint16(p + 10, true), time: view.getUint16(p + 12, true), date: view.getUint16(p + 14, true),
      crc: view.getUint32(p + 16, true), csize: view.getUint32(p + 20, true), size: view.getUint32(p + 24, true),
      nameLen: view.getUint16(p + 28, true), extraLen: view.getUint16(p + 30, true), commentLen: view.getUint16(p + 32, true), offset: view.getUint32(p + 42, true),
    };
    e.name = new TextDecoder().decode(zip.subarray(p + 46, p + 46 + e.nameLen));
    out.push(e);
    p += 46 + e.nameLen + e.extraLen + e.commentLen;
  }
  return out;
}

test('[crit 9] zipStored: every file stored (method 0), names in UTF-8 (flag bit 11), CRC-32 and sizes right, in the order given', () => {
  const list = entries();
  assert.deepEqual(list.map(e => e.name), files.map(f => f.name));
  list.forEach((e, i) => {
    assert.equal(e.method, 0, 'stored');
    assert.equal(e.flags & 0x0800, 0x0800, 'UTF-8 names');
    assert.equal(e.flags & 0x0008, 0, 'no data descriptor');
    assert.equal(e.size, files[i].bytes.length);
    assert.equal(e.csize, files[i].bytes.length);
    assert.equal(e.crc, crc32(files[i].bytes) >>> 0);
    // The local header repeats the name and the sizes, and the data follows it.
    assert.equal(view.getUint32(e.offset, true), 0x04034b50);
    assert.equal(view.getUint32(e.offset + 14, true), e.crc);
    assert.equal(view.getUint32(e.offset + 18, true), e.csize);
    assert.equal(view.getUint32(e.offset + 22, true), e.size);
    const start = e.offset + 30 + view.getUint16(e.offset + 26, true) + view.getUint16(e.offset + 28, true);
    assert.deepEqual([...zip.subarray(start, start + e.size)], [...files[i].bytes]);
  });
});

test('[crit 9] zipStored: the DOS date and time are the pack\'s moment on India\'s clock (here 01/11/2026 01:30:10), no ZIP64', () => {
  const expectedTime = (1 << 11) | (30 << 5) | (10 >> 1);
  const expectedDate = ((2026 - 1980) << 9) | (11 << 5) | 1;
  for (const e of entries()) { assert.equal(e.time, expectedTime); assert.equal(e.date, expectedDate); }
  assert.ok(!zip.some((_, i) => i + 3 < zip.length && view.getUint32(i, true) === 0x06064b50), 'no ZIP64 end record');
  const other = zipStored([{ name: 'a.txt', bytes: enc.encode('x') }], new Date(Date.UTC(2026, 9, 31, 5, 30, 0)));
  const v = new DataView(other.buffer, other.byteOffset, other.byteLength);
  const c = v.getUint32(other.length - 22 + 16, true);
  assert.equal(v.getUint16(c + 12, true), (11 << 11), '05:30 UTC is 11:00:00 in India');
  assert.equal(v.getUint16(c + 14, true), ((2026 - 1980) << 9) | (10 << 5) | 31);
});

test('[crit 9] zipStored: read back by unzip (-l lists the names, -t passes, -p returns the bytes)', t => {
  if (spawnSync('unzip', ['-v']).error) { t.skip('unzip is not installed'); return; }
  const dir = mkdtempSync(join(tmpdir(), 'wh158-zip-'));
  try {
    const path = join(dir, 'pack.zip');
    writeFileSync(path, zip);
    const list = spawnSync('unzip', ['-l', path], { encoding: 'utf8' });
    assert.equal(list.status, 0, list.stderr);
    assert.match(list.stdout, /README\.txt/);
    assert.match(list.stdout, /sales-register\.csv/);
    assert.match(list.stdout, /empty\.txt/);
    assert.match(list.stdout, /4 files/);
    const test = spawnSync('unzip', ['-t', path], { encoding: 'utf8' });
    assert.equal(test.status, 0, test.stdout + test.stderr);
    assert.match(test.stdout, /No errors detected/);
    const bytes = spawnSync('unzip', ['-p', path, 'README.txt']);
    assert.equal(bytes.stdout.toString('utf8'), 'Accountant pack\r\nline two\r\n');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
