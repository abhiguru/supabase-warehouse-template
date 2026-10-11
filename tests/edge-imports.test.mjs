import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const functions = new URL('../functions/', import.meta.url).pathname;
const map = JSON.parse(readFileSync(join(functions, 'import_map.json'), 'utf8')).imports;
const packageJson = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

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

test('functions/import_map.json is the one list of remote modules, each at an exact version', () => {
  const remote = Object.values(map);
  for (const [name, url] of Object.entries(map)) {
    assert.match(url, /^https:\/\/(?:esm\.sh|deno\.land)\/[^?#]*@\d+\.\d+\.\d+(?:\/|$)/, `${name} is not pinned to an exact version`);
  }
  const used = new Set();
  const all = specifiers();
  assert.ok(all.length > 40, 'function imports were read');
  for (const { file, specifier } of all) {
    if (/^\.{1,2}\//.test(specifier) || specifier.startsWith('node:')) continue;
    if (specifier.startsWith('npm:')) {
      assert.match(specifier, /^npm:(?:@[a-z0-9-]+\/)?[a-z0-9-]+@\d+\.\d+\.\d+$/, `${file}: ${specifier} has no exact version`);
      continue;
    }
    const pin = remote.find(url => (url.endsWith('/') ? specifier.startsWith(url) : specifier === url));
    assert.ok(pin, `${file}: ${specifier} is not listed in functions/import_map.json`);
    used.add(pin);
  }
  assert.deepEqual([...used].sort(), [...remote].sort(), 'import_map.json lists a module no function imports');
});

test('each npm package is imported at one version', () => {
  const versions = {};
  for (const { specifier } of specifiers()) {
    const match = /^npm:((?:@[^/]+\/)?[^@]+)(?:@(.+))?$/.exec(specifier);
    if (match) (versions[match[1]] ??= new Set()).add(match[2] ?? 'unpinned');
  }
  assert.deepEqual(Object.fromEntries(Object.entries(versions).map(([name, set]) => [name, [...set]])), { ipp: ['2.0.1'] });
});

test('the unit tests verify tokens with the jose release the edge runtime loads', async () => {
  const runtime = /jose@(\d+\.\d+\.\d+)$/.exec(map.jose)?.[1];
  assert.ok(runtime, 'jose is listed in the import map');
  assert.equal(packageJson.devDependencies.jose, runtime, 'package.json jose differs from functions/import_map.json');
  const installed = JSON.parse(readFileSync(new URL('../node_modules/jose/package.json', import.meta.url), 'utf8')).version;
  assert.equal(installed, runtime, 'installed jose differs; run npm ci');
  // The loader maps the runtime URL to that installed package.
  const viaUrl = await import(map.jose);
  assert.equal(viaUrl.jwtVerify, (await import('jose')).jwtVerify);
});
