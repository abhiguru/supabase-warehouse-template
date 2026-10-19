import { createHash, createHmac, pbkdf2Sync, randomBytes } from 'node:crypto';
import { lstatSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, resolve } from 'node:path';
import { replaceEnvLines, retireGraphqlSchema } from './keys.mjs';
import { readEnv } from './doctor-common.mjs';
import { isMain } from './is-main.mjs';

// Per-role database passwords (docs/CONTAINER_SECURITY.md, "Database passwords").
// Every service login has its own generated password in config/compose.env;
// POSTGRES_PASSWORD stays the superuser password (postgres, supabase_admin),
// used by the operator scripts and Supavisor's
// metadata connection.
//   env       the compose.env line
//   role      the PostgreSQL login it is the password of
//   variable  the psql variable scripts/configure-db-roles.sql reads (a verifier)
// A new login (for example a runner role) is one more entry here, one more
// ALTER ROLE line in configure-db-roles.sql and a `${NAME:?…}` reference in
// the Compose file of the service that uses it; tests/db-roles.test.mjs checks
// that the three agree.
export const DB_ROLE_LOGINS = [
  { env: 'DB_PASSWORD_AUTHENTICATOR', role: 'authenticator', variable: 'authenticator_verifier', usedBy: 'PostgREST' },
  { env: 'DB_PASSWORD_STORAGE', role: 'supabase_storage_admin', variable: 'storage_verifier', usedBy: 'Storage' },
  { env: 'DB_PASSWORD_POOLER', role: 'pgbouncer', variable: 'pooler_verifier', usedBy: "Supavisor's pool user" },
];
// The superuser logins; both have POSTGRES_PASSWORD.
export const SUPERUSER_ROLES = [
  { role: 'postgres', variable: 'postgres_verifier' },
  { role: 'supabase_admin', variable: 'supabase_admin_verifier' },
];

const PASSWORD_PATTERN = /^[A-Za-z0-9_-]{32,128}$/;
const newPassword = () => randomBytes(32).toString('hex');

// The values a fresh state gets, and what an existing one lacks.
export function generatedDbValues() {
  return Object.fromEntries(DB_ROLE_LOGINS.map(({ env }) => [env, newPassword()]));
}
export const GENERATED_DB_NAMES = DB_ROLE_LOGINS.map(({ env }) => env);

// compose.env text with every missing (absent or empty) generated value
// added; a value that exists is never replaced. Returns the new text and the
// names that were added.
export function addMissingDbValues(text) {
  const fresh = generatedDbValues();
  let result = text;
  const added = [];
  for (const name of GENERATED_DB_NAMES) {
    const line = result.match(new RegExp(`^${name}=(.*)$`, 'm'));
    if (line && line[1] !== '') continue;
    if (line) result = replaceEnvLines(result, { [name]: fresh[name] });
    else result += `${result === '' || result.endsWith('\n') ? '' : '\n'}${name}=${fresh[name]}\n`;
    added.push(name);
  }
  return { text: result, added };
}

// Refuses a configuration whose values cannot be used: missing, wrong form, or
// a role password that repeats the superuser password or another role's.
export function validateDbValues(env) {
  const seen = new Map([[env.POSTGRES_PASSWORD, 'POSTGRES_PASSWORD']]);
  for (const { env: name } of DB_ROLE_LOGINS) {
    const value = env[name] ?? '';
    if (!PASSWORD_PATTERN.test(value)) throw new Error(`Invalid ${name}: run setup.sh to generate the per-role database passwords.`);
    if (seen.has(value)) throw new Error(`${name} repeats ${seen.get(value)}; every database login needs its own password.`);
    seen.set(value, name);
  }
}

// A SCRAM-SHA-256 verifier in PostgreSQL's stored format (RFC 5802/7677,
// 4096 iterations as PostgreSQL itself uses). ALTER ROLE stores a verifier as
// it is, so the server never sees the password: nothing can log it, and
// pg_stat_statements or pg_stat_activity show only the verifier, with which
// one cannot log in.
export function scramVerifier(password, salt = randomBytes(16), iterations = 4096) {
  const salted = pbkdf2Sync(Buffer.from(password, 'utf8'), salt, iterations, 32, 'sha256');
  const clientKey = createHmac('sha256', salted).update('Client Key').digest();
  const storedKey = createHash('sha256').update(clientKey).digest();
  const serverKey = createHmac('sha256', salted).update('Server Key').digest();
  return `SCRAM-SHA-256$${iterations}:${salt.toString('base64')}$${storedKey.toString('base64')}:${serverKey.toString('base64')}`;
}

// The psql prelude for scripts/configure-db-roles.sql: one `\set` line per
// login. With `superuser`, also the two superuser logins (rotation only).
export function psqlPrelude(env, { superuser = false } = {}) {
  validateDbValues(env);
  const lines = DB_ROLE_LOGINS.map(({ env: name, variable }) => `\\set ${variable} '${scramVerifier(env[name])}'`);
  if (superuser) {
    if (!PASSWORD_PATTERN.test(env.POSTGRES_PASSWORD ?? '')) throw new Error('Invalid POSTGRES_PASSWORD.');
    for (const { variable } of SUPERUSER_ROLES) lines.push(`\\set ${variable} '${scramVerifier(env.POSTGRES_PASSWORD)}'`);
  }
  return `${lines.join('\n')}\n`;
}

// What scripts/db-roles.sh check reads on standard input inside the database
// container: the superuser password, then one `role<TAB>password` line per login.
export function checkInput(env) {
  validateDbValues(env);
  return `${env.POSTGRES_PASSWORD}\n${DB_ROLE_LOGINS.map(({ env: name, role }) => `${role}\t${env[name]}`).join('\n')}\n`;
}

function privateFile(path) {
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isFile() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('Private configuration must be an owned regular file with mode 0600.');
}

// Stage a copy of compose.env with new per-role passwords (and, with
// `superuser`, a new POSTGRES_PASSWORD). Only those lines
// change. scripts/rotate-db-passwords.sh applies the database side first and
// then renames the staged file over compose.env.
export function stageRotatedDbEnv(envPath, stagedPath, { superuser = false } = {}) {
  if (!isAbsolute(envPath) || !isAbsolute(stagedPath)) throw new Error('Configuration paths must be absolute.');
  if (dirname(resolve(stagedPath)) !== dirname(resolve(envPath)) || resolve(stagedPath) === resolve(envPath)) throw new Error('Staged configuration must be a different file in the compose.env directory.');
  privateFile(envPath);
  const current = readFileSync(envPath, 'utf8');
  validateDbValues(readEnv(envPath));
  const values = generatedDbValues();
  if (superuser) values.POSTGRES_PASSWORD = newPassword();
  const updated = replaceEnvLines(current, values);
  rmSync(stagedPath, { force: true });
  writeFileSync(stagedPath, updated, { mode: 0o600, flag: 'wx' });
  return { staged: resolve(stagedPath), replaced: Object.keys(values) };
}

// Adds the missing values to a compose.env in place (through a same-directory
// temporary). Returns the names added (the PGRST_DB_SCHEMAS rewrite is not one of them).
export function addMissingDbValuesToFile(envPath) {
  privateFile(envPath);
  const current = readFileSync(envPath, 'utf8');
  const { text: withValues, added } = addMissingDbValues(current);
  // A backup's compose.env from before migration 103 also names the GraphQL schema, which the restore drops
  // (the migration runs after the replay); both restore paths call this before the database starts.
  const text = retireGraphqlSchema(withValues);
  if (text === current) return added;
  const stage = `${envPath}.${randomBytes(8).toString('hex')}`;
  writeFileSync(stage, text, { mode: 0o600, flag: 'wx' });
  try { renameSync(stage, envPath); } catch (error) { rmSync(stage, { force: true }); throw error; }
  return added;
}

const USAGE = `Usage: node scripts/db-roles.mjs prelude ENV_FILE [--superuser]
       node scripts/db-roles.mjs check-input ENV_FILE
       node scripts/db-roles.mjs stage ENV_FILE STAGED_FILE [--superuser]
       node scripts/db-roles.mjs add-missing ENV_FILE
       node scripts/db-roles.mjs names`;

if (isMain(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    const superuser = args.at(-1) === '--superuser';
    if (superuser) args.pop();
    const [command, ...rest] = args;
    const envFile = path => { if (!path || !isAbsolute(path)) throw new Error(USAGE); privateFile(path); return readEnv(path); };
    if (command === 'prelude' && rest.length === 1) process.stdout.write(psqlPrelude(envFile(rest[0]), { superuser }));
    else if (command === 'check-input' && rest.length === 1 && !superuser) process.stdout.write(checkInput(envFile(rest[0])));
    else if (command === 'stage' && rest.length === 2) {
      const { replaced } = stageRotatedDbEnv(rest[0], rest[1], { superuser });
      console.log(`Staged new values for ${replaced.join(', ')}.`);
    } else if (command === 'add-missing' && rest.length === 1 && !superuser) {
      // configure.mjs's existing-state step on its own, for the restore paths:
      // a backup taken before per-role passwords carries none.
      if (!isAbsolute(rest[0])) throw new Error(USAGE);
      const added = addMissingDbValuesToFile(rest[0]);
      if (added.length) console.log(`Added ${added.join(', ')}: the backup was taken before every database login had its own password.`);
    } else if (command === 'names' && rest.length === 0 && !superuser) console.log(GENERATED_DB_NAMES.join('\n'));
    else throw new Error(USAGE);
  } catch (error) { console.error(`Database roles: ${error.message}`); process.exitCode = 1; }
}
