// A module-loader hook for the WH-109 print tests: Node's default TypeScript support only strips types, and functions/_shared/ipp-client.ts
// uses a constructor parameter property (`public cupsJobId`), which Deno accepts and a strip-only Node refuses. Every .ts file loaded after
// tests/print-harness.mjs registers this hook is transformed (not just stripped); the sources are not changed.
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';

export async function load(url, context, nextLoad) {
  const path = url.split('?')[0];
  if (path.startsWith('file:') && path.endsWith('.ts')) {
    const source = await readFile(fileURLToPath(path), 'utf8');
    return { format: 'module', source: stripTypeScriptTypes(source, { mode: 'transform' }), shortCircuit: true };
  }
  return nextLoad(url, context);
}
