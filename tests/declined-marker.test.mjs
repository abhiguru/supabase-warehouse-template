// scripts/declined-marker.mjs: a recorded decision counts only as a regular file the running user owns, mode 0600, with exactly the sentence.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { declinedMarker, OFFHOST_DECLINED_SENTENCE, OFFHOST_DECLINED_NAME } from '../scripts/declined-marker.mjs';

const make = () => { const dir = mkdtempSync(join(tmpdir(), 'warehouse-declined-')); mkdirSync(join(dir, 'config')); return dir; };

test('the sentence for the off-host copy is the documented one', () => {
  assert.equal(OFFHOST_DECLINED_SENTENCE, 'We have decided not to keep a copy of the backups outside this host.');
  assert.equal(OFFHOST_DECLINED_NAME, 'offhost-copy-declined');
});

test('declinedMarker: true only for a 0600 regular file of this user holding exactly the sentence (surrounding whitespace ignored)', () => {
  const state = make();
  try {
    const file = join(state, 'config', 'x-declined');
    assert.equal(declinedMarker(state, 'x-declined', 'Yes.'), false, 'absent');
    writeFileSync(file, 'Yes.\n', { mode: 0o600 });
    assert.equal(declinedMarker(state, 'x-declined', 'Yes.'), true);
    writeFileSync(file, '  Yes.  \n\n'); chmodSync(file, 0o600);
    assert.equal(declinedMarker(state, 'x-declined', 'Yes.'), true, 'trimmed text');
    for (const text of ['yes.', 'Yes', 'Yes. And more.', 'No. Yes.', '']) {
      writeFileSync(file, `${text}\n`); chmodSync(file, 0o600);
      assert.equal(declinedMarker(state, 'x-declined', 'Yes.'), false, JSON.stringify(text));
    }
    writeFileSync(file, 'Yes.\n');
    for (const mode of [0o644, 0o640, 0o660, 0o400, 0o700, 0o666]) { chmodSync(file, mode); assert.equal(declinedMarker(state, 'x-declined', 'Yes.'), false, mode.toString(8)); }
  } finally { rmSync(state, { recursive: true, force: true }); }
});

test('declinedMarker: a link (to a good file too), a directory, and another owner are refused', () => {
  const state = make();
  try {
    const real = join(state, 'real'); writeFileSync(real, 'Yes.\n', { mode: 0o600 });
    symlinkSync(real, join(state, 'config', 'x-declined'));
    assert.equal(declinedMarker(state, 'x-declined', 'Yes.'), false, 'symlink');
    mkdirSync(join(state, 'config', 'dir-declined'), { mode: 0o600 });
    assert.equal(declinedMarker(state, 'dir-declined', 'Yes.'), false, 'directory');
    writeFileSync(join(state, 'config', 'ok'), 'Yes.\n', { mode: 0o600 });
    assert.equal(declinedMarker(state, 'ok', 'Yes.'), true);
    const getuid = process.getuid; process.getuid = () => getuid.call(process) + 1;
    try { assert.equal(declinedMarker(state, 'ok', 'Yes.'), false, 'owned by someone else'); } finally { process.getuid = getuid; }
  } finally { rmSync(state, { recursive: true, force: true }); }
});
