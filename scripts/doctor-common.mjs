import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, lstatSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, isAbsolute } from 'node:path';
import { KEY_SET_MAX_BYTES, usableKeys } from './central-key-set.mjs';
import { LETTERHEAD_MAX_BYTES, LETTERHEAD_NAME_PATTERN, letterheadKind } from './letterhead.mjs';

export function probe(command, args = [], timeoutMs = 15000) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'pipe'] });
  return { ok: result.status === 0, output: result.status === 0 ? result.stdout : '' };
}
// What backups and restores need besides Docker: rsync built with extended-attribute support (scripts/backup.sh and
// scripts/restore.sh copy the stored files with `rsync -X`, which carries each file's content type and cache control) and GNU
// tar with --xattrs (db:restore-host unpacks a backup archive with it). One message per missing tool, each with the command
// that installs it. `run` is probe, replaceable for a test.
export function backupToolProblems(run = probe) {
  const problems = [];
  const rsync = run('rsync', ['--version']);
  if (!rsync.ok) {
    problems.push('rsync (the package rsync) is missing; backups and restores copy the stored files with it. Install it: sudo apt-get install rsync');
  } else {
    // The "Capabilities:" part of the version text lists "xattrs", or "no xattrs" for a build without them. No such part
    // (a very old rsync) tells nothing, and a backup would then say what is wrong.
    const capabilities = /Capabilities:([\s\S]*?)(?:Optimizations:|Checksum list:|$)/.exec(rsync.output)?.[1];
    if (capabilities !== undefined && !/(?<!no )\bxattrs\b/.test(capabilities)) {
      problems.push('this rsync was built without extended-attribute support (its version text lists no "xattrs"), so backups would lose the content type of every stored file. Install the distribution\'s rsync: sudo apt-get install rsync');
    }
  }
  if (!/GNU tar/.test(run('tar', ['--xattrs', '--version']).output)) {
    problems.push('GNU tar with --xattrs support is missing; db:restore-host unpacks a backup archive with it. Install it: sudo apt-get install tar');
  }
  return problems;
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
// The loopback port of the gateway in a compose.env: GATEWAY_HTTP_PORT, or KONG_HTTP_PORT, its name while the gateway was Kong, in
// a file that configure.mjs has not rewritten yet (docker/docker-compose.yml reads both in the same order). An empty line counts as
// unset, as in Compose's `${GATEWAY_HTTP_PORT:-...}`: `||`, not `??`.
export const gatewayPortText = env => env.GATEWAY_HTTP_PORT || env.KONG_HTTP_PORT;
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

// The one rule for the optional letterhead image (LETTERHEAD_FILE, read by the router from <state>/public/<name>): the name is
// letterhead.jpg or letterhead.png, an existing regular file of at most 2 MiB that starts with the signature of its kind.
// Returns null when the file is fine or none is configured, else { code, path } with code name | missing | not-file |
// too-large | not-image. PDFs are made without a faulty letterhead, so callers word this as a warning.
export function letterheadFault(name, stateDir) {
  if (!name) return null;
  if (!LETTERHEAD_NAME_PATTERN.test(name)) return { code: 'name', path: name };
  const path = resolve(stateDir, 'public', name);
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return { code: 'missing', path };
  if (!stat.isFile()) return { code: 'not-file', path };
  if (stat.size > LETTERHEAD_MAX_BYTES) return { code: 'too-large', path };
  const kind = letterheadKind(readFileSync(path));
  if (!kind || name !== `letterhead.${kind}`) return { code: 'not-image', path };
  return null;
}
// The sentence both doctor.mjs and watch.mjs print; includes the command that puts the image back.
export function letterheadProblem(env, stateDir) {
  const fault = letterheadFault(env.LETTERHEAD_FILE, stateDir);
  if (!fault) return '';
  const rerun = 'Put it back by rerunning setup.sh --operator with your usual inputs plus --letterhead-file <the image> (or --letterhead-file off for plain PDFs); see docs/OPERATOR_INSTALL.md, "Letterhead".';
  return {
    name: `LETTERHEAD_FILE must be letterhead.jpg or letterhead.png, not ${fault.path}. ${rerun}`,
    missing: `The letterhead image ${fault.path} is missing: the GRN, dispatch, invoice and customer stock PDFs are made without it. ${rerun}`,
    'not-file': `${fault.path} must be a regular file; the PDFs are made without a letterhead. ${rerun}`,
    'too-large': `${fault.path} is larger than 2 MiB; the PDFs are made without a letterhead. ${rerun}`,
    'not-image': `${fault.path} is not a JPEG or PNG image; the PDFs are made without a letterhead. ${rerun}`,
  }[fault.code];
}
