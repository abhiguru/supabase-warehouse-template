import { existsSync, readFileSync, writeFileSync, mkdirSync, lstatSync, realpathSync, readdirSync, chmodSync, renameSync, rmSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import { resolve, isAbsolute, sep, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';
import { generateSigningKeys, replaceEnvLines } from './keys.mjs';

export function canonicalOrigin(value, name = 'URL') {
  let url;
  try { url = new URL(value); } catch { throw new Error(`${name} must be an HTTPS origin.`); }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.pathname !== '/' || url.search || url.hash || url.port) throw new Error(`${name} must be an HTTPS origin without credentials, path or port.`);
  return url.origin;
}

function providerValues(path, checkout) {
  if (!isAbsolute(path) || resolve(path).startsWith(checkout + sep) || realpathSync(path).startsWith(checkout + sep)) throw new Error('--provider-env must be an absolute file outside the checkout.');
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (!st?.isFile() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('Provider file must be owned by this user and mode 0600.');
  const values = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    if (!line.trim() || line.startsWith('#')) continue;
    const match = line.match(/^([A-Z][A-Z0-9_]*)=([^\s'"`\\$#\r\n]+)$/);
    if (!match) throw new Error('Provider file must contain KEY=value lines without quotes or comments.');
    values[match[1]] = match[2];
  }
  if (values.SMS_PROVIDER !== 'msg91') throw new Error('SMS_PROVIDER=msg91 is required.');
  const keys = ['SMS_PROVIDER', 'MSG91_AUTH_KEY', 'MSG91_TEMPLATE_ID', 'MSG91_PE_ID', 'MSG91_SENDER_ID'];
  for (const key of keys) if (!values[key] || /^(your-|changeme|fake_)/i.test(values[key])) throw new Error(`Missing production provider setting: ${key}.`);
  for (const key of Object.keys(values)) if (!keys.includes(key)) throw new Error(`Unsupported provider setting: ${key}.`);
  return values;
}

// Replace a private file through a same-directory temporary so readers see
// either the old or the new content, never a partial write.
function replaceFileAtomically(path, text) {
  const stage = `${path}.${randomBytes(8).toString('hex')}`;
  writeFileSync(stage, text, { mode: 0o600, flag: 'wx' });
  try { renameSync(stage, path); } catch (error) { rmSync(stage, { force: true }); throw error; }
}

// The backup key signs every backup (scripts/backup-key.sh) and is never part
// of one: the operator keeps a copy off the machine for a lost-host restore.
export function createBackupKey(configDir) {
  const path = join(configDir, 'backup.key');
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st) {
    if (!st.isFile() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('config/backup.key must be an owned regular file with mode 0600.');
    return false;
  }
  writeFileSync(path, randomBytes(32).toString('hex') + '\n', { mode: 0o600, flag: 'wx' });
  return true;
}

export function configure(root, { stateDir, apiUrl, appUrl, company, providerEnv, faultAfterManifest = false } = {}) {
  if (!stateDir || !isAbsolute(stateDir)) throw new Error('--state-dir must be an absolute path outside the checkout.');
  const checkout = realpathSync(root);
  const state = resolve(stateDir);
  if (state === checkout || state.startsWith(checkout + sep)) throw new Error('State directory must be outside the checkout.');
  const parent = realpathSync(resolve(state, '..'));
  if (parent === checkout || parent.startsWith(checkout + sep)) throw new Error('State directory must be outside the checkout.');
  if (parent !== resolve(state, '..')) throw new Error('State directory parent must not use a symlink.');
  const envPath = join(state, 'config', 'compose.env');
  const manifestPath = join(state, 'public', 'instance.json');
  const stateStat = lstatSync(state, { throwIfNoEntry: false });
  if (stateStat) {
    const st = stateStat;
    if (!st.isDirectory() || realpathSync(state) !== state || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('State directory must be owned by this user, mode 0700, and not use a symlink.');
    if (existsSync(envPath) && existsSync(manifestPath)) {
      for (const path of [join(state, 'config'), join(state, 'public'), join(state, 'data')]) {
        const part = lstatSync(path, { throwIfNoEntry: false });
        if (!part?.isDirectory() || part.uid !== process.getuid() || (part.mode & 0o077)) throw new Error('Operator state directories must be owned by this user and private.');
      }
      for (const path of [join(state, 'data/db'), join(state, 'data/storage')]) {
        if (!lstatSync(path, { throwIfNoEntry: false })?.isDirectory()) throw new Error('Operator data paths must be regular directories.');
      }
      const configStat = lstatSync(envPath);
      const manifestStat = lstatSync(manifestPath);
      if (!configStat.isFile() || configStat.uid !== process.getuid() || (configStat.mode & 0o077) || !manifestStat.isFile() || manifestStat.uid !== process.getuid()) throw new Error('Operator configuration files must be owned regular files; credentials must be private.');
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
      if (apiUrl && canonicalOrigin(apiUrl, '--api-url') !== manifest.canonicalOrigin) throw new Error('Existing canonical origin differs; refusing to replace instance identity.');
      if (appUrl && !readFileSync(envPath, 'utf8').includes(`SITE_URL=${canonicalOrigin(appUrl, '--app-url')}\n`)) throw new Error('Existing app origin differs; refusing to replace trusted browser origin.');
      if (company && company !== manifest.companyName) throw new Error('Existing company differs; refusing to replace instance identity.');
      // A rerun may replace only the SMS provider lines; identity, paths and
      // signing keys are preserved. Unchanged values leave the file bytes intact.
      let providerUpdated = false;
      if (providerEnv) {
        const provider = providerValues(providerEnv, checkout);
        const current = readFileSync(envPath, 'utf8');
        const updated = replaceEnvLines(current, provider);
        if (updated !== current) { replaceFileAtomically(envPath, updated); providerUpdated = true; }
      }
      // An installation made before signed backups gets its backup key here;
      // an existing key is never replaced.
      const backupKeyCreated = createBackupKey(join(state, 'config'));
      return { created: false, state, manifest, providerUpdated, backupKeyCreated };
    }
    if (readdirSync(state).length) throw new Error('State directory is partially initialized; inspect it before retrying.');
  }
  if (!apiUrl || !company || !providerEnv) throw new Error('Fresh setup requires --api-url, --company and --provider-env.');
  const canonical = canonicalOrigin(apiUrl, '--api-url');
  const application = appUrl ? canonicalOrigin(appUrl, '--app-url') : canonical;
  if (company.length > 120 || !/^[^\x00-\x1f]+$/.test(company)) throw new Error('--company must be a printable name of at most 120 characters.');
  const provider = providerValues(providerEnv, checkout);
  const manifest = { schemaVersion: 1, instanceId: randomUUID(), displayName: company, companyName: company,
    canonicalOrigin: canonical, supportedApiVersions: ['1'], minimumClientVersion: '0.1.0',
    capabilities: { sensors: false, printing: false } };
  const values = { AUTH_MODE: 'operator', APP_ENV: 'production', BIND_ADDRESS: '127.0.0.1',
    SMS_PRODUCTION_MODE: 'true', SUPABASE_PUBLIC_URL: canonical, API_EXTERNAL_URL: canonical,
    SITE_URL: application, ADDITIONAL_REDIRECT_URLS: application, CORS_ALLOWED_ORIGIN: application,
    WAREHOUSE_DB_PATH: join(state, 'data', 'db'), WAREHOUSE_STORAGE_PATH: join(state, 'data', 'storage'),
    WAREHOUSE_MANIFEST_PATH: manifestPath, WAREHOUSE_PROJECT_NAME: `warehouse-${manifest.instanceId.slice(0, 12)}`,
    POSTGRES_PASSWORD: randomBytes(32).toString('hex'), ...generateSigningKeys(),
    SECRET_KEY_BASE: randomBytes(64).toString('hex'), VAULT_ENC_KEY: randomBytes(16).toString('hex'), ...provider };
  for (const key of ['DASHBOARD_PASSWORD', 'GRAFANA_ADMIN_PASS', 'CUPS_ADMIN_PASSWORD']) values[key] = randomBytes(32).toString('hex');
  const template = replaceEnvLines(readFileSync(resolve(root, '.env.example'), 'utf8'), values);
  const stage = `${state}.installing-${randomBytes(8).toString('hex')}`;
  mkdirSync(stage, { mode: 0o700 });
  try {
    for (const path of ['config', 'public', 'data', 'data/db', 'data/storage']) mkdirSync(join(stage, path), { recursive: true, mode: 0o700 });
    chmodSync(stage, 0o700);
    writeFileSync(join(stage, 'public/instance.json'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o644, flag: 'wx' });
    if (faultAfterManifest) throw new Error('Injected failure after manifest staging.');
    writeFileSync(join(stage, 'config/compose.env'), template, { mode: 0o600, flag: 'wx' });
    createBackupKey(join(stage, 'config'));
    renameSync(stage, state);
  } catch (error) { rmSync(stage, { recursive: true, force: true }); throw error; }
  return { created: true, state, manifest, backupKeyCreated: true };
}

export function parseConfigureArgs(args) {
  const options = {};
  const names = { '--state-dir': 'stateDir', '--api-url': 'apiUrl', '--app-url': 'appUrl', '--company': 'company', '--provider-env': 'providerEnv' };
  for (let i = 0; i < args.length; i += 2) {
    if (!names[args[i]] || !args[i + 1]) throw new Error('Usage: --state-dir ABSOLUTE [--api-url HTTPS --app-url HTTPS --company NAME --provider-env ABSOLUTE]');
    options[names[args[i]]] = args[i + 1];
  }
  return options;
}

if (isMain(import.meta.url)) {
  try {
    const result = configure(fileURLToPath(new URL('..', import.meta.url)), parseConfigureArgs(process.argv.slice(2)));
    console.log(result.created ? 'Created operator state and private credentials.'
      : result.providerUpdated ? 'Updated MSG91 provider settings in existing operator state.'
        : 'Preserved existing operator state unchanged.');
    if (result.backupKeyCreated) console.log(`Created the backup key ${join(result.state, 'config', 'backup.key')}. Backups are signed with it and a lost-host restore needs it: keep a copy away from this machine and from the backup drive.`);
  } catch (error) { console.error(`Configure: ${error.message}`); process.exitCode = 1; }
}
