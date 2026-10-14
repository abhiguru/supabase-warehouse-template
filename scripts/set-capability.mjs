// Turns one capability of this installation on or off in the public manifest
// (<state>/public/instance.json, `capabilities`), which get-public-config
// serves to the app. The app shows a feature only where its capability is on.
//
//   WAREHOUSE_STATE_DIR=/abs/state node scripts/set-capability.mjs <sensors|printing> <on|off>
//
// Only the one boolean changes; every other byte of the file stays as it is.
// The new file is written next to the old one and renamed over it, keeping its
// mode, so a reader sees either the old or the new manifest, never half of one.
// The manifest is part of every backup, and db:restore refuses a backup whose
// instance.json differs from the state: take a new backup after the change.
import { closeSync, fsyncSync, fchmodSync, lstatSync, openSync, readFileSync, realpathSync, renameSync, rmSync, writeSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { isAbsolute, join } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { isMain } from './is-main.mjs';

export const CAPABILITIES = ['sensors', 'printing'];
const VALUES = { on: true, off: false };
const USAGE = 'Usage: WAREHOUSE_STATE_DIR=/absolute/state node scripts/set-capability.mjs <sensors|printing> <on|off>';

function privateDirectory(path, what) {
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isDirectory() || realpathSync(path) !== path || st.uid !== process.getuid() || (st.mode & 0o077)) {
    throw new Error(`${what} must be a directory owned by this user, mode 0700, and not a symlink: ${path}`);
  }
}

// The manifest path the same way configure.mjs builds it.
export function manifestPath(stateDir) {
  if (!stateDir || !isAbsolute(stateDir)) throw new Error('Set WAREHOUSE_STATE_DIR to the absolute operator state path.');
  privateDirectory(stateDir, 'The operator state');
  privateDirectory(join(stateDir, 'public'), 'The public state directory');
  const path = join(stateDir, 'public', 'instance.json');
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isFile() || st.uid !== process.getuid()) throw new Error(`The manifest must be a regular file owned by this user: ${path}`);
  return path;
}

export function setCapability(stateDir, name, value) {
  if (!CAPABILITIES.includes(name) || !(value in VALUES)) throw new Error(USAGE);
  const path = manifestPath(stateDir);
  const text = readFileSync(path, 'utf8');
  let manifest;
  try { manifest = JSON.parse(text); } catch { throw new Error(`${path} is not valid JSON; it was not changed.`); }
  const capabilities = manifest?.capabilities;
  if (!capabilities || typeof capabilities !== 'object' || Array.isArray(capabilities)
    || Object.values(capabilities).some(flag => typeof flag !== 'boolean') || typeof capabilities[name] !== 'boolean') {
    throw new Error(`${path} has no boolean capabilities.${name}; it was not changed.`);
  }
  const wanted = VALUES[value];
  if (capabilities[name] === wanted) return { changed: false, path, name, enabled: wanted };
  // The capabilities object holds booleans only, so it contains no brace.
  const pattern = new RegExp(`("capabilities"\\s*:\\s*\\{[^{}]*?"${name}"\\s*:\\s*)(true|false)`, 'g');
  const matches = [...text.matchAll(pattern)];
  if (matches.length !== 1) throw new Error(`${path}: capabilities.${name} is not written exactly once; it was not changed.`);
  const at = matches[0].index + matches[0][1].length;
  const updated = text.slice(0, at) + String(wanted) + text.slice(at + matches[0][2].length);
  const expected = { ...manifest, capabilities: { ...capabilities, [name]: wanted } };
  if (!isDeepStrictEqual(JSON.parse(updated), expected)) throw new Error(`${path}: the edit would change more than capabilities.${name}; it was not changed.`);
  const mode = lstatSync(path).mode & 0o7777;
  const stage = `${path}.${randomBytes(8).toString('hex')}`;
  const fd = openSync(stage, 'wx', 0o600);
  try {
    writeSync(fd, updated);
    fchmodSync(fd, mode);
    fsyncSync(fd);
    closeSync(fd);
    renameSync(stage, path);
  } catch (error) {
    try { closeSync(fd); } catch { /* already closed */ }
    rmSync(stage, { force: true });
    throw error;
  }
  return { changed: true, path, name, enabled: wanted };
}

if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.length !== 2) throw new Error(USAGE);
    const result = setCapability(process.env.WAREHOUSE_STATE_DIR, args[0], args[1]);
    if (!result.changed) {
      console.log(`capabilities.${result.name} is already ${args[1]} in ${result.path}; nothing changed.`);
    } else {
      console.log(`Set capabilities.${result.name} ${args[1]} in ${result.path}.`);
      console.log('Restart the function runtime so the app is told: bash scripts/compose.sh restart functions');
      console.log('A backup taken before this change can only be restored with restore-host (npm run db:restore-host);');
      console.log('db:restore refuses a backup whose instance.json differs. Take a new backup now: npm run db:backup');
      if (result.name === 'printing' && result.enabled) console.log('The print routes still answer 503 until printing is accepted (docs/PRINTING.md).');
    }
  } catch (error) { console.error(`set-capability: ${error.message}`); process.exitCode = 1; }
}
