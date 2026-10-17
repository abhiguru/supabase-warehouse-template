import { existsSync, readFileSync, writeFileSync, mkdirSync, lstatSync, statSync, realpathSync, readdirSync, chmodSync, renameSync, rmSync, linkSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import { resolve, isAbsolute, sep, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';
import { generateSigningKeys, replaceEnvLines } from './keys.mjs';
import { KEY_SET_MAX_BYTES, holdsPrivateKey, usableKeys } from './central-key-set.mjs';
import { placeMonitoringConfig, readAlertWebhook } from './monitoring-config.mjs';

export function canonicalOrigin(value, name = 'URL') {
  let url;
  try { url = new URL(value); } catch { throw new Error(`${name} must be an HTTPS origin.`); }
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.pathname !== '/' || url.search || url.hash || url.port) throw new Error(`${name} must be an HTTPS origin without credentials, path or port.`);
  return url.origin;
}

// Central sign-in (docs/CENTRAL_LOGIN.md): the association's token issuer and
// its public keys, either as an address the facility fetches or as a file that
// is copied into the state. The issuer goes with exactly one of the two; `off`
// as the issuer empties everything. Returns null when no option was given
// (leave the state as it is), else the three compose.env values and, for a
// key file, its bytes. The issuer is kept exactly as typed, because the
// facility compares it with the token's `iss` as a string.
export const CENTRAL_KEY_FILE = 'central-jwks.json';
export function centralValues(centralIssuer, centralJwksUrl, centralJwksFile) {
  if (centralIssuer === undefined && centralJwksUrl === undefined && centralJwksFile === undefined) return null;
  if (centralIssuer === 'off') {
    if (centralJwksUrl !== undefined || centralJwksFile !== undefined) throw new Error('--central-issuer off turns central sign-in off; leave out --central-jwks-url and --central-jwks-file.');
    return { values: { CENTRAL_ISSUER: '', CENTRAL_JWKS_URL: '', CENTRAL_JWKS_FILE: '' }, keyFile: null };
  }
  if (!centralIssuer || (centralJwksUrl === undefined) === (centralJwksFile === undefined) || centralJwksUrl === '' || centralJwksFile === '') {
    throw new Error('Central sign-in needs --central-issuer with exactly one of --central-jwks-url and --central-jwks-file (or --central-issuer off).');
  }
  const addresses = [['CENTRAL_ISSUER', centralIssuer, '--central-issuer']];
  if (centralJwksUrl !== undefined) addresses.push(['CENTRAL_JWKS_URL', centralJwksUrl, '--central-jwks-url']);
  for (const [name, value, option] of addresses) {
    let url;
    try { url = new URL(value); } catch { throw new Error(`${option} must be an https:// address.`); }
    // The same characters a provider value may hold, so the line reads back unchanged from compose.env.
    if (!value.startsWith('https://') || url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.hash
      || value.length > 255 || !/^[^\s'"`\\$#\r\n]+$/.test(value)) {
      throw new Error(`${option} must be an https:// address without credentials, fragment, spaces, quotes, backslash, $ or #.`);
    }
    if (name === 'CENTRAL_ISSUER' && url.search) throw new Error('--central-issuer must not carry a query.');
  }
  if (centralJwksUrl !== undefined) return { values: { CENTRAL_ISSUER: centralIssuer, CENTRAL_JWKS_URL: centralJwksUrl, CENTRAL_JWKS_FILE: '' }, keyFile: null };
  return { values: { CENTRAL_ISSUER: centralIssuer, CENTRAL_JWKS_URL: '', CENTRAL_JWKS_FILE: CENTRAL_KEY_FILE }, keyFile: centralKeyFile(centralJwksFile) };
}

// The facility's own extra code (--central-local-code on|off; owner decision of
// 2026-10-15): with it on, this facility asks for an SMS code of its own at
// every central sign-in; off (the default) leaves the association's sign-in
// alone. Returns the CENTRAL_LOCAL_CODE line to write, or {} to leave the state
// as it is: a rerun without the flag keeps the stored value, exactly as the
// other central lines are kept, and only `--central-issuer off` clears it (it
// is meaningless without central sign-in). `on` is refused unless central
// sign-in is configured, in this call or already in the state (`current` is
// the text of an existing compose.env, null on a fresh setup).
export function centralLocalCodeValues(flag, central, current) {
  if (flag !== undefined && flag !== 'on' && flag !== 'off') throw new Error('--central-local-code must be on or off.');
  const stored = current ? current.match(/^CENTRAL_LOCAL_CODE=(.*)$/m)?.[1] ?? '' : '';
  const issuer = central ? central.values.CENTRAL_ISSUER : (current?.match(/^CENTRAL_ISSUER=(.*)$/m)?.[1] ?? '');
  if (flag === 'on') {
    if (!issuer) throw new Error('--central-local-code on needs central sign-in: also give --central-issuer with --central-jwks-url or --central-jwks-file, or set it up first.');
    return { CENTRAL_LOCAL_CODE: 'on' };
  }
  if ((flag === 'off' || (central && !issuer)) && stored) return { CENTRAL_LOCAL_CODE: '' };
  return {};
}

// The bytes of a key file the operator received from the association, after
// the checks the edge function applies to a fetched key set, plus one: a file
// that holds private key material is refused outright.
function centralKeyFile(path) {
  if (!isAbsolute(path)) throw new Error('--central-jwks-file must be an absolute path.');
  const st = statSync(path, { throwIfNoEntry: false });
  if (!st?.isFile()) throw new Error('--central-jwks-file must be a readable regular file.');
  if (st.size > KEY_SET_MAX_BYTES) throw new Error('--central-jwks-file is larger than 64 KB.');
  const bytes = readFileSync(path);
  if (bytes.length > KEY_SET_MAX_BYTES) throw new Error('--central-jwks-file is larger than 64 KB.');
  let document;
  try { document = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)); } catch { throw new Error('--central-jwks-file is not a JSON key set.'); }
  if (holdsPrivateKey(document)) throw new Error('--central-jwks-file holds private key material (a "d" member). Ask the association for its public key set; nothing was copied.');
  try { usableKeys(document); } catch (error) { throw new Error(`--central-jwks-file is not usable: ${error.message}.`); }
  return bytes;
}

// Puts the key file into the state's public directory (mode 0644, through a
// same-directory temporary), or removes it. Returns whether anything changed.
function placeCentralKeyFile(publicDir, bytes) {
  const path = join(publicDir, CENTRAL_KEY_FILE);
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st && !st.isFile()) throw new Error(`public/${CENTRAL_KEY_FILE} must be a regular file.`);
  if (!bytes) {
    if (st) rmSync(path);
    return Boolean(st);
  }
  if (st && (st.mode & 0o777) === 0o644 && readFileSync(path).equals(bytes)) return false;
  const stage = join(publicDir, `.${CENTRAL_KEY_FILE}.${randomBytes(8).toString('hex')}`);
  writeFileSync(stage, bytes, { mode: 0o644, flag: 'wx' });
  try { chmodSync(stage, 0o644); renameSync(stage, path); } catch (error) { rmSync(stage, { force: true }); throw error; }
  return true;
}

// Sets the central lines of an existing compose.env; a state written by a
// release that had no such lines gets them appended.
function setCentralLines(text, values) {
  let result = text;
  for (const key of Object.keys(values)) {
    if (!new RegExp(`^${key}=.*$`, 'm').test(result)) result += `${result.endsWith('\n') ? '' : '\n'}${key}=\n`;
  }
  return replaceEnvLines(result, values);
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
// It is written to a temporary file and linked into place, so an interrupted
// setup leaves no key file at all rather than an empty one that every later
// command finds and then rejects.
export function createBackupKey(configDir) {
  const path = join(configDir, 'backup.key');
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st) {
    if (!st.isFile() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('config/backup.key must be an owned regular file with mode 0600.');
    if (st.size > 0) {
      if (!/^[0-9a-f]{64}\r?\n?$/.test(readFileSync(path, 'utf8'))) throw new Error('config/backup.key does not hold a backup key (64 hexadecimal characters on one line). Put your copy of the key back; if no backup was ever signed with this file, remove it and run setup again.');
      return false;
    }
    // Empty: the remnant of a creation that was interrupted before this was atomic. It signed nothing.
    rmSync(path);
  }
  const stage = join(configDir, `.backup.key.${randomBytes(8).toString('hex')}`);
  writeFileSync(stage, randomBytes(32).toString('hex') + '\n', { mode: 0o600, flag: 'wx' });
  // link, not rename: it fails instead of replacing a key that appeared in the meantime.
  try { linkSync(stage, path); } finally { rmSync(stage, { force: true }); }
  return true;
}

export function configure(root, { stateDir, apiUrl, appUrl, company, providerEnv, centralIssuer, centralJwksUrl, centralJwksFile, centralLocalCode, alertWebhookFile, faultAfterManifest = false } = {}) {
  const central = centralValues(centralIssuer, centralJwksUrl, centralJwksFile);
  if (centralLocalCode !== undefined && centralLocalCode !== 'on' && centralLocalCode !== 'off') throw new Error('--central-local-code must be on or off.');
  if (!stateDir || !isAbsolute(stateDir)) throw new Error('--state-dir must be an absolute path outside the checkout.');
  const checkout = realpathSync(root);
  // Checked before anything is written: a refused file changes nothing.
  const webhook = readAlertWebhook(alertWebhookFile, checkout);
  // What the result says about it: true (an address was stored), null (removed), undefined (not given). Never the address.
  const webhookReport = typeof webhook === 'string' ? true : webhook;
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
      // A rerun may replace only the SMS provider lines and the central
      // sign-in lines (with the key file); identity, paths and signing keys are preserved.
      // Unchanged values leave the file bytes intact.
      let providerUpdated = false;
      let centralUpdated = false;
      if (providerEnv) {
        const provider = providerValues(providerEnv, checkout);
        const current = readFileSync(envPath, 'utf8');
        const updated = replaceEnvLines(current, provider);
        if (updated !== current) { replaceFileAtomically(envPath, updated); providerUpdated = true; }
      }
      if (central || centralLocalCode !== undefined) {
        const current = readFileSync(envPath, 'utf8');
        // The extra code is decided before anything is written, so a refused flag changes nothing.
        const localCode = centralLocalCodeValues(centralLocalCode, central, current);
        // "Off" on a state that never had the lines changes nothing.
        const absent = !/^CENTRAL_(?:ISSUER|JWKS_URL|JWKS_FILE)=/m.test(current);
        const updated = !central ? setCentralLines(current, localCode)
          : absent && !central.values.CENTRAL_ISSUER ? current : setCentralLines(current, { ...central.values, ...localCode });
        // The key file first: compose.env never names a file that is not there.
        if (central && placeCentralKeyFile(join(state, 'public'), central.keyFile)) centralUpdated = true;
        if (updated !== current) { replaceFileAtomically(envPath, updated); centralUpdated = true; }
      }
      // An installation made before signed backups gets its backup key here;
      // an existing key is never replaced.
      const backupKeyCreated = createBackupKey(join(state, 'config'));
      // The per-installation monitoring files and the textfile directory (docs/MONITORING.md). A state made
      // before they existed gets them here; unchanged files are left alone.
      const project = readFileSync(envPath, 'utf8').match(/^WAREHOUSE_PROJECT_NAME=(.*)$/m)?.[1];
      const monitoringUpdated = placeMonitoringConfig(state, { project, webhook });
      return { created: false, state, manifest, providerUpdated, centralUpdated, backupKeyCreated, monitoringUpdated, webhook: webhookReport };
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
    SECRET_KEY_BASE: randomBytes(64).toString('hex'), VAULT_ENC_KEY: randomBytes(16).toString('hex'), ...provider,
    ...(central?.values ?? {}), ...centralLocalCodeValues(centralLocalCode, central, null) };
  for (const key of ['DASHBOARD_PASSWORD', 'GRAFANA_ADMIN_PASS', 'CUPS_ADMIN_PASSWORD']) values[key] = randomBytes(32).toString('hex');
  const template = replaceEnvLines(readFileSync(resolve(root, '.env.example'), 'utf8'), values);
  const stage = `${state}.installing-${randomBytes(8).toString('hex')}`;
  mkdirSync(stage, { mode: 0o700 });
  try {
    for (const path of ['config', 'public', 'data', 'data/db', 'data/storage']) mkdirSync(join(stage, path), { recursive: true, mode: 0o700 });
    chmodSync(stage, 0o700);
    writeFileSync(join(stage, 'public/instance.json'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o644, flag: 'wx' });
    if (faultAfterManifest) throw new Error('Injected failure after manifest staging.');
    if (central?.keyFile) placeCentralKeyFile(join(stage, 'public'), central.keyFile);
    writeFileSync(join(stage, 'config/compose.env'), template, { mode: 0o600, flag: 'wx' });
    createBackupKey(join(stage, 'config'));
    placeMonitoringConfig(stage, { project: values.WAREHOUSE_PROJECT_NAME, webhook });
    renameSync(stage, state);
  } catch (error) { rmSync(stage, { recursive: true, force: true }); throw error; }
  return { created: true, state, manifest, backupKeyCreated: true, monitoringUpdated: true, webhook: webhookReport };
}

export function parseConfigureArgs(args) {
  const options = {};
  const names = { '--state-dir': 'stateDir', '--api-url': 'apiUrl', '--app-url': 'appUrl', '--company': 'company', '--provider-env': 'providerEnv',
    '--central-issuer': 'centralIssuer', '--central-jwks-url': 'centralJwksUrl', '--central-jwks-file': 'centralJwksFile',
    '--central-local-code': 'centralLocalCode', '--alert-webhook-file': 'alertWebhookFile' };
  for (let i = 0; i < args.length; i += 2) {
    if (!names[args[i]] || !args[i + 1]) throw new Error('Usage: --state-dir ABSOLUTE [--api-url HTTPS --app-url HTTPS --company NAME --provider-env ABSOLUTE] [--central-issuer HTTPS|off (--central-jwks-url HTTPS | --central-jwks-file ABSOLUTE)] [--central-local-code on|off] [--alert-webhook-file ABSOLUTE|off]');
    options[names[args[i]]] = args[i + 1];
  }
  return options;
}

if (isMain(import.meta.url)) {
  try {
    const result = configure(fileURLToPath(new URL('..', import.meta.url)), parseConfigureArgs(process.argv.slice(2)));
    console.log(result.created ? 'Created operator state and private credentials.'
      : result.providerUpdated ? 'Updated MSG91 provider settings in existing operator state.'
        : result.centralUpdated ? 'Updated central sign-in settings in existing operator state.'
          : 'Preserved existing operator state unchanged.');
    if (result.centralUpdated && result.providerUpdated) console.log('Updated central sign-in settings in existing operator state.');
    if (result.monitoringUpdated && !result.created) console.log('Updated the monitoring files in the state (docs/MONITORING.md).');
    if (result.webhook) console.log('Stored the alert webhook address for Alertmanager (mode 0600, in the state).');
    else if (result.webhook === null) console.log('Removed the alert webhook address: Alertmanager keeps alerts on this host only.');
    if (result.backupKeyCreated) console.log(`Created the backup key ${join(result.state, 'config', 'backup.key')}. Backups are signed with it and a lost-host restore needs it: keep a copy away from this machine and from the backup drive.`);
  } catch (error) { console.error(`Configure: ${error.message}`); process.exitCode = 1; }
}
