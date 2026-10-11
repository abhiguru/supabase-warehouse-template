import { readFileSync } from 'node:fs';

// The edge runtime loads its modules from the URLs in functions/import_map.json.
// Under node:test a listed URL resolves to the npm package of the same name, at
// the version package.json pins (tests/edge-imports.test.mjs keeps the two
// equal). Only packages the unit tests reach are installed: jose.
const { imports } = JSON.parse(readFileSync(new URL('../functions/import_map.json', import.meta.url), 'utf8'));
const packageByUrl = new Map(Object.entries(imports).map(([name, url]) => [url, name]));

export async function resolve(specifier, context, nextResolve) {
  return nextResolve(packageByUrl.get(specifier) ?? specifier, context);
}
