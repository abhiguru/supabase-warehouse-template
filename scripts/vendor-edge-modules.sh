#!/usr/bin/env bash
# Rebuilds functions/vendor: the library the edge functions load (jose), as
# one self-contained file, from the exact npm packages that
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
# The licence of every package the file may contain (the production tree).
node - <<'NODE' > "$out/LICENSES.txt"
const { readFileSync, readdirSync } = require('node:fs');
const lock = JSON.parse(readFileSync('package-lock.json', 'utf8')).packages;
const out = ['Licences of the npm packages built into jose.mjs.',
  'Built by scripts/vendor-edge-modules.sh from scripts/edge-vendor/package-lock.json.', ''];
for (const path of Object.keys(lock).filter(key => key && !lock[key].dev).sort()) {
  const name = path.replace(/^.*node_modules\//, '');
  const file = readdirSync(path).find(entry => /^licen[cs]e(\.md|\.txt)?$/i.test(entry));
  out.push('='.repeat(72), `${name} ${lock[path].version} (${lock[path].license})`, '='.repeat(72), '');
  out.push(file ? readFileSync(`${path}/${file}`, 'utf8').replace(/\r\n/g, '\n').trim() : `No licence file in the package; declared licence: ${lock[path].license}.`, '');
}
process.stdout.write(out.join('\n'));
NODE
(cd "$out" && sha256sum LICENSES.txt jose.mjs > SHA256SUMS)
echo "Wrote $out/jose.mjs, LICENSES.txt and SHA256SUMS."
