import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { MIN_VHDX_DRIVE_FREE_BYTES, driveSpace, isWsl, isWslHost, mountTypeOf, statfsWithTimeout, vhdxDrive, wslDriveVerdict } from '../scripts/wsl-host.mjs';

const GiB = 1024 ** 3;

test('isWsl reads the kernel release under the given /proc and matches "microsoft" in any letter case', () => {
  const read = text => path => { assert.equal(path, '/p/sys/kernel/osrelease'); return text; };
  assert.equal(isWsl(read('5.15.153.1-microsoft-standard-WSL2\n'), '/p'), true);
  assert.equal(isWsl(read('4.4.0-19041-Microsoft\n'), '/p'), true);
  assert.equal(isWsl(read('6.8.0-45-generic\n'), '/p'), false);
  assert.equal(isWsl(() => null), false);
  assert.equal(isWsl(() => { throw new Error('ENOENT'); }), false);
  assert.equal(isWsl(path => (path === '/proc/sys/kernel/osrelease' ? 'x-microsoft-x' : null)), true, 'default /proc');
});

test('isWslHost reads WAREHOUSE_OSRELEASE_FILE when set, else /proc', () => {
  const read = path => ({ '/f': 'x-microsoft-x', '/proc/sys/kernel/osrelease': '6.8.0' })[path] ?? null;
  assert.equal(isWslHost({ WAREHOUSE_OSRELEASE_FILE: '/f' }, read), true);
  assert.equal(isWslHost({}, read), false);
  assert.equal(isWslHost({ WAREHOUSE_OSRELEASE_FILE: '/f' }, () => { throw new Error('x'); }), false);
});

test('vhdxDrive: WAREHOUSE_VHDX_DRIVE, then VHDX_DRIVE of compose.env, then /mnt/c; empty and relative values are ignored', () => {
  assert.equal(vhdxDrive({}), '/mnt/c');
  assert.equal(vhdxDrive({ WAREHOUSE_VHDX_DRIVE: '' }, { VHDX_DRIVE: '' }), '/mnt/c');
  assert.equal(vhdxDrive({ WAREHOUSE_VHDX_DRIVE: '/mnt/d' }), '/mnt/d');
  assert.equal(vhdxDrive({}, { VHDX_DRIVE: '/mnt/e' }), '/mnt/e');
  assert.equal(vhdxDrive({ WAREHOUSE_VHDX_DRIVE: '/mnt/d' }, { VHDX_DRIVE: '/mnt/e' }), '/mnt/d');
  assert.equal(vhdxDrive({ WAREHOUSE_VHDX_DRIVE: 'd' }, { VHDX_DRIVE: 'e' }), '/mnt/c');
});

test('mountTypeOf: the longest mount point that holds the path decides, escaped spaces included', () => {
  const mounts = '/dev/sdc / ext4 rw 0 0\nC:\\134 /mnt/c 9p rw 0 0\nX /mnt/my\\040disk drvfs rw 0 0\ntmpfs /mnt/c/tmp tmpfs rw 0 0\n';
  assert.equal(mountTypeOf('/mnt/c', mounts), '9p');
  assert.equal(mountTypeOf('/mnt/c/Users/x', mounts), '9p');
  assert.equal(mountTypeOf('/mnt/c/tmp/y', mounts), 'tmpfs');
  assert.equal(mountTypeOf('/mnt/cc', mounts), 'ext4', 'a sibling name is not inside /mnt/c');
  assert.equal(mountTypeOf('/mnt/my disk', mounts), 'drvfs');
  assert.equal(mountTypeOf('/mnt/d', '/dev/sdc / ext4 rw 0 0\n'), 'ext4');
  assert.equal(mountTypeOf('/mnt/d', ''), null);
});

test('driveSpace accepts only a 9p, drvfs or virtiofs mount, and reports free bytes and percent', () => {
  const mount = type => ({ readText: () => `/dev/sdc / ext4 rw 0 0\nC:\\134 /mnt/c ${type} rw 0 0\n`, statfs: () => ({ bavail: 25, bsize: 1024, blocks: 100 }) });
  for (const type of ['9p', 'drvfs', 'virtiofs']) assert.deepEqual(driveSpace('/mnt/c', mount(type)), { free: 25600, percent: 25 }, type);
  assert.throws(() => driveSpace('/mnt/c', mount('ext4')), /not a Windows drive mount \(filesystem type ext4\)/);
  assert.throws(() => driveSpace('/mnt/d', mount('9p')), /not a Windows drive mount \(filesystem type ext4\)/, 'the mount holding /mnt/d is /');
  assert.throws(() => driveSpace('/mnt/c', { ...mount('9p'), statfs: () => ({ bavail: 'x', bsize: 1, blocks: 1 }) }), /unexpected free-space figures/);
});

test('statfsWithTimeout reads a real path, fails on a missing one, and gives up on a command that never answers', () => {
  const real = statfsWithTimeout('/');
  assert.ok(real.bsize > 0 && real.blocks > 0 && real.bavail >= 0);
  assert.throws(() => statfsWithTimeout('/no/such/path'), /./);
  const dir = mkdtempSync(join(tmpdir(), 'wsl-host-'));
  try {
    const hang = join(dir, 'stat');
    writeFileSync(hang, '#!/bin/sh\nexec sleep 30\n');
    chmodSync(hang, 0o755);
    const started = Date.now();
    assert.throws(() => statfsWithTimeout('/', 500, hang), /timed out after 0\.5 s/);
    assert.ok(Date.now() - started < 10000);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('wslDriveVerdict: the floor is 20 GiB; a new installation gets an error, a running one a warning', () => {
  assert.equal(MIN_VHDX_DRIVE_FREE_BYTES, 20 * GiB);
  for (const newInstall of [true, false]) assert.deepEqual(wslDriveVerdict(20 * GiB, { newInstall }), {});
  assert.deepEqual(Object.keys(wslDriveVerdict(20 * GiB - 1, { newInstall: true })), ['error']);
  assert.deepEqual(Object.keys(wslDriveVerdict(20 * GiB - 1, { newInstall: false })), ['warning']);
  assert.deepEqual(Object.keys(wslDriveVerdict(0)), ['warning'], 'a start is the default');
  assert.match(wslDriveVerdict(3 * GiB, { newInstall: true, drive: '/mnt/d' }).error, /\(\/mnt\/d\); 3\.0 GiB is free/);
});
