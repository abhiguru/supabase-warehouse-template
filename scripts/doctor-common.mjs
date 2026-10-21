import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, lstatSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, isAbsolute } from 'node:path';
import { KEY_SET_MAX_BYTES, usableKeys } from './central-key-set.mjs';

export function probe(command, args = [], timeoutMs = 15000) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'pipe'] });
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
export function operatorEnvPath() {
  const state = process.env.WAREHOUSE_STATE_DIR;
  if (!state || !isAbsolute(state)) throw new Error('Set WAREHOUSE_STATE_DIR to the installed operator state.');
  return resolve(state, 'config/compose.env');
}
export const root = fileURLToPath(new URL('..', import.meta.url));
export const supportedNode = (version = process.versions.node) => {
  const [major, minor] = version.split('.').map(Number);
  return major > 22 || (major === 22 && minor >= 18);
};

// The one rule for the central sign-in key file (CENTRAL_JWKS_FILE, read by the router from <state>/public/<name>): it must be a
// plain file name, an existing regular file of at most 64 KB, holding a usable JSON key set. Returns null when the file is fine or
// none is configured, else { code, path, detail } with code name | missing | not-file | too-large | not-json | unusable. Each caller
// (doctor.mjs, watch.mjs) words the fault for its reader.
export function centralKeyFault(name, stateDir) {
  if (!name) return null;
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(name)) return { code: 'name', path: name, detail: '' };
  const path = resolve(stateDir, 'public', name);
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return { code: 'missing', path, detail: '' };
  if (!stat.isFile()) return { code: 'not-file', path, detail: '' };
  if (stat.size > KEY_SET_MAX_BYTES) return { code: 'too-large', path, detail: '' };
  let document;
  try { document = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(path))); } catch (error) { return { code: 'not-json', path, detail: error.message }; }
  try { usableKeys(document); } catch (error) { return { code: 'unusable', path, detail: error.message }; }
  return null;
}
