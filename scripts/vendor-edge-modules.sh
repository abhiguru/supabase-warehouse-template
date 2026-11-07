#!/usr/bin/env bash
# Rebuilds functions/vendor: the libraries the edge functions load (jose, ipp),
# each as one self-contained file, from the exact npm packages that
# scripts/edge-vendor/package-lock.json names. The functions import these files
# by relative path, so the edge runtime downloads nothing when a worker starts.
#
# Run it after changing a version in scripts/edge-vendor/package.json (then
# `npm install --package-lock-only --ignore-scripts` there), and commit the
# result. tests/edge-imports.test.mjs checks the files against SHA256SUMS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$ROOT/scripts/edge-vendor/package.json" "$ROOT/scripts/edge-vendor/package-lock.json" "$work/"
cd "$work"
# No install scripts: esbuild's binary comes from its platform package.
npm ci --ignore-scripts --no-audit --no-fund >/dev/null
out="$ROOT/functions/vendor"
mkdir -p "$out"
build() { # package, output name
  printf "export * from '%s';\n" "$1" > entry.js
  node_modules/.bin/esbuild entry.js --bundle --format=esm --platform=browser --target=es2022 \
    --legal-comments=inline --log-level=warning --outfile="$out/$2"
}
build jose jose.mjs
# ipp is a CommonJS package for Node (it requires http, url and Buffer): its file keeps the node: modules external and
# gets a require() that works in ESM and an explicit Buffer import (edge-runtime gives user code no global Buffer). Used by functions/_shared/ipp-client.ts only (the CUPS path of the print functions).
printf "import ipp from 'ipp';\nexport default ipp;\nexport const Printer = ipp.Printer;\n" > entry.js
node_modules/.bin/esbuild entry.js --bundle --format=esm --platform=node --target=es2022 \
  --banner:js="import { createRequire as __createRequire } from 'node:module'; import { Buffer } from 'node:buffer'; const require = __createRequire(import.meta.url);" \
  --legal-comments=inline --log-level=warning --outfile="$out/ipp.mjs"
# The licence of every package the file may contain (the production tree).
node - <<'NODE' > "$out/LICENSES.txt"
const { readFileSync, readdirSync } = require('node:fs');
const lock = JSON.parse(readFileSync('package-lock.json', 'utf8')).packages;
const out = ['Licences of the npm packages built into jose.mjs and ipp.mjs.',
  'Built by scripts/vendor-edge-modules.sh from scripts/edge-vendor/package-lock.json.', ''];
for (const path of Object.keys(lock).filter(key => key && !lock[key].dev).sort()) {
  const name = path.replace(/^.*node_modules\//, '');
  const file = readdirSync(path).find(entry => /^licen[cs]e(\.md|\.txt)?$/i.test(entry));
  // ipp 2.0.1 declares its licence in the old "licenses" array of its package.json (MIT), not in the lock file's "license".
  const declared = lock[path].license ?? ((JSON.parse(readFileSync(`${path}/package.json`, 'utf8')).licenses ?? []).map(entry => entry.type).join(', ') || 'unknown');
  const authorField = JSON.parse(readFileSync(`${path}/package.json`, 'utf8')).author;
  const author = typeof authorField === 'string' ? authorField.replace(/\s*[<(].*$/, '') : authorField?.name ?? '';
  out.push('='.repeat(72), `${name} ${lock[path].version} (${declared})`, '='.repeat(72), '');
  out.push(file ? readFileSync(`${path}/${file}`, 'utf8').replace(/\r\n/g, '\n').trim() : `No licence file in the package; declared licence: ${declared}${author ? `; author: ${author}` : ''}.`, '');
}
process.stdout.write(out.join('\n'));
NODE
(cd "$out" && sha256sum LICENSES.txt ipp.mjs jose.mjs > SHA256SUMS)
echo "Wrote $out/jose.mjs, ipp.mjs, LICENSES.txt and SHA256SUMS."
