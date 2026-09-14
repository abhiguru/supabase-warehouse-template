import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, lstatSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export function probe(command, args = []) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'pipe'] });
  return { ok: result.status === 0, output: result.status === 0 ? result.stdout : '' };
}
export function readEnv(path) {
  if (!existsSync(path)) throw new Error('Configuration is missing; run the documented setup first.');
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Configuration must be a regular file, not a symlink.');
  const values = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match) values[match[1]] = match[2].replace(/\s+#.*$/, '').replace(/^['"]|['"]$/g, '');
  }
  return values;
}
export const root = fileURLToPath(new URL('..', import.meta.url));
export const supportedNode = (version = process.versions.node) => {
  const [major, minor] = version.split('.').map(Number);
  return major > 22 || (major === 22 && minor >= 18);
};
