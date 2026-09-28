import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, chmodSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const script = new URL('../scripts/export-recovery-backup.sh', import.meta.url).pathname;
const run = (command, args, env) => spawnSync(command, args, { encoding: 'utf8', env });

test('recovery export and intake protect backup structure and credentials', { timeout: 30000 }, (t) => {
  if (run('gpg', ['--version'], process.env).status !== 0) return t.skip('GPG is unavailable');
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-encrypted-backup-'));
  try {
    const backup = join(scratch, 'backup');
    const secrets = join(scratch, 'recovery-secrets');
    const gpgHome = join(scratch, 'gnupg');
    const storage = join(scratch, 'storage');
    for (const dir of [backup, secrets, gpgHome, storage]) mkdirSync(dir, { mode: 0o700 });
    writeFileSync(join(storage, 'object.txt'), 'existing document bytes\n', { mode: 0o600 });
    const storageTar = spawnSync('tar', ['-czf', '-', '-C', storage, '.']);
    assert.equal(storageTar.status, 0, storageTar.stderr?.toString());
    const files = {
      'database.dump': 'database fixture\n', 'storage.tar.gz': storageTar.stdout,
      'integrity.txt': 'integrity fixture\n', 'metadata.txt': 'format=warehouse-backup-v4\n',
      'compose.env': 'PRIVATE_FIXTURE=value\n', 'instance.json': '{}\n',
      'roles.txt': 'postgres\n', 'globals.sql': 'CREATE ROLE fixture;\n',
    };
    for (const [name, content] of Object.entries(files)) writeFileSync(join(backup, name), content, { mode: 0o600 });
    const sums = Object.entries(files).map(([name, content]) =>
      `${createHash('sha256').update(content).digest('hex')}  ${name}`).join('\n') + '\n';
    writeFileSync(join(backup, 'SHA256SUMS'), sums, { mode: 0o600 });
    writeFileSync(join(secrets, 'tunnel.json'), '{"test":"credential"}\n', { mode: 0o600 });
    const env = { ...process.env, GNUPGHOME: gpgHome };
    const generated = run('gpg', ['--batch', '--pinentry-mode', 'loopback', '--passphrase', '',
      '--quick-generate-key', 'Warehouse Recovery Test <recovery-test@example.invalid>', 'rsa2048', 'encr', '0'], env);
    assert.equal(generated.status, 0, generated.stderr);
    const listed = run('gpg', ['--batch', '--with-colons', '--fingerprint'], env);
    assert.equal(listed.status, 0, listed.stderr);
    const fingerprint = listed.stdout.split('\n').find((line) => line.startsWith('fpr:'))?.split(':')[9];
    assert.match(fingerprint, /^[A-F0-9]{40}$/);

    const output = join(scratch, 'off-host.tar.gpg');
    const exported = run('bash', [script, '--gpg', backup, secrets, output, fingerprint], env);
    assert.equal(exported.status, 0, exported.stderr);
    assert.equal(existsSync(output), true);
    const decrypted = spawnSync('gpg', ['--batch', '--quiet', '--decrypt', output], { env, maxBuffer: 2 ** 20 });
    assert.equal(decrypted.status, 0, decrypted.stderr?.toString());
    const listing = spawnSync('tar', ['-tf', '-'], { input: decrypted.stdout, encoding: 'utf8' });
    assert.equal(listing.status, 0, listing.stderr);
    assert.match(listing.stdout, /backup\/globals\.sql/);
    assert.match(listing.stdout, /recovery-secrets\/tunnel\.json/);

    const second = run('bash', [script, '--gpg', backup, secrets, output, fingerprint], env);
    assert.notEqual(second.status, 0, 'Existing ciphertext must not be overwritten');
    const plain = join(scratch, 'off-host-plain.tar');
    const plainExport = run('bash', [script, '--plain', backup, secrets, plain], env);
    assert.equal(plainExport.status, 0, plainExport.stderr);
    assert.match(plainExport.stdout, /UNENCRYPTED/);
    const plainListing = run('tar', ['-tf', plain], env);
    assert.equal(plainListing.status, 0, plainListing.stderr);
    assert.match(plainListing.stdout, /backup\/globals\.sql/);
    assert.match(plainListing.stdout, /recovery-secrets\/tunnel\.json/);
    const prepared = join(scratch, 'prepared');
    const preparedResult = run('python3', [new URL('../scripts/prepare-recovery-bundle.py', import.meta.url).pathname,
      plain, createHash('sha256').update(readFileSync(plain)).digest('hex'), prepared], env);
    assert.equal(preparedResult.status, 0, preparedResult.stderr);
    assert.equal(readFileSync(join(prepared, 'backup', 'globals.sql'), 'utf8'), files['globals.sql']);
    assert.equal(readFileSync(join(prepared, 'recovery-secrets', 'tunnel.json'), 'utf8'), '{"test":"credential"}\n');
    const badHash = run('python3', [new URL('../scripts/prepare-recovery-bundle.py', import.meta.url).pathname,
      plain, '0'.repeat(64), join(scratch, 'bad-hash')], env);
    assert.notEqual(badHash.status, 0);
    assert.equal(existsSync(join(scratch, 'bad-hash')), false);
    const malicious = join(scratch, 'malicious.tar');
    const crafted = run('python3', ['-c', `import io,sys,tarfile
with tarfile.open(sys.argv[1], 'w') as archive:
    entry = tarfile.TarInfo('../escape')
    entry.size = 1
    archive.addfile(entry, io.BytesIO(b'x'))`, malicious], env);
    assert.equal(crafted.status, 0, crafted.stderr);
    const rejected = run('python3', [new URL('../scripts/prepare-recovery-bundle.py', import.meta.url).pathname,
      malicious, createHash('sha256').update(readFileSync(malicious)).digest('hex'), join(scratch, 'rejected')], env);
    assert.notEqual(rejected.status, 0);
    assert.equal(existsSync(join(scratch, 'rejected')), false);
    assert.equal(existsSync(join(scratch, 'escape')), false);
    chmodSync(join(secrets, 'tunnel.json'), 0o644);
    const weak = run('bash', [script, '--plain', backup, secrets, join(scratch, 'weak.tar')], env);
    assert.notEqual(weak.status, 0, 'Readable credential files must be rejected');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
