import test from 'node:test';
import assert from 'node:assert/strict';
import { MIN_VHDX_DRIVE_FREE_BYTES, isWsl, vhdxDrive, wslDriveVerdict } from '../scripts/wsl-host.mjs';

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

test('vhdxDrive is /mnt/c unless WAREHOUSE_VHDX_DRIVE says otherwise (an empty value is none)', () => {
  assert.equal(vhdxDrive({}), '/mnt/c');
  assert.equal(vhdxDrive({ WAREHOUSE_VHDX_DRIVE: '' }), '/mnt/c');
  assert.equal(vhdxDrive({ WAREHOUSE_VHDX_DRIVE: '/mnt/d' }), '/mnt/d');
});

test('wslDriveVerdict: the floor is 20 GiB; a new installation gets an error, a running one a warning', () => {
  assert.equal(MIN_VHDX_DRIVE_FREE_BYTES, 20 * GiB);
  for (const newInstall of [true, false]) assert.deepEqual(wslDriveVerdict(20 * GiB, { newInstall }), {});
  assert.deepEqual(Object.keys(wslDriveVerdict(20 * GiB - 1, { newInstall: true })), ['error']);
  assert.deepEqual(Object.keys(wslDriveVerdict(20 * GiB - 1, { newInstall: false })), ['warning']);
  assert.deepEqual(Object.keys(wslDriveVerdict(0)), ['warning'], 'a start is the default');
  assert.match(wslDriveVerdict(3 * GiB, { newInstall: true, drive: '/mnt/d' }).error, /\(\/mnt\/d\); 3\.0 GiB is free/);
});
