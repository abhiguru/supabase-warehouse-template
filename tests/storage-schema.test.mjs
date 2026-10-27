// The Storage service's schema version: where it is written down (docker/storage/migrations-head.txt), that the compose file freezes
// Storage's migrator at it, and that the integrity report counts it. The refusals of restore and verify are in restore.test.mjs and
// backup-storage.test.mjs; the head against the real image is tests/migrations.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const head = Object.fromEntries(read('docker/storage/migrations-head.txt').split('\n').filter(l => /^[a-z]+=/.test(l)).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]));

// The text of the `storage:` service in the compose file (up to the next service).
const storageService = () => {
  const compose = read('docker/docker-compose.yml');
  const start = compose.indexOf('\n  storage:\n');
  assert.ok(start > 0, 'the storage service');
  const rest = compose.slice(start + 1);
  const end = rest.slice(1).search(/\n  [a-z][a-z-]*:\n/);
  return end < 0 ? rest : rest.slice(0, end + 1);
};

test('migrations-head.txt names the newest Storage migration as a number and a name', () => {
  assert.match(head.id, /^[0-9]{1,6}$/);
  assert.match(head.name, /^[a-z0-9][a-z0-9-]*$/);
});

test('the storage service freezes its migrator at the head the image ships', () => {
  const lines = storageService().split('\n').filter(l => /^\s+DB_MIGRATIONS_FREEZE_AT:/.test(l));
  assert.equal(lines.length, 1, 'DB_MIGRATIONS_FREEZE_AT is set once on the storage service');
  assert.equal(lines[0].replace(/^\s+DB_MIGRATIONS_FREEZE_AT:\s*/, '').replace(/^["']|["']$/g, ''), head.name);
});

test('the version the image reports (ENV VERSION) is the tag it is built from', () => {
  const dockerfile = read('docker/storage/Dockerfile');
  const from = dockerfile.match(/^FROM supabase\/storage-api:v([0-9.]+)@sha256:[0-9a-f]{64} AS patched$/m);
  assert.ok(from, 'stage 1 is the publisher image by tag and digest');
  assert.equal(dockerfile.match(/^ENV VERSION=(\S+)$/m)?.[1], from[1]);
});

test('pg-boss is pinned to one commit, in the manifest and in the lock', () => {
  const manifest = JSON.parse(read('docker/storage/package.json'));
  const pinned = manifest.dependencies['pg-boss'].match(/^github:supabase\/pg-boss#([0-9a-f]{40})$/);
  assert.ok(pinned, `pg-boss is not pinned to a commit: ${manifest.dependencies['pg-boss']}`);
  const lock = JSON.parse(read('docker/storage/package-lock.json'));
  assert.equal(lock.packages[''].dependencies['pg-boss'], manifest.dependencies['pg-boss']);
  assert.match(lock.packages['node_modules/pg-boss'].resolved, new RegExp(`#${pinned[1]}$`), 'the lock resolves the pinned commit');
});

test('the integrity report prints the Storage migration count and head, and prints zeros before Storage has run', () => {
  const sql = read('scripts/backup-integrity.sql');
  assert.match(sql, /\\if :storage_migrations_recorded\n.*'storage_migrations_count=' \|\| count\(\*\) FROM storage\.migrations;\nSELECT 'storage_migrations_head=' \|\| COALESCE\(max\(id\), 0\) FROM storage\.migrations;\n\\else\nSELECT 'storage_migrations_count=0';\nSELECT 'storage_migrations_head=0';\n\\endif/s);
});

test('Dependabot may propose Storage minor updates again and still ignores majors', () => {
  const config = read('.github/dependabot.yml');
  const block = config.match(/- dependency-name: supabase\/storage-api\n((?:\s+.*\n)*?)(?=\s*- dependency-name|\s*- package-ecosystem|$)/);
  assert.ok(block, 'a storage-api entry');
  assert.match(block[1], /version-update:semver-major/);
  assert.doesNotMatch(block[1], /version-update:semver-minor/);
});
