import { lstatSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { dirname, isAbsolute, resolve } from 'node:path';
import { generateSigningKeys, replaceEnvLines, SIGNING_KEY_NAMES } from './keys.mjs';
import { isMain } from './is-main.mjs';

// Stage a copy of the private Compose environment with a new JWT secret and
// freshly signed anon/service keys. Only those three lines change. The caller
// (rotate-keys.sh) applies the database side and then renames the staged file
// over compose.env, so a failure before that rename leaves the live file intact.
export function stageRotatedEnv(envPath, stagedPath) {
  if (!isAbsolute(envPath) || !isAbsolute(stagedPath)) throw new Error('Configuration paths must be absolute.');
  if (dirname(resolve(stagedPath)) !== dirname(resolve(envPath)) || resolve(stagedPath) === resolve(envPath)) throw new Error('Staged configuration must be a different file in the compose.env directory.');
  const st = lstatSync(envPath, { throwIfNoEntry: false });
  if (!st?.isFile() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('Private configuration must be an owned regular file with mode 0600.');
  const current = readFileSync(envPath, 'utf8');
  const updated = replaceEnvLines(current, generateSigningKeys());
  rmSync(stagedPath, { force: true });
  writeFileSync(stagedPath, updated, { mode: 0o600, flag: 'wx' });
  return { staged: resolve(stagedPath), replaced: [...SIGNING_KEY_NAMES] };
}

if (isMain(import.meta.url)) {
  try {
    const [envPath, stagedPath, ...rest] = process.argv.slice(2);
    if (!envPath || !stagedPath || rest.length) throw new Error('Usage: node scripts/rotate-keys.mjs /abs/config/compose.env /abs/config/compose.env.rotating');
    stageRotatedEnv(envPath, stagedPath);
    console.log('Staged a new JWT secret with new anon and service keys.');
  } catch (error) { console.error(`Rotate keys: ${error.message}`); process.exitCode = 1; }
}
