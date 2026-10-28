// Writes the two small files the app learns about this backend from (served by functions/get-public-config):
//
//   <state>/public/release.json     what this checkout is: tag or `git describe`, commit, the newest applied migration, the time
//   <state>/public/app-compat.json  the oldest app build this backend still answers (copied from app-compat.json of the checkout)
//
//   WAREHOUSE_STATE_DIR=/abs/state node scripts/release-info.mjs write <schemaHead>
//
// scripts/release-info.sh runs it for setup.sh and for restore.sh, after their migrations, so both always describe the code that is
// running. Neither is part of the instance identity: backups do not carry them, and a restore writes them again for its own checkout.
import { chmodSync, lstatSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const VERSION = /^\d+\.\d+\.\d+$/;

function git(root, args) {
  try { return { text: execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim(), error: '' }; } catch (error) {
    return { text: '', error: String(error?.stderr || error?.message || error).trim().split('\n')[0] };
  }
}

// The name goes into release.json and is read back by functions/_shared/release-info.ts, which accepts [A-Za-z0-9_.+-]{1,100} only: a tag
// such as release/1.2 would otherwise be shown to the app as "unknown". Other characters become "-".
export function releaseName(text) {
  return text.replace(/[^A-Za-z0-9_.+-]/g, '-').slice(0, 100);
}

// A source archive has no .git: the release then says "unknown" rather than failing the setup. A checkout that git cannot read (another
// owner: "dubious ownership"; a damaged .git) is "unknown" too, but not silently: `warn` says why.
export function releaseRecord({ root = ROOT, schemaHead, now = new Date(), warn = message => console.error(message) }) {
  if (!schemaHead || !/^[A-Za-z0-9_.-]+$/.test(schemaHead)) throw new Error('The newest applied migration name is missing or not a file name.');
  // --dirty: a checkout with local changes to tracked files is not the tag it started from.
  const described = git(root, ['describe', '--tags', '--always', '--dirty']);
  const commit = git(root, ['rev-parse', 'HEAD']);
  if ((!described.text || !commit.text) && lstatSync(join(root, '.git'), { throwIfNoEntry: false })) {
    warn(`Warning: git could not read the checkout (${described.error || commit.error || 'no answer'}), so release.json says "unknown" for the release. If the checkout belongs to another user, run: git config --global --add safe.directory ${root}`);
  }
  return {
    backendRelease: releaseName(described.text) || 'unknown',
    backendCommit: commit.text || 'unknown',
    schemaHead,
    writtenAt: now.toISOString(),
  };
}

// The compatibility file of the checkout, checked: a malformed one stops the setup before the app is told anything wrong.
export function appCompat(root = ROOT) {
  const document = JSON.parse(readFileSync(join(root, 'app-compat.json'), 'utf8'));
  if (typeof document?.minimumClientVersion !== 'string' || !VERSION.test(document.minimumClientVersion)) {
    throw new Error('app-compat.json must hold minimumClientVersion as MAJOR.MINOR.PATCH.');
  }
  return document;
}

function place(publicDir, name, text) {
  const path = join(publicDir, name);
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st && !st.isFile()) throw new Error(`public/${name} must be a regular file.`);
  const stage = join(publicDir, `.${name}.${randomBytes(8).toString('hex')}`);
  writeFileSync(stage, text, { mode: 0o644, flag: 'wx' });
  try { chmodSync(stage, 0o644); renameSync(stage, path); } catch (error) { rmSync(stage, { force: true }); throw error; }
}

export function writeReleaseFiles({ state, root = ROOT, schemaHead, now }) {
  if (!state || !isAbsolute(state)) throw new Error('Set WAREHOUSE_STATE_DIR to the absolute operator state path.');
  const publicDir = join(state, 'public');
  const st = lstatSync(publicDir, { throwIfNoEntry: false });
  if (!st?.isDirectory() || st.uid !== process.getuid()) throw new Error(`${publicDir} must be a directory owned by this user.`);
  const compat = appCompat(root);
  const record = releaseRecord({ root, schemaHead, now });
  place(publicDir, 'app-compat.json', JSON.stringify(compat, null, 2) + '\n');
  place(publicDir, 'release.json', JSON.stringify(record, null, 2) + '\n');
  return { record, compat };
}

if (isMain(import.meta.url)) {
  try {
    if (process.argv[2] !== 'write' || !process.argv[3]) throw new Error('Usage: WAREHOUSE_STATE_DIR=/absolute/state node scripts/release-info.mjs write <newest migration name>');
    const { record } = writeReleaseFiles({ state: process.env.WAREHOUSE_STATE_DIR, schemaHead: process.argv[3] });
    console.log(`Wrote public/release.json (${record.backendRelease}, schema ${record.schemaHead}) and public/app-compat.json.`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
