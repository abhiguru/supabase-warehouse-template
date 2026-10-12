import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const functions = new URL('../functions/', import.meta.url).pathname;
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const packageJson = JSON.parse(read('package.json'));
const vendorManifest = JSON.parse(read('scripts/edge-vendor/package.json'));
const vendorLock = JSON.parse(read('scripts/edge-vendor/package-lock.json'));

function specifiers() {
  const found = [];
  for (const entry of readdirSync(functions, { recursive: true })) {
    const file = String(entry);
    if (!file.endsWith('.ts')) continue;
    const source = readFileSync(join(functions, file), 'utf8');
    for (const match of source.matchAll(/(?:\bfrom\s+|\bimport\s*\(\s*|\bimport\s+)(['"])([^'"\n]+)\1/g)) found.push({ file, specifier: match[2] });
  }
  return found;
}

test('the functions load no module from the network when a worker starts', () => {
  // Everything is a file in this repository: relative imports, with the two
  // libraries built into functions/vendor. The one exception is the printing
  // code, which the router refuses with 503 and which imports ipp on demand.
  const all = specifiers();
  assert.ok(all.length > 40, 'function imports were read');
  const vendored = new Set();
  for (const { file, specifier } of all) {
    if (specifier.startsWith('node:')) continue;
    if (specifier.startsWith('npm:')) {
      assert.equal(specifier, 'npm:ipp@2.0.1', `${file}: ${specifier}`);
      assert.match(file, /^_shared\/ipp-client\.ts$|^print-|^get-printer-status\//, `${file} is not printing code`);
      continue;
    }
    assert.match(specifier, /^\.{1,2}\//, `${file}: ${specifier} is not a file in this repository`);
    const vendor = /^\.\.\/vendor\/(.+)$/.exec(specifier)?.[1];
    if (vendor) vendored.add(vendor);
  }
  assert.deepEqual([...vendored].sort(), ['jose.mjs', 'supabase-js.mjs']);
  assert.doesNotMatch(read('functions/main/index.ts'), /importMapPath/);
});

test('functions/vendor holds exactly the files its checksum list names', () => {
  const sums = read('functions/vendor/SHA256SUMS').trim().split('\n').map(line => line.split(/\s+/));
  assert.deepEqual(sums.map(([, name]) => name), ['LICENSES.txt', 'jose.mjs', 'supabase-js.mjs']);
  for (const [sum, name] of sums) {
    const actual = createHash('sha256').update(readFileSync(join(functions, 'vendor', name))).digest('hex');
    assert.equal(actual, sum, `${name} was changed without scripts/vendor-edge-modules.sh`);
  }
  assert.deepEqual(readdirSync(join(functions, 'vendor')).sort(), ['LICENSES.txt', 'SHA256SUMS', 'jose.mjs', 'supabase-js.mjs']);
  // A vendored file must not reach out again.
  for (const [, name] of sums.filter(([, file]) => file.endsWith('.mjs'))) {
    const source = readFileSync(join(functions, 'vendor', name), 'utf8');
    assert.doesNotMatch(source, /^\s*(?:import|export)\b[^\n]*\bfrom\s*["'][^"']+["']/m, `${name} imports another module`);
    assert.doesNotMatch(source, /\bimport\s*\(\s*["']/, `${name} imports another module on demand`);
  }
});

test('the vendored libraries are built from exact, locked versions', () => {
  for (const [name, version] of Object.entries({ ...vendorManifest.dependencies, ...vendorManifest.devDependencies })) {
    assert.match(version, /^\d+\.\d+\.\d+$/, `${name} is not an exact version`);
    assert.equal(vendorLock.packages[`node_modules/${name}`]?.version, version, `${name} differs in the lock file`);
  }
  for (const [path, entry] of Object.entries(vendorLock.packages)) {
    if (path) assert.match(entry.integrity ?? '', /^sha512-/, `${path} has no integrity hash`);
  }
  assert.deepEqual(Object.keys(vendorManifest.dependencies).sort(), ['@supabase/supabase-js', 'jose']);
});

test('the unit tests sign tokens with the jose release the functions verify with', async () => {
  assert.equal(packageJson.devDependencies.jose, vendorManifest.dependencies.jose, 'package.json jose differs from scripts/edge-vendor/package.json');
  const installed = JSON.parse(read('node_modules/jose/package.json')).version;
  assert.equal(installed, vendorManifest.dependencies.jose, 'installed jose differs; run npm ci');
  // A token signed with the installed package verifies with the vendored file.
  const { SignJWT } = await import('jose');
  const { jwtVerify } = await import('../functions/vendor/jose.mjs');
  const key = new TextEncoder().encode('unit-test-key-of-thirty-two-bytes');
  const token = await new SignJWT({ role: 'fixture' }).setProtectedHeader({ alg: 'HS256' }).sign(key);
  assert.equal((await jwtVerify(token, key)).payload.role, 'fixture');
});
