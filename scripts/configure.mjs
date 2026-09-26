import { existsSync, readFileSync, writeFileSync, mkdirSync, statSync, lstatSync, realpathSync, readdirSync, chmodSync, renameSync, rmSync } from 'node:fs';
import { randomBytes, randomUUID, createHmac } from 'node:crypto';
import { resolve, isAbsolute, sep, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

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
    const match = line.match(/^([A-Z][A-Z0-9_]*)=([^\r\n#]*)$/);
    if (!match) throw new Error('Provider file must contain KEY=value lines without quotes or comments.');
    values[match[1]] = match[2];
  }
  if (values.SMS_PROVIDER !== 'msg91') throw new Error('SMS_PROVIDER=msg91 is required.');
  const keys = ['SMS_PROVIDER', 'MSG91_AUTH_KEY', 'MSG91_TEMPLATE_ID', 'MSG91_PE_ID', 'MSG91_SENDER_ID'];
  for (const key of keys) if (!values[key] || /^(your-|changeme|fake_)/i.test(values[key])) throw new Error(`Missing production provider setting: ${key}.`);
  for (const key of Object.keys(values)) if (!keys.includes(key)) throw new Error(`Unsupported provider setting: ${key}.`);
  return values;
}

export function configure(root, { stateDir, apiUrl, appUrl, company, providerEnv, faultAfterManifest = false } = {}) {
  if (!stateDir || !isAbsolute(stateDir)) throw new Error('--state-dir must be an absolute path outside the checkout.');
  const checkout = realpathSync(root);
  const state = resolve(stateDir);
  if (state === checkout || state.startsWith(checkout + sep)) throw new Error('State directory must be outside the checkout.');
  const parent = realpathSync(resolve(state, '..'));
  if (parent === checkout || parent.startsWith(checkout + sep)) throw new Error('State directory must be outside the checkout.');
  const envPath = join(state, 'config', 'compose.env');
  const manifestPath = join(state, 'public', 'instance.json');
  if (existsSync(state)) {
    const st = lstatSync(state);
    if (!st.isDirectory() || realpathSync(state).startsWith(checkout + sep) || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('State directory must be owned by this user and mode 0700.');
    if (existsSync(envPath) && existsSync(manifestPath)) {
      if (!lstatSync(envPath).isFile() || !lstatSync(manifestPath).isFile()) throw new Error('Operator configuration files must be regular files.');
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
      if (apiUrl && canonicalOrigin(apiUrl, '--api-url') !== manifest.canonicalOrigin) throw new Error('Existing canonical origin differs; refusing to replace instance identity.');
      if (appUrl && !readFileSync(envPath, 'utf8').includes(`SITE_URL=${canonicalOrigin(appUrl, '--app-url')}\n`)) throw new Error('Existing app origin differs; refusing to replace trusted browser origin.');
      if (company && company !== manifest.companyName) throw new Error('Existing company differs; refusing to replace instance identity.');
      return { created: false, state, manifest };
    }
    if (readdirSync(state).length) throw new Error('State directory is partially initialized; inspect it before retrying.');
  }
  if (!apiUrl || !company || !providerEnv) throw new Error('Fresh setup requires --api-url, --company and --provider-env.');
  const canonical = canonicalOrigin(apiUrl, '--api-url');
  const application = appUrl ? canonicalOrigin(appUrl, '--app-url') : canonical;
  if (company.length > 120 || !/^[^\x00-\x1f]+$/.test(company)) throw new Error('--company must be a printable name of at most 120 characters.');
  const provider = providerValues(providerEnv, checkout);
  const secret = randomBytes(48).toString('hex');
  const jwt = role => {
    const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');
    const body = `${part({ alg: 'HS256', typ: 'JWT' })}.${part({ iss: 'supabase', role, exp: Math.floor(Date.now() / 1000) + 10 * 365 * 86400 })}`;
    return `${body}.${createHmac('sha256', secret).update(body).digest('base64url')}`;
  };
  const manifest = { schemaVersion: 1, instanceId: randomUUID(), displayName: company, companyName: company,
    canonicalOrigin: canonical, supportedApiVersions: ['1'], minimumClientVersion: '0.1.0',
    capabilities: { sensors: false, printing: false } };
  const values = { AUTH_MODE: 'operator', APP_ENV: 'production', BIND_ADDRESS: '127.0.0.1',
    SMS_PRODUCTION_MODE: 'true', SUPABASE_PUBLIC_URL: canonical, API_EXTERNAL_URL: canonical,
    SITE_URL: application, ADDITIONAL_REDIRECT_URLS: application, CORS_ALLOWED_ORIGIN: application,
    WAREHOUSE_DB_PATH: join(state, 'data', 'db'), WAREHOUSE_STORAGE_PATH: join(state, 'data', 'storage'),
    WAREHOUSE_MANIFEST_PATH: manifestPath, WAREHOUSE_PROJECT_NAME: `warehouse-${manifest.instanceId.slice(0, 12)}`,
    POSTGRES_PASSWORD: randomBytes(32).toString('hex'),
    JWT_SECRET: secret, ANON_KEY: jwt('anon'), SERVICE_ROLE_KEY: jwt('service_role'),
    SECRET_KEY_BASE: randomBytes(64).toString('hex'), VAULT_ENC_KEY: randomBytes(16).toString('hex'), ...provider };
  for (const key of ['DASHBOARD_PASSWORD', 'GRAFANA_ADMIN_PASS', 'CUPS_ADMIN_PASSWORD',
    'LOGFLARE_LOGGER_BACKEND_API_KEY', 'LOGFLARE_PUBLIC_ACCESS_TOKEN',
    'LOGFLARE_PRIVATE_ACCESS_TOKEN', 'LOGFLARE_API_KEY']) values[key] = randomBytes(32).toString('hex');
  let template = readFileSync(resolve(root, '.env.example'), 'utf8');
  for (const [key, value] of Object.entries(values)) {
    if (/[$\r\n#]/.test(value)) throw new Error(`Unsupported character in ${key}.`);
    const line = new RegExp(`^${key}=.*$`, 'm');
    if (!line.test(template)) throw new Error(`Missing template variable: ${key}`);
    template = template.replace(line, () => `${key}=${value}`);
  }
  const stage = `${state}.installing-${randomBytes(8).toString('hex')}`;
  mkdirSync(stage, { mode: 0o700 });
  try {
    for (const path of ['config', 'public', 'data', 'data/db', 'data/storage']) mkdirSync(join(stage, path), { recursive: true, mode: 0o700 });
    chmodSync(stage, 0o700);
    writeFileSync(join(stage, 'public/instance.json'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o644, flag: 'wx' });
    if (faultAfterManifest) throw new Error('Injected failure after manifest staging.');
    writeFileSync(join(stage, 'config/compose.env'), template, { mode: 0o600, flag: 'wx' });
    renameSync(stage, state);
  } catch (error) { rmSync(stage, { recursive: true, force: true }); throw error; }
  return { created: true, state, manifest };
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
    console.log(result.created ? 'Created operator state and private credentials.' : 'Preserved existing operator state unchanged.');
  } catch (error) { console.error(`Configure: ${error.message}`); process.exitCode = 1; }
}
