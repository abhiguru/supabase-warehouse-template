// scripts/retag-storage-metadata.cjs (run inside the storage container with `node -e`, exactly as scripts/storage-retag.sh runs
// it) sets the extended attributes user.supabase.content-type and user.supabase.cache-control from the catalog. The Storage
// service's module fs-xattr is stood in for: by a JSON file (any host), and by real attributes where this host can set them.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { makeState, xattrTool, xattrSkip } from './backup-test-helpers.mjs';

const root = new URL('..', import.meta.url).pathname;
const retagScript = readFileSync(join(root, 'scripts/retag-storage-metadata.cjs'), 'utf8');
const CONTENT_TYPE = 'user.supabase.content-type';
const CACHE_CONTROL = 'user.supabase.cache-control';

// A module fs-xattr with the calls the script uses (getAttributeSync, setAttributeSync). "json": attributes kept in the file
// named by FAKE_XATTR_DB. "real": real extended attributes, through the same host tools the other tests use (setfattr and
// getfattr, else python3: whichever xattrTool() found works on this host).
const missingAttribute = "Object.assign(new Error('ENODATA: no data available'), { code: 'ENODATA' })";
const realModule = () => (xattrTool()?.kind === 'attr' ? `
const { spawnSync } = require('node:child_process');
exports.getAttributeSync = (file, name) => {
  const r = spawnSync('getfattr', ['-n', name, '--only-values', file]);
  if (r.status !== 0) throw ${missingAttribute};
  return r.stdout;
};
exports.setAttributeSync = (file, name, value) => {
  const r = spawnSync('setfattr', ['-n', name, '-v', String(value), file]);
  if (r.status !== 0) throw new Error(String(r.stderr));
};
` : `
const { spawnSync } = require('node:child_process');
exports.getAttributeSync = (file, name) => {
  const r = spawnSync('python3', ['-I', '-c', 'import os, sys; sys.stdout.buffer.write(os.getxattr(sys.argv[1], sys.argv[2]))', file, name]);
  if (r.status !== 0) throw ${missingAttribute};
  return r.stdout;
};
exports.setAttributeSync = (file, name, value) => {
  const r = spawnSync('python3', ['-I', '-c', 'import os, sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode())', file, name, String(value)]);
  if (r.status !== 0) throw new Error(String(r.stderr));
};
`);
function fakeModule(dir, kind) {
  const module = join(dir, 'modules/node_modules/fs-xattr');
  mkdirSync(module, { recursive: true });
  writeFileSync(join(module, 'package.json'), '{"name":"fs-xattr","version":"0.4.0","main":"index.js"}\n');
  writeFileSync(join(module, 'index.js'), kind === 'json' ? `
const fs = require('node:fs');
const load = () => { try { return JSON.parse(fs.readFileSync(process.env.FAKE_XATTR_DB, 'utf8')); } catch { return {}; } };
const missing = () => ${missingAttribute};
exports.getAttributeSync = (file, name) => { const value = load()[file + '|' + name]; if (value === undefined) throw missing(); return Buffer.from(value); };
exports.setAttributeSync = (file, name, value) => { const db = load(); db[file + '|' + name] = String(value); fs.writeFileSync(process.env.FAKE_XATTR_DB, JSON.stringify(db)); };
` : realModule());
  return join(dir, 'modules/node_modules');
}

function setup(prefix, kind) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const storage = join(scratch, 'storage');
  const base = join(storage, 'stub', 'stub');
  const put = (path, body = 'bytes') => { mkdirSync(dirname(join(base, path)), { recursive: true }); writeFileSync(join(base, path), body); return join(base, path); };
  const run = (lines, ...args) => {
    const result = spawnSync(process.execPath, ['-e', retagScript, ...args], {
      input: lines.map(line => typeof line === 'string' ? line : JSON.stringify(line)).join('\n') + '\n', encoding: 'utf8',
      env: { PATH: process.env.PATH, FILE_STORAGE_BACKEND_PATH: storage, GLOBAL_S3_BUCKET: 'stub', TENANT_ID: 'stub',
        NODE_PATH: fakeModule(scratch, kind), FAKE_XATTR_DB: join(scratch, 'xattr.json') } });
    return result;
  };
  const attrs = file => {
    if (kind === 'json') { const db = (() => { try { return JSON.parse(readFileSync(join(scratch, 'xattr.json'), 'utf8')); } catch { return {}; } })(); return { type: db[`${file}|${CONTENT_TYPE}`] ?? null, cache: db[`${file}|${CACHE_CONTROL}`] ?? null }; }
    const tool = xattrTool();
    return { type: tool.get(file, CONTENT_TYPE), cache: tool.get(file, CACHE_CONTROL) };
  };
  return { scratch, storage, base, put, run, attrs, done: () => rmSync(scratch, { recursive: true, force: true }) };
}

for (const kind of ['json', 'real']) {
  test(`retag sets content type and cache control from the catalog, once, and counts what it did (${kind} attributes)`, { skip: kind === 'real' && xattrSkip() }, () => {
    const t = setup(`warehouse-retag-${kind}-`, kind);
    try {
      const pdf = t.put('documents/a.pdf/v1');
      const photo = t.put('dispatch-images/c1/photo.jpg/v7');
      const unversioned = t.put('documents/plain.pdf');
      const odd = t.put('documents/ünï cødé #1 "q".pdf/v1');
      t.put('documents/nometa.pdf/v1');
      const catalog = [
        { path: 'documents/a.pdf/v1', mimetype: 'application/pdf', cacheControl: 'max-age=3600' },
        { path: 'dispatch-images/c1/photo.jpg/v7', mimetype: 'image/jpeg', cacheControl: null },
        { path: 'documents/plain.pdf', mimetype: 'application/pdf', cacheControl: 'no-cache' },
        { path: 'documents/ünï cødé #1 "q".pdf/v1', mimetype: 'application/pdf', cacheControl: 'max-age=60' },
        { path: 'documents/nometa.pdf/v1', mimetype: null, cacheControl: null },
        { path: 'documents/gone.pdf/v1', mimetype: 'application/pdf', cacheControl: 'max-age=3600' },
      ];
      const first = t.run(catalog);
      assert.equal(first.status, 0, first.stderr);
      assert.equal(first.stdout.trim(), 'Storage metadata set from the catalog: 4 files updated, 0 already correct, 1 catalogued but not on disk, 1 without catalog metadata, 0 errors.');
      assert.deepEqual(t.attrs(pdf), { type: 'application/pdf', cache: 'max-age=3600' });
      assert.deepEqual(t.attrs(photo), { type: 'image/jpeg', cache: null }, 'no cache control in the catalog: none is set');
      assert.deepEqual(t.attrs(unversioned), { type: 'application/pdf', cache: 'no-cache' }, 'an object without a version is the file itself');
      assert.deepEqual(t.attrs(odd), { type: 'application/pdf', cache: 'max-age=60' }, 'any character in a name');
      assert.deepEqual(t.attrs(join(t.base, 'documents/nometa.pdf/v1')), { type: null, cache: null });

      // Again: nothing to do, nothing written.
      const second = t.run(catalog);
      assert.equal(second.status, 0, second.stderr);
      assert.match(second.stdout, /0 files updated, 4 already correct, 1 catalogued but not on disk, 1 without catalog metadata, 0 errors\./);
      // The catalog changes a type: that one file is updated.
      catalog[0].mimetype = 'application/octet-stream';
      const third = t.run(catalog);
      assert.match(third.stdout, /1 files updated, 3 already correct/);
      assert.equal(t.attrs(pdf).type, 'application/octet-stream');
      assert.equal(t.attrs(pdf).cache, 'max-age=3600');
    } finally { t.done(); }
  });
}

test('retag refuses a path outside the storage directory and a line that is not JSON, reports them and still processes the rest', () => {
  const t = setup('warehouse-retag-bad-', 'json');
  try {
    const pdf = t.put('documents/a.pdf/v1');
    writeFileSync(join(t.scratch, 'outside.txt'), 'outside');
    symlinkSync(join(t.scratch, 'outside.txt'), join(t.base, 'documents', 'link.pdf'));
    const result = t.run([
      { path: '../../../outside.txt', mimetype: 'text/plain', cacheControl: 'no-cache' },
      'this is not json',
      { path: 'documents/link.pdf', mimetype: 'text/plain', cacheControl: 'no-cache' },
      { path: 'documents/a.pdf/v1', mimetype: 'application/pdf', cacheControl: 'max-age=3600' },
      '',
    ]);
    assert.equal(result.status, 1, 'a refused entry fails the run');
    assert.match(result.stdout, /1 files updated, 0 already correct, 1 catalogued but not on disk, 0 without catalog metadata, 2 errors\./, 'the symlink counts as not on disk');
    assert.match(result.stderr, /line 1: \.\.\/\.\.\/\.\.\/outside\.txt: outside the storage directory/);
    assert.match(result.stderr, /line 2: /);
    assert.deepEqual(t.attrs(pdf), { type: 'application/pdf', cache: 'max-age=3600' });
    assert.deepEqual(t.attrs(join(t.scratch, 'outside.txt')), { type: null, cache: null }, 'nothing outside was touched');
  } finally { t.done(); }
});

test('retag fails when the Storage service module reports an error other than a missing attribute', () => {
  const t = setup('warehouse-retag-fail-', 'json');
  try {
    t.put('documents/a.pdf/v1');
    // The module's database path points nowhere writable: setting an attribute throws.
    const result = spawnSync(process.execPath, ['-e', retagScript], { input: JSON.stringify({ path: 'documents/a.pdf/v1', mimetype: 'application/pdf', cacheControl: 'x' }) + '\n', encoding: 'utf8',
      env: { PATH: process.env.PATH, FILE_STORAGE_BACKEND_PATH: t.storage, NODE_PATH: fakeModule(t.scratch, 'json'), FAKE_XATTR_DB: join(t.scratch, 'no-such-dir/xattr.json') } });
    assert.equal(result.status, 1);
    assert.match(result.stdout, /0 files updated, 0 already correct, 0 catalogued but not on disk, 0 without catalog metadata, 1 errors\./);
    assert.match(result.stderr, /line 1: /);
  } finally { t.done(); }
});

// scripts/storage-retag.sh with a stand-in docker: the catalog goes from the database container to the storage container.
// The storage container's script is called with `all` (the run that sets the attributes) or `probe` (the look at a sample,
// which answers FAKE_PROBE_STATUS: 10 when a sampled file has no content type).
function wrapper({ psqlStatus = 0, nodeStatus = 0, probeStatus = 0, args = [], catalog = '{"path":"documents/a.pdf/v1","mimetype":"application/pdf","cacheControl":"max-age=3600"}\n', holdLock = false } = {}) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-retag-wrapper-'));
  try {
    const state = makeState(scratch);
    const bin = join(scratch, 'bin'); mkdirSync(bin);
    writeFileSync(join(scratch, 'catalog'), catalog);
    writeFileSync(join(bin, 'docker'), `#!/bin/sh
case "$*" in
  *'exec -T storage node -e'*)
    for last; do :; done
    if [ "$last" = probe ]; then
      printf 'storage-node-probe\\n' >> "$FAKE_DOCKER_LOG"; cat > "$FAKE_PROBE_STDIN"; echo 'Storage metadata check: 1 of 1 sampled files have no content type.'; exit "$FAKE_PROBE_STATUS"
    fi
    printf 'storage-node\\n' >> "$FAKE_DOCKER_LOG"; printf '%s' "$*" > "$FAKE_NODE_ARGS"; cat > "$FAKE_STORAGE_STDIN"; echo 'Storage metadata set from the catalog: 1 files updated.'; exit "$FAKE_NODE_STATUS" ;;
  *'exec -T db psql'*) printf 'catalog-query\\n' >> "$FAKE_DOCKER_LOG"; printf '%s' "$*" > "$FAKE_PSQL_ARGS"; cat "$FAKE_CATALOG"; exit "$FAKE_PSQL_STATUS" ;;
esac
`, { mode: 0o700 });
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, FAKE_DOCKER_LOG: join(scratch, 'docker.log'),
      FAKE_STORAGE_STDIN: join(scratch, 'stdin'), FAKE_PROBE_STDIN: join(scratch, 'probe-stdin'), FAKE_NODE_ARGS: join(scratch, 'node-args'), FAKE_PSQL_ARGS: join(scratch, 'psql-args'),
      FAKE_CATALOG: join(scratch, 'catalog'), FAKE_NODE_STATUS: String(nodeStatus), FAKE_PROBE_STATUS: String(probeStatus), FAKE_PSQL_STATUS: String(psqlStatus) };
    const read = path => { try { return readFileSync(path, 'utf8'); } catch { return null; } };
    const result = spawnSync('bash', [join(root, 'scripts/storage-retag.sh'), ...args], { encoding: 'utf8', env });
    return { ...result, calls: (read(env.FAKE_DOCKER_LOG) ?? '').trim().split('\n').filter(Boolean), stdin: read(env.FAKE_STORAGE_STDIN), probeStdin: read(env.FAKE_PROBE_STDIN), nodeArgs: read(env.FAKE_NODE_ARGS), psqlArgs: read(env.FAKE_PSQL_ARGS), holdLock };
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

test('storage:retag feeds the catalog, one JSON object per line, to the script in the storage container', () => {
  const result = wrapper();
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.calls.sort(), ['catalog-query', 'storage-node'], 'no look at a sample without --if-missing');
  assert.equal(result.stdin, '{"path":"documents/a.pdf/v1","mimetype":"application/pdf","cacheControl":"max-age=3600"}\n');
  assert.match(result.psqlArgs, /jsonb_build_object\('path', bucket_id \|\| '\/' \|\| name \|\| COALESCE\('\/' \|\| version, ''\), 'mimetype', metadata->>'mimetype', 'cacheControl', metadata->>'cacheControl'\)::text FROM storage\.objects/);
  assert.ok(result.nodeArgs.includes('user.supabase.content-type') && result.nodeArgs.includes("require('fs-xattr')"), 'the script text is what runs in the container');
  assert.match(result.stdout, /Storage metadata set from the catalog/);
});

test('storage:retag fails when the catalog query fails or the script in the container fails', () => {
  const noCatalog = wrapper({ psqlStatus: 3 });
  assert.notEqual(noCatalog.status, 0, 'a failing query is not hidden by the pipe');
  const noScript = wrapper({ nodeStatus: 1 });
  assert.notEqual(noScript.status, 0);
});

test('storage:retag --if-missing looks at a sample first and sets every file only when a sampled one has no content type', () => {
  const lacking = wrapper({ args: ['--if-missing'], probeStatus: 10 });
  assert.equal(lacking.status, 0, lacking.stderr);
  // (The query and the script of one pipeline write their log lines at the same time, so the order is by sorted name.)
  assert.deepEqual([...lacking.calls].sort(), ['catalog-query', 'catalog-query', 'storage-node', 'storage-node-probe'], 'look, then the whole catalog again for the run that sets');
  assert.ok(lacking.calls.indexOf('storage-node-probe') < lacking.calls.indexOf('storage-node'), 'the look comes first');
  assert.equal(lacking.probeStdin, lacking.stdin, 'both are fed the catalog');
  assert.match(lacking.stdout, /Some stored files have no content type .*: setting them for every file\./);
  assert.match(lacking.stdout, /Storage metadata set from the catalog/);

  const fine = wrapper({ args: ['--if-missing'], probeStatus: 0 });
  assert.equal(fine.status, 0, fine.stderr);
  assert.deepEqual([...fine.calls].sort(), ['catalog-query', 'storage-node-probe'], 'nothing is set when the sample is fine');
  assert.match(fine.stdout, /The stored files carry their content types; nothing to set\./);

  const broken = wrapper({ args: ['--if-missing'], probeStatus: 3 });
  assert.equal(broken.status, 3, 'a failing look is a failure, not a reason to set blindly');
  assert.deepEqual([...broken.calls].sort(), ['catalog-query', 'storage-node-probe']);
  const noCatalog = wrapper({ args: ['--if-missing'], psqlStatus: 3 });
  assert.notEqual(noCatalog.status, 0);
  const typo = wrapper({ args: ['--missing'] });
  assert.equal(typo.status, 1);
  assert.match(typo.stderr, /Usage: npm run storage:retag \[-- --if-missing\]/);
  assert.deepEqual(typo.calls, []);
});

test('the probe looks at up to 20 catalogued files spread over the list, writes nothing, and answers 10 when a sampled one has no content type', () => {
  const t = setup('warehouse-retag-probe-', 'json');
  try {
    const catalog = [];
    for (let i = 0; i < 45; i++) {
      const path = `documents/f${String(i).padStart(2, '0')}.pdf/v1`;
      t.put(path);
      catalog.push({ path, mimetype: 'application/pdf', cacheControl: 'max-age=3600' });
    }
    catalog.push({ path: 'documents/nometa.pdf/v1', mimetype: null, cacheControl: null });   // not looked at
    t.put('documents/nometa.pdf/v1');
    catalog.push({ path: 'documents/gone.pdf/v1', mimetype: 'application/pdf', cacheControl: 'max-age=3600' });   // not on disk: not looked at
    const none = t.run(catalog, 'probe');
    assert.equal(none.status, 10, none.stderr);
    assert.equal(none.stdout.trim(), 'Storage metadata check: 20 of 20 sampled files have no content type.');
    assert.deepEqual(t.attrs(join(t.base, 'documents/f00.pdf/v1')), { type: null, cache: null }, 'the probe sets nothing');
    assert.equal(t.run(catalog).status, 0);
    const all = t.run(catalog, 'probe');
    assert.equal(all.status, 0, all.stderr);
    assert.equal(all.stdout.trim(), 'Storage metadata check: 0 of 20 sampled files have no content type.');
    // The sample is f00, f02, f04 ... (45 files, 20 looked at: indices floor(i * 45 / 20)). A sampled file without its type is found.
    const sampled = [0, 2, 4, 6, 9, 11, 13, 15, 18, 20, 22, 24, 27, 29, 31, 33, 36, 38, 40, 42].map(i => `documents/f${String(i).padStart(2, '0')}.pdf/v1`);
    for (const path of [sampled[0], sampled[10], sampled[19]]) {
      const db = JSON.parse(readFileSync(join(t.scratch, 'xattr.json'), 'utf8'));
      delete db[`${join(t.base, path)}|${CONTENT_TYPE}`];
      writeFileSync(join(t.scratch, 'xattr.json'), JSON.stringify(db));
      const found = t.run(catalog, 'probe');
      assert.equal(found.status, 10, `${path} is in the sample`);
      assert.match(found.stdout, /Storage metadata check: 1 of 20 sampled files have no content type\./);
      t.run(catalog);   // sets it again
    }
    // A file outside the sample is not looked at: that is what a sample means, and why the full run is also there.
    const db = JSON.parse(readFileSync(join(t.scratch, 'xattr.json'), 'utf8'));
    delete db[`${join(t.base, 'documents/f01.pdf/v1')}|${CONTENT_TYPE}`];
    writeFileSync(join(t.scratch, 'xattr.json'), JSON.stringify(db));
    assert.equal(t.run(catalog, 'probe').status, 0);
    // Fewer than 20 files: all of them. No catalogued file at all: nothing lacks anything.
    const few = setup('warehouse-retag-probe-few-', 'json');
    try {
      few.put('documents/a.pdf/v1'); few.put('documents/b.pdf/v1');
      const two = [{ path: 'documents/a.pdf/v1', mimetype: 'application/pdf' }, { path: 'documents/b.pdf/v1', mimetype: 'application/pdf' }];
      assert.match(few.run(two, 'probe').stdout, /2 of 2 sampled files have no content type/);
      assert.equal(few.run([], 'probe').status, 0);
      assert.match(few.run([], 'probe').stdout, /0 of 0 sampled/);
    } finally { few.done(); }
  } finally { t.done(); }
});
