// scripts/backup-archive.sh: the one-file archive of a backup that the USB drive holds. A v6 backup keeps its stored files as
// a tree with hard links to earlier backups and extended attributes; the archive must carry all of it on a drive that has
// neither, in an order that lets the restore check read the small files without the photos.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, statSync, linkSync, utimesSync, chmodSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeBackup, makeState, scriptRoot, composeEnv, backupKey, signBackup, manifestOf, filesUnder, xattrTool, xattrSkip } from './backup-test-helpers.mjs';

const A = 'stub/stub/documents/a.pdf/v1';
const B = 'stub/stub/documents/b.pdf/v1';
const NAME = 'warehouse-20260101T000000Z';

function fixture(options = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-archive-'));
  const state = makeState(scratch);
  const root = scriptRoot(scratch);
  const drive = join(scratch, 'drive'); mkdirSync(drive);
  const backups = join(state, 'backups'); mkdirSync(backups);
  const dir = makeBackup(join(backups, NAME), { env: composeEnv(state), format: 'warehouse-backup-v6', objects: ['documents/a.pdf/v1', 'documents/b.pdf/v1'], files: [A, B], ...options });
  // Runs shell with the helpers loaded and the backup key of the state.
  const sh = (script, ...args) => spawnSync('bash', ['-c', `set -euo pipefail; source "$1"; source "$2"; backup_key_load "$3"; shift 3; ${script}`, 'sh',
    join(root, 'scripts/backup-key.sh'), join(root, 'scripts/backup-archive.sh'), join(state, 'config/backup.key'), ...args], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_BACKUP_KEY_FILE: join(state, 'config/backup.key') } });
  const write = (out, encrypt = '') => sh('backup_archive_write "$@"', dir, out, ...(encrypt ? [encrypt] : []));
  const extract = (archive, mode = '') => {
    const dest = mkdtempSync(join(scratch, 'x-'));
    const result = sh('backup_archive_extract "$@"', archive, dest, ...(mode ? [mode] : []));
    return { dest, result };
  };
  return { scratch, state, root, drive, dir, sh, write, extract, cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}
// Rewrites the list and the signature of a backup after a test changed its files (the manifest, a tunnel folder, ...).
function resign(dir, listed) {
  const sums = spawnSync('sha256sum', listed, { cwd: dir, encoding: 'utf8' });
  assert.equal(sums.status, 0, sums.stderr);
  writeFileSync(join(dir, 'SHA256SUMS'), sums.stdout);
  signBackup(dir);
}
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const names = text => text.split('\n').filter(Boolean).map(line => line.split(/\s+/).slice(5).join(' '));
const authenticate = (f, dir) => f.sh('backup_authenticate "$1" false', dir);

test('an archive of a v6 backup holds the small files first, the manifest, then the whole tree, as a plain tar without gzip', () => {
  const f = fixture();
  try {
    const out = join(f.drive, `${NAME}.tar`);
    const result = f.write(out);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), sha(out), 'the SHA-256 of the written bytes is printed');
    const bytes = readFileSync(out);
    assert.notDeepEqual([...bytes.subarray(0, 2)], [0x1f, 0x8b], 'not gzip');
    assert.equal(bytes.subarray(257, 262).toString(), 'ustar');
    const list = names(spawnSync('tar', ['-tvf', out], { encoding: 'utf8' }).stdout);
    const at = name => list.indexOf(`${NAME}/${name}`);
    assert.equal(list[0], `${NAME}/`);
    assert.ok(at('SHA256SUMS') === 1 && at('SHA256SUMS.hmac') === 2, 'the signed list and its signature come first');
    for (const small of ['database.dump', 'integrity.txt', 'metadata.txt', 'compose.env', 'instance.json', 'roles.txt', 'storage_objects.txt']) assert.ok(at(small) > 2 && at(small) < at('storage.manifest'), `${small} before the manifest`);
    const tree = list.findIndex(name => name.startsWith(`${NAME}/storage/`));
    assert.ok(at('storage.manifest') < tree, 'the manifest before the tree');
    assert.deepEqual(list.slice(tree).filter(name => !name.endsWith('/')).sort(), [`${NAME}/storage/${A}`, `${NAME}/storage/${B}`].sort(), 'and the tree last');
    assert.ok(list.slice(tree).every(name => name.startsWith(`${NAME}/storage`)), 'nothing but the tree after it');
  } finally { f.cleanup(); }
});

test('writing then extracting a v6 backup gives back the same signed backup: files, modes, modification times and hard-linked photos as separate files', () => {
  const f = fixture();
  try {
    const tree = join(f.dir, 'storage');
    // b is a hard link to a, as a photo that did not change since the previous backup is.
    rmSync(join(tree, B)); linkSync(join(tree, A), join(tree, B));
    chmodSync(join(tree, A), 0o644);
    utimesSync(join(tree, A), new Date('2025-03-04T05:06:07Z'), new Date('2025-03-04T05:06:07Z'));
    writeFileSync(join(f.dir, 'storage.manifest'), manifestOf(tree));
    resign(f.dir, ['storage.manifest', 'database.dump', 'integrity.txt', 'metadata.txt', 'compose.env', 'instance.json', 'roles.txt', 'storage_objects.txt']);
    assert.equal(statSync(join(tree, A)).nlink, 2);
    for (const encrypt of ['', 'encrypt']) {
      const out = join(f.drive, `${NAME}.tar${encrypt ? '.enc' : ''}`);
      assert.equal(f.write(out, encrypt).status, 0);
      if (encrypt) assert.match(readFileSync(out, 'latin1'), /^Salted__/);
      const { dest, result } = f.extract(out);
      assert.equal(result.status, 0, result.stderr);
      const back = join(dest, NAME);
      assert.deepEqual(filesUnder(back), filesUnder(f.dir), `${encrypt || 'plain'}: the same files`);
      for (const path of filesUnder(f.dir)) assert.equal(sha(join(back, path)), sha(join(f.dir, path)), `${encrypt || 'plain'}: ${path}`);
      assert.equal(statSync(join(back, 'storage', A)).mode & 0o777, 0o644);
      assert.equal(statSync(join(back, 'compose.env')).mode & 0o777, 0o600);
      assert.equal(statSync(join(back, 'storage', A)).mtimeMs, new Date('2025-03-04T05:06:07Z').getTime(), 'modification time kept');
      assert.equal(statSync(join(back, 'storage', A)).nlink, 1, 'a link in the backup is an ordinary file in the archive');
      assert.equal(statSync(join(back, 'storage', B)).nlink, 1);
      // And it is the backup that was signed: the signature, the list and every file of the tree check out.
      const check = f.sh('backup_authenticate "$1" false', back);
      assert.equal(check.status, 0, check.stderr);
    }
  } finally { f.cleanup(); }
});

test('the extended attributes of the stored files travel in the archive and come back on extraction', { skip: xattrSkip() }, () => {
  const xattrs = { [A]: { 'user.supabase.content-type': 'application/pdf', 'user.supabase.cache-control': 'max-age=3600' } };
  const f = fixture({ xattrs });
  try {
    assert.equal(xattrTool().get(join(f.dir, 'storage', A), 'user.supabase.content-type'), 'application/pdf');
    for (const encrypt of ['', 'encrypt']) {
      const out = join(f.drive, `${NAME}.tar${encrypt ? '.enc' : ''}`);
      assert.equal(f.write(out, encrypt).status, 0);
      const { dest, result } = f.extract(out);
      assert.equal(result.status, 0, result.stderr);
      const file = join(dest, NAME, 'storage', A);
      assert.equal(xattrTool().get(file, 'user.supabase.content-type'), 'application/pdf', `${encrypt || 'plain'}: content type`);
      assert.equal(xattrTool().get(file, 'user.supabase.cache-control'), 'max-age=3600');
      assert.equal(xattrTool().get(join(dest, NAME, 'storage', B), 'user.supabase.content-type'), null, 'a file without one has none');
    }
    // The attributes are in pax headers of a plain tar, readable by any tar on a machine that has none of the filesystem.
    assert.match(readFileSync(join(f.drive, `${NAME}.tar`), 'latin1'), /SCHILY\.xattr\.user\.supabase\.content-type=application\/pdf/);
  } finally { f.cleanup(); }
});

test('extracting with --no-tree writes no storage/ at all, and the rest authenticates with the chain-only check', () => {
  const f = fixture();
  try {
    for (const encrypt of ['', 'encrypt']) {
      const out = join(f.drive, `${NAME}.tar${encrypt ? '.enc' : ''}`);
      assert.equal(f.write(out, encrypt).status, 0);
      const { dest, result } = f.extract(out, '--no-tree');
      assert.equal(result.status, 0, result.stderr);
      const back = join(dest, NAME);
      assert.equal(existsSync(join(back, 'storage')), false, `${encrypt || 'plain'}: no tree, not even its folder`);
      assert.deepEqual(filesUnder(back), filesUnder(f.dir).filter(path => !path.startsWith('storage/')));
      // Without the tree the full check refuses; the chain-only check (verify-restore.sh --no-storage-tree) passes.
      assert.match(authenticate(f, back).stderr, /no storage\/ tree|does not match|Refusing/);
      assert.notEqual(authenticate(f, back).status, 0);
      const chain = f.sh('BACKUP_TREE=skip backup_authenticate "$1" false', back);
      assert.equal(chain.status, 0, chain.stderr);
      // The room that needs: the bytes of the members before the tree, found by reading the start of the archive only.
      const small = f.sh('backup_archive_small_bytes "$1"', out);
      assert.equal(small.status, 0, small.stderr);
      const expected = filesUnder(f.dir).filter(path => !path.startsWith('storage/')).reduce((sum, path) => sum + statSync(join(f.dir, path)).size, 0);
      assert.equal(Number(small.stdout), expected, `${encrypt || 'plain'}: small files`);
    }
  } finally { f.cleanup(); }
});

test('the room for the small files is the size of the archive when the tree comes before the manifest, as in an archive an earlier release wrote', () => {
  const f = fixture();
  try {
    // An earlier release archived the backup folder in directory order: here the tree first, the small files after it.
    const out = join(f.drive, `${NAME}.tar`);
    const rest = filesUnder(f.dir).filter(path => !path.startsWith('storage/')).map(path => `${NAME}/${path}`);
    const packed = spawnSync('tar', ['--format=posix', '-C', join(f.state, 'backups'), '-cf', out, `${NAME}/storage`, ...rest], { encoding: 'utf8' });
    assert.equal(packed.status, 0, packed.stderr);
    const small = f.sh('backup_archive_small_bytes "$1"', out);
    assert.equal(small.status, 0, small.stderr);
    assert.equal(Number(small.stdout), statSync(out).size, 'the count of the members before the tree would be short here, so the archive size is the room to ask for');
    // This release's order is unchanged: the same backup written by backup_archive_write gets the figure for the small files only.
    mkdirSync(join(f.drive, 'new'));
    const named = join(f.drive, 'new', `${NAME}.tar`);
    assert.equal(f.write(named).status, 0);
    const sized = f.sh('backup_archive_small_bytes "$1"', named);
    assert.equal(sized.status, 0, sized.stderr);
    const expected = rest.reduce((sum, path) => sum + statSync(join(f.state, 'backups', path)).size, 0);
    assert.equal(Number(sized.stdout), expected);
    assert.ok(Number(sized.stdout) < statSync(named).size, 'the small files are less than the whole archive');
  } finally { f.cleanup(); }
});

test('a v5 backup is archived with its storage.tar.gz last, and that file is not left out of an extraction without the tree', () => {
  const f = fixture({ format: 'warehouse-backup-v5' });
  try {
    const out = join(f.drive, `${NAME}.tar.enc`);
    assert.equal(f.write(out, 'encrypt').status, 0);
    const listing = f.sh('backup_decrypt "$BACKUP_KEY" < "$1" | tar -tf -', out).stdout.split('\n').filter(Boolean);
    assert.equal(listing.at(-1), `${NAME}/storage.tar.gz`);
    assert.equal(listing[1], `${NAME}/SHA256SUMS`);
    const { dest, result } = f.extract(out, '--no-tree');
    assert.equal(result.status, 0, result.stderr);
    assert.ok(existsSync(join(dest, NAME, 'storage.tar.gz')), 'the v5 tarball is a signed file of the backup');
    assert.equal(f.sh('backup_authenticate "$1" false', join(dest, NAME)).status, 0);
    const small = f.sh('backup_archive_small_bytes "$1"', out);
    assert.equal(Number(small.stdout), filesUnder(f.dir).reduce((sum, path) => sum + statSync(join(f.dir, path)).size, 0), 'all of it counts: the tarball cannot be skipped');
  } finally { f.cleanup(); }
});

test('a folder inside the backup (tunnel/) and the optional files travel too', () => {
  const f = fixture({ centralKey: '{"keys":[]}\n' });
  try {
    mkdirSync(join(f.dir, 'tunnel'), { mode: 0o700 });
    writeFileSync(join(f.dir, 'tunnel/config.yml'), 'tunnel: x\n');
    writeFileSync(join(f.dir, 'tunnel/credentials.json'), '{}\n');
    resign(f.dir, ['storage.manifest', 'database.dump', 'integrity.txt', 'metadata.txt', 'compose.env', 'instance.json', 'roles.txt', 'storage_objects.txt', 'central-jwks.json', 'tunnel/config.yml', 'tunnel/credentials.json']);
    const out = join(f.drive, `${NAME}.tar`);
    assert.equal(f.write(out).status, 0);
    const list = names(spawnSync('tar', ['-tvf', out], { encoding: 'utf8' }).stdout);
    assert.ok(list.includes(`${NAME}/tunnel/`) && list.includes(`${NAME}/tunnel/config.yml`) && list.includes(`${NAME}/central-jwks.json`));
    assert.ok(list.indexOf(`${NAME}/tunnel/`) < list.indexOf(`${NAME}/tunnel/config.yml`));
    const { dest, result } = f.extract(out);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(f.sh('backup_authenticate "$1" false', join(dest, NAME)).status, 0);
    assert.equal(statSync(join(dest, NAME, 'tunnel')).mode & 0o777, 0o700);
  } finally { f.cleanup(); }
});

test('writing refuses what it cannot archive faithfully, and returns non-zero when the output cannot be written', () => {
  const f = fixture();
  try {
    const out = join(f.drive, `${NAME}.tar`);
    // The output cannot be written.
    let result = f.write(join(f.drive, 'no-such-folder', 'x.tar'));
    assert.notEqual(result.status, 0);
    // A signed list that names a path outside the backup.
    const original = readFileSync(join(f.dir, 'SHA256SUMS'), 'utf8');
    writeFileSync(join(f.dir, 'SHA256SUMS'), `${original}${'0'.repeat(64)}  ../../etc/passwd\n`);
    result = f.write(out);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /SHA256SUMS names an unusable path: \.\.\/\.\.\/etc\/passwd/);
    assert.equal(existsSync(out), false);
    // A list for a v6 backup whose tree is gone.
    writeFileSync(join(f.dir, 'SHA256SUMS'), original);
    rmSync(join(f.dir, 'storage'), { recursive: true });
    result = f.write(out);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /lists storage\.manifest but has no storage\/ tree/);
    // No list at all, a folder that is not a backup, a wrong third argument.
    rmSync(join(f.dir, 'SHA256SUMS'));
    assert.match(f.write(out).stderr, /has no SHA256SUMS/);
    assert.match(f.sh('backup_archive_write "$1" "$2" maybe', f.dir, out).stderr, /third argument is `encrypt` or nothing/);
    assert.match(f.sh('backup_archive_write "$1/nothing" "$2"', f.drive, out).stderr, /needs the backup folder and the output file/);
    assert.match(f.sh('backup_archive_extract "$1" "$2" --everything', out, f.drive).stderr, /backup_archive_extract/);
  } finally { f.cleanup(); }
});

test('a tree file that cannot be read stops the archive with a failure instead of writing a short one that looks whole', () => {
  const f = fixture();
  try {
    chmodSync(join(f.dir, 'storage', A), 0o000);
    if (process.getuid() === 0) return;
    const out = join(f.drive, `${NAME}.tar`);
    const result = f.write(out);
    assert.notEqual(result.status, 0, 'the pipeline reports tar\'s failure');
  } finally { chmodSync(join(f.dir, 'storage', A), 0o600); f.cleanup(); }
});

test('backup-archive.sh is a sourced helper: run directly it says so', () => {
  const result = spawnSync('bash', [fileURLToPath(new URL('../scripts/backup-archive.sh', import.meta.url))], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /is a sourced helper, not a command/);
});
