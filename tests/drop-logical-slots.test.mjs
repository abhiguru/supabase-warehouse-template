import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const read = path => readFileSync(join(root, path), 'utf8');

// The real script in a scratch checkout whose scripts/compose.sh is a fake: `ps` answers whether db runs, the
// drop statement is recorded, and the listing of slots that are left answers FAKE_LEFT.
function run({ running = true, left = '' } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'drop-slots-'));
  try {
    mkdirSync(join(scratch, 'scripts'));
    copyFileSync(join(root, 'scripts/drop-logical-slots.sh'), join(scratch, 'scripts/drop-logical-slots.sh'));
    writeFileSync(join(scratch, 'scripts/compose.sh'), `#!/usr/bin/env bash
echo "$*" >> "${scratch}/calls"
case "$*" in
  ps*) ${running ? 'echo abc123' : ':'} ;;
  *pg_drop_replication_slot*) echo drop >> "${scratch}/drops" ;;
  *"SELECT slot_name"*) printf '%s' "$FAKE_LEFT" ;;
esac
`);
    const result = spawnSync('bash', [join(scratch, 'scripts/drop-logical-slots.sh')], { encoding: 'utf8', env: { ...process.env, FAKE_LEFT: left } });
    const text = name => { try { return readFileSync(join(scratch, name), 'utf8'); } catch { return ''; } };
    return { ...result, calls: text('calls'), drops: text('drops') };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('db not running: nothing is asked and the step passes', () => {
  const r = run({ running: false });
  assert.equal(r.status, 0, r.stderr);
  assert.doesNotMatch(r.calls, /exec/);
  assert.equal(r.drops, '');
});

test('db running with no slot left: idle logical slots are dropped, then the check passes', () => {
  const r = run();
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.drops, 'drop\n');
  assert.match(r.calls, /slot_type = 'logical' AND NOT active/);
  assert.ok(r.calls.indexOf('pg_drop_replication_slot') < r.calls.indexOf('SELECT slot_name'), 'drop comes before the check');
});

test('a logical slot still in use refuses with its name', () => {
  const r = run({ left: 'supabase_realtime_replication_slot\n' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /still in use: supabase_realtime_replication_slot/);
  assert.match(r.stderr, /nothing was changed/);
});

test('setup.sh and start.sh run the slot step, under the lock, before the db is recreated', () => {
  for (const name of ['setup.sh', 'start.sh']) {
    const code = read(name).split('\n').map((line, index) => [line, index]).filter(([line]) => !line.startsWith('#'));
    const slots = code.find(([line]) => line === 'bash "$ROOT/scripts/drop-logical-slots.sh"');
    assert.ok(slots, `${name}: calls the slot step`);
    const lock = code.find(([line]) => /flock -n 9/.test(line));
    const firstUp = code.find(([line]) => /compose\.sh" up/.test(line));
    assert.ok(lock[1] < slots[1], `${name}: the lock is taken first`);
    assert.ok(slots[1] < firstUp[1], `${name}: slots are dropped before the first compose up`);
  }
  assert.match(read('setup.sh'), /compose\.sh" up -d --remove-orphans --wait --wait-timeout 180 db$/m);
});
