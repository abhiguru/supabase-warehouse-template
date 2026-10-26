import { existsSync, readFileSync, writeFileSync, mkdirSync, lstatSync, statSync, realpathSync, readdirSync, chmodSync, renameSync, rmSync, linkSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';
import { resolve, isAbsolute, sep, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { isMain } from './is-main.mjs';
import { generateSigningKeys, replaceEnvLines, updateRestSchemas } from './keys.mjs';
import { KEY_SET_MAX_BYTES, holdsPrivateKey, usableKeys } from './central-key-set.mjs';
import { addMissingDbValues, generatedDbValues } from './db-roles.mjs';
import { isFixtureAddress, isProviderPlaceholder } from './provider-placeholder.mjs';
import { LETTERHEAD_NAMES, readLetterhead } from './letterhead.mjs';
import { LEGACY_WEBHOOK_FILE, WEBHOOK_FILE, placeWebhook, readAlertWebhook } from './alert-webhook.mjs';

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

// Setup tries the key address once (--central-jwks-url) and only warns: a host may be set up offline, and the
// functions container, not this process, does the fetching later. Returns null when the address answered with a
// JSON key list, else the reason in a few words. `fetchImpl` is injectable for tests.
export async function centralKeysFault(url, fetchImpl = fetch) {
  let response;
  try {
    response = await fetchImpl(url, { signal: AbortSignal.timeout(10000), redirect: 'error' });
  } catch (error) {
    // Node's fetch reports only "fetch failed"; the reason (DNS, refused, unreachable) is in error.cause.
    const cause = error.cause ? ` (${error.cause.code ?? ''} ${error.cause.message ?? error.cause})`.replace('( ', '(') : '';
    return `${error.message}${cause}`;
  }
  if (!response.ok) return `HTTP ${response.status}`;
  let document;
  try { document = await response.json(); } catch { return 'the answer is not JSON'; }
  if (!document || typeof document !== 'object' || !Array.isArray(document.keys)) return 'the answer has no "keys" list';
  return null;
}

export async function centralKeysWarning(url, fetchImpl = fetch) {
  const fault = await centralKeysFault(url, fetchImpl);
  return fault === null ? null
    : `Warning: could not fetch the central keys from ${url} (${fault}). Central sign-in answers "temporarily unavailable" until this host can reach it; SMS sign-in is unaffected. See docs/TROUBLESHOOTING.md, "Tunnel and public address".`;
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

// Sets lines of an existing compose.env (the central lines, LETTERHEAD_FILE); a state written by a
// release that had no such lines gets them appended.
function setEnvLines(text, values) {
  let result = text;
  for (const key of Object.keys(values)) {
    if (!new RegExp(`^${key}=.*$`, 'm').test(result)) result += `${result.endsWith('\n') ? '' : '\n'}${key}=\n`;
  }
  return replaceEnvLines(result, values);
}

// The optional letterhead image of the GRN, dispatch, invoice and customer stock PDFs (--letterhead-file ABSOLUTE|off).
// Returns undefined when the flag was not given (leave the state as it is), { name: '', bytes: null } for `off`, else the
// file name to store (letterhead.jpg or letterhead.png, by the file's first bytes) and the bytes. Everything is checked
// before anything is written: a refused file changes nothing.
function letterheadValue(path) {
  if (path === undefined) return undefined;
  if (path === 'off') return { name: '', bytes: null };
  return readLetterhead(path);
}

// Puts the letterhead into the state's public directory (mode 0644, through a same-directory temporary). Returns whether
// anything changed. The file of the other kind is removed by removeOtherLetterheads, after compose.env names the new one.
function placeLetterhead(publicDir, letterhead) {
  for (const name of Object.values(LETTERHEAD_NAMES)) {
    const st = lstatSync(join(publicDir, name), { throwIfNoEntry: false });
    if (st && !st.isFile()) throw new Error(`public/${name} must be a regular file.`);
  }
  const path = join(publicDir, letterhead.name);
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st && (st.mode & 0o777) === 0o644 && readFileSync(path).equals(letterhead.bytes)) return false;
  const stage = join(publicDir, `.${letterhead.name}.${randomBytes(8).toString('hex')}`);
  writeFileSync(stage, letterhead.bytes, { mode: 0o644, flag: 'wx' });
  try { chmodSync(stage, 0o644); renameSync(stage, path); } catch (error) { rmSync(stage, { force: true }); throw error; }
  return true;
}
// Removes the letterhead file(s) except `keep` ('' = all). Returns whether anything was removed.
function removeOtherLetterheads(publicDir, keep) {
  let removed = false;
  for (const name of Object.values(LETTERHEAD_NAMES)) {
    const path = join(publicDir, name);
    if (name !== keep && lstatSync(path, { throwIfNoEntry: false })) { rmSync(path); removed = true; }
  }
  return removed;
}

function providerValues(path, checkout, apiUrl) {
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
  // The same rule as the doctor and the edge function (provider-placeholder.mjs): the fixture sentinel
  // `isolated-` is accepted only for a reserved .test address.
  const fixture = isFixtureAddress(apiUrl);
  for (const key of keys) if (isProviderPlaceholder(values[key], { allowFixtureSentinel: fixture })) throw new Error(`Missing production provider setting: ${key}.`);
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

// --gateway-port: the loopback port of this installation's gateway (GATEWAY_HTTP_PORT; KONG_HTTP_PORT before the gateway was nginx).
// A compose.env that still has the old name keeps working (docker-compose.yml and the readers accept both); when the port is
// changed the line is written under the new name and the old line is removed, so the two never disagree.
export function withGatewayPort(text, port) {
  const hasNew = /^GATEWAY_HTTP_PORT=/m.test(text);
  const renamed = hasNew ? text.replace(/^KONG_HTTP_PORT=.*\n?/m, '') : text.replace(/^KONG_HTTP_PORT=.*$/m, `GATEWAY_HTTP_PORT=${port}`);
  return replaceEnvLines(renamed, { GATEWAY_HTTP_PORT: port });
}
// Every rerun of setup renames a compose.env line that has only the old name (KONG_HTTP_PORT, a state from the Kong gateway) to
// GATEWAY_HTTP_PORT, in place and with the same value, whether or not --gateway-port was given; Compose reads the same port from either
// name, so nothing is recreated. A file that has GATEWAY_HTTP_PORT already (renamed earlier, or both lines by hand) is left as it is.
// This is what lets a later release drop the KONG_HTTP_PORT fallback of docker-compose.yml, doctor-common.mjs and the check above.
export function renameKongPort(text) {
  return /^GATEWAY_HTTP_PORT=/m.test(text) ? text : text.replace(/^KONG_HTTP_PORT=/m, 'GATEWAY_HTTP_PORT=');
}
export function gatewayPortValue(value) {
  if (value === undefined) return null;
  if (!/^[0-9]{4,5}$/.test(String(value)) || Number(value) < 1024 || Number(value) > 65535) throw new Error('--gateway-port must be a whole number from 1024 to 65535.');
  return String(Number(value));
}
// Test-bind 127.0.0.1:<port> in a child process, so configure() stays synchronous.
function loopbackPortFree(port) {
  const probe = "const s=require('net').createServer();s.once('error',()=>process.exit(1));s.listen(Number(process.argv[1]),'127.0.0.1',()=>s.close(()=>process.exit(0)));";
  return spawnSync(process.execPath, ['-e', probe, port], { timeout: 10000 }).status === 0;
}
function projectContainersRunning(project) {
  const listed = spawnSync('docker', ['ps', '-q', '--filter', `label=com.docker.compose.project=${project}`], { encoding: 'utf8', timeout: 30000 });
  if (listed.status !== 0) throw new Error('Cannot check whether this installation\'s containers are running (docker ps failed); stop them first and retry.');
  return listed.stdout.trim() !== '';
}
// The LAN fallback (scripts/lan.sh) keeps its own lines in compose.env: LAN_ENABLED, LAN_BIND_IP, LAN_HTTP_PORT, LAN_CIDR and a `lan` entry in
// COMPOSE_PROFILES. A rerun of setup changes none of them (the existing-state branch below replaces only the lines it names), so the fallback
// survives every setup, upgrade and restore; lan.sh is the one writer. Its validators are in lan-common.mjs, beside this file's gatewayPortValue.
export { lanAddressValue, lanCidrValue, lanPortValue } from './lan-common.mjs';
export const GATEWAY_PORT_REMINDER = 'Update the Cloudflare Tunnel ingress for this installation to http://127.0.0.1:<port> (deploy/cloudflared-config.example.yml), then restart the tunnel.';

export function configure(root, { stateDir, apiUrl, appUrl, company, providerEnv, centralIssuer, centralJwksUrl, centralJwksFile, centralLocalCode, alertWebhookFile, letterheadFile, gatewayPort, portFree = loopbackPortFree, containersRunning = projectContainersRunning, faultAfterManifest = false } = {}) {
  const port = gatewayPortValue(gatewayPort);
  const central = centralValues(centralIssuer, centralJwksUrl, centralJwksFile);
  const letterhead = letterheadValue(letterheadFile);
  if (centralLocalCode !== undefined && centralLocalCode !== 'on' && centralLocalCode !== 'off') throw new Error('--central-local-code must be on or off.');
  if (!stateDir || !isAbsolute(stateDir)) throw new Error('--state-dir must be an absolute path outside the checkout.');
  const checkout = realpathSync(root);
  // Checked before anything is written: a refused file changes nothing.
  const webhook = readAlertWebhook(alertWebhookFile, checkout);
  // What the result says about it: true (an address was stored), null (removed), undefined (not given). Never the address.
  const state = resolve(stateDir);
  // `off` reports a removal only when a stored URL was there to remove.
  const hadWebhook = [WEBHOOK_FILE, LEGACY_WEBHOOK_FILE].some(file => lstatSync(join(state, file), { throwIfNoEntry: false }));
  const webhookReport = typeof webhook === 'string' ? true : webhook === null && hadWebhook ? null : undefined;
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
      // A rerun may replace only the SMS provider lines, the central sign-in lines (with the key file) and
      // GATEWAY_HTTP_PORT, add generated values that are missing (database passwords, backup key) and place the
      // alert webhook; identity, paths and signing keys are preserved, and so are the LAN fallback lines (scripts/lan.sh).
      // Unchanged values leave the file bytes intact.
      let providerUpdated = false;
      let centralUpdated = false;
      // Every check that can refuse runs before the first write, so a refused flag changes nothing.
      let gatewayPortChanged = false;
      let newPortText = null;
      {
        const text = readFileSync(envPath, 'utf8');
        if (centralLocalCode !== undefined || central) centralLocalCodeValues(centralLocalCode, central, text);
        // Compatibility shim (a compose.env from the Kong gateway): the KONG_HTTP_PORT fallback may be dropped once from_floor (scripts/upgrade-floor.txt) is at or after the release that renames the line on every setup (renameKongPort), because an installation that has passed through it has no such line.
        if (port !== null && (text.match(/^GATEWAY_HTTP_PORT=(.*)$/m)?.[1] || text.match(/^KONG_HTTP_PORT=(.*)$/m)?.[1]) !== port) {
          // Containers keep the published port they were created with, so the change waits for a stopped installation.
          if (containersRunning(text.match(/^WAREHOUSE_PROJECT_NAME=(.*)$/m)?.[1] ?? '')) throw new Error('This installation\'s containers are running; stop them (stop.sh) before changing --gateway-port.');
          if (!portFree(port)) throw new Error(`127.0.0.1:${port} is already in use; choose another --gateway-port.`);
          newPortText = port;
        }
      }
      if (providerEnv) providerValues(providerEnv, checkout, manifest.canonicalOrigin);
      if (providerEnv) {
        const provider = providerValues(providerEnv, checkout, manifest.canonicalOrigin);
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
        const updated = !central ? setEnvLines(current, localCode)
          : absent && !central.values.CENTRAL_ISSUER ? current : setEnvLines(current, { ...central.values, ...localCode });
        // The key file first: compose.env never names a file that is not there.
        if (central && placeCentralKeyFile(join(state, 'public'), central.keyFile)) centralUpdated = true;
        if (updated !== current) { replaceFileAtomically(envPath, updated); centralUpdated = true; }
      }
      // The letterhead image (--letterhead-file). Omitted = keep what is there. The image first, then the line that names it;
      // `off` takes the line out first, so compose.env never names a file that is not there.
      let letterheadUpdated = false;
      if (letterhead) {
        const publicDir = join(state, 'public');
        const current = readFileSync(envPath, 'utf8');
        const stored = current.match(/^LETTERHEAD_FILE=(.*)$/m)?.[1] ?? '';
        if (letterhead.bytes && placeLetterhead(publicDir, letterhead)) letterheadUpdated = true;
        if (stored !== letterhead.name && (letterhead.name || /^LETTERHEAD_FILE=/m.test(current))) {
          replaceFileAtomically(envPath, setEnvLines(current, { LETTERHEAD_FILE: letterhead.name }));
          letterheadUpdated = true;
        }
        if (removeOtherLetterheads(publicDir, letterhead.name)) letterheadUpdated = true;
      }
      // A compose.env from the Kong gateway: the gateway port gets its new name (see renameKongPort).
      const beforeRename = readFileSync(envPath, 'utf8');
      const renamedPort = renameKongPort(beforeRename);
      const gatewayPortRenamed = renamedPort !== beforeRename;
      if (gatewayPortRenamed) replaceFileAtomically(envPath, renamedPort);
      // An installation made before per-role database passwords gets them here
      // (docs/CONTAINER_SECURITY.md, "Database passwords"); a value that exists
      // is never replaced. setup.sh then sets them in the database with
      // scripts/configure-db-roles.sql, and both restore paths run this branch
      // before the database starts, because an older backup carries none.
      const withDbValues = addMissingDbValues(readFileSync(envPath, 'utf8'));
      if (withDbValues.added.length) replaceFileAtomically(envPath, withDbValues.text);
      // An installation made before this release lists the storage schema (and, before migration 103, the GraphQL
      // schema) for PostgREST; the old default becomes `public` (a list the operator changed is kept). setup.sh
      // then recreates rest with the new value.
      const updatedSchemas = updateRestSchemas(readFileSync(envPath, 'utf8'));
      const restSchemasUpdated = updatedSchemas !== readFileSync(envPath, 'utf8');
      if (restSchemasUpdated) replaceFileAtomically(envPath, updatedSchemas);
      // Database logins of removed components (the Auth service, the monitoring login) left a password line in
      // older states. Nothing reads them, so a rerun of setup (every facility reload runs it) removes them.
      // Compatibility shim (a state from before the slimming): the first release with a from_floor after v0.6.1 (scripts/upgrade-floor.txt) may drop it.
      const retiredKeys = ['DB_PASSWORD_AUTH', 'DB_PASSWORD_MONITORING'];
      const beforeRetire = readFileSync(envPath, 'utf8');
      const retiredKeysRemoved = retiredKeys.filter(key => new RegExp(`^${key}=`, 'm').test(beforeRetire));
      if (retiredKeysRemoved.length) replaceFileAtomically(envPath, beforeRetire.split('\n').filter(line => !retiredKeys.some(key => line.startsWith(`${key}=`))).join('\n'));
      // A list the operator changed by hand is kept, but one that still names the removed schema breaks PostgREST.
      const graphqlSchemaKept = /^PGRST_DB_SCHEMAS=.*\bgraphql_public\b/m.test(readFileSync(envPath, 'utf8'));
      // An installation made before signed backups gets its backup key here;
      // an existing key is never replaced.
      const backupKeyCreated = createBackupKey(join(state, 'config'));
      // The Slack webhook (docs/MONITORING.md). One stored at the old path under config/monitoring moves to config/slack-webhook-url.
      const placed = placeWebhook(state, webhook);
      // The gateway port is written last: a refusal above (state faults, the webhook) leaves it unchanged,
      // so the rerun after the fix still reports the change and prints the tunnel reminder.
      if (newPortText !== null) {
        replaceFileAtomically(envPath, withGatewayPort(readFileSync(envPath, 'utf8'), newPortText));
        gatewayPortChanged = true;
      }
      return { created: false, state, manifest, providerUpdated, centralUpdated, letterheadUpdated, letterhead: letterhead === undefined ? undefined : letterhead.bytes ? letterhead.name : letterheadUpdated ? null : undefined, gatewayPortChanged, gatewayPortRenamed, restSchemasUpdated, graphqlSchemaKept, retiredKeysRemoved, dbValuesAdded: withDbValues.added, backupKeyCreated, monitoringUpdated: placed.moved, monitoringCleaned: placed.cleaned, webhook: webhookReport };
    }
    if (readdirSync(state).length) throw new Error('State directory is partially initialized; inspect it before retrying.');
  }
  if (!apiUrl || !company || !providerEnv) throw new Error('Fresh setup requires --api-url, --company and --provider-env.');
  const canonical = canonicalOrigin(apiUrl, '--api-url');
  const application = appUrl ? canonicalOrigin(appUrl, '--app-url') : canonical;
  if (company.length > 120 || !/^[^\u0000-\u001f\u007f-\u009f\u2028\u2029]+$/.test(company)) throw new Error('--company must be a printable name of at most 120 characters.');
  const provider = providerValues(providerEnv, checkout, canonical);
  if (port !== null && !portFree(port)) throw new Error(`127.0.0.1:${port} is already in use; choose another --gateway-port.`);
  const manifest = { schemaVersion: 1, instanceId: randomUUID(), displayName: company, companyName: company,
    canonicalOrigin: canonical, supportedApiVersions: ['1'], minimumClientVersion: '0.1.0',
    capabilities: { sensors: false, printing: false } };
  const values = { AUTH_MODE: 'operator', APP_ENV: 'production',
    SMS_PRODUCTION_MODE: 'true', SUPABASE_PUBLIC_URL: canonical, API_EXTERNAL_URL: canonical,
    SITE_URL: application, CORS_ALLOWED_ORIGIN: application,
    WAREHOUSE_DB_PATH: join(state, 'data', 'db'), WAREHOUSE_STORAGE_PATH: join(state, 'data', 'storage'),
    WAREHOUSE_MANIFEST_PATH: manifestPath, WAREHOUSE_PROJECT_NAME: `warehouse-${manifest.instanceId.slice(0, 12)}`,
    POSTGRES_PASSWORD: randomBytes(32).toString('hex'), ...generatedDbValues(), ...generateSigningKeys(), ...(port === null ? {} : { GATEWAY_HTTP_PORT: port }),
    ...provider,
    ...(central?.values ?? {}), ...centralLocalCodeValues(centralLocalCode, central, null), ...(letterhead?.bytes ? { LETTERHEAD_FILE: letterhead.name } : {}) };
  values.CUPS_ADMIN_PASSWORD = randomBytes(32).toString('hex');
  const template = replaceEnvLines(readFileSync(resolve(root, '.env.example'), 'utf8'), values);
  const stage = `${state}.installing-${randomBytes(8).toString('hex')}`;
  mkdirSync(stage, { mode: 0o700 });
  try {
    for (const path of ['config', 'public', 'data', 'data/db', 'data/storage']) mkdirSync(join(stage, path), { recursive: true, mode: 0o700 });
    chmodSync(stage, 0o700);
    writeFileSync(join(stage, 'public/instance.json'), JSON.stringify(manifest, null, 2) + '\n', { mode: 0o644, flag: 'wx' });
    if (faultAfterManifest) throw new Error('Injected failure after manifest staging.');
    if (central?.keyFile) placeCentralKeyFile(join(stage, 'public'), central.keyFile);
    if (letterhead?.bytes) placeLetterhead(join(stage, 'public'), letterhead);
    writeFileSync(join(stage, 'config/compose.env'), template, { mode: 0o600, flag: 'wx' });
    createBackupKey(join(stage, 'config'));
    placeWebhook(stage, webhook);
    renameSync(stage, state);
  } catch (error) { rmSync(stage, { recursive: true, force: true }); throw error; }
  return { created: true, state, manifest, letterhead: letterhead?.bytes ? letterhead.name : undefined, gatewayPortChanged: port !== null, dbValuesAdded: [], backupKeyCreated: true, monitoringUpdated: true, webhook: webhookReport };
}

export function parseConfigureArgs(args) {
  const options = {};
  const names = { '--state-dir': 'stateDir', '--api-url': 'apiUrl', '--app-url': 'appUrl', '--company': 'company', '--provider-env': 'providerEnv',
    '--central-issuer': 'centralIssuer', '--central-jwks-url': 'centralJwksUrl', '--central-jwks-file': 'centralJwksFile',
    '--central-local-code': 'centralLocalCode', '--alert-webhook-file': 'alertWebhookFile', '--letterhead-file': 'letterheadFile', '--gateway-port': 'gatewayPort' };
  for (let i = 0; i < args.length; i += 2) {
    if (!names[args[i]] || !args[i + 1]) throw new Error('Usage: --state-dir ABSOLUTE [--api-url HTTPS --app-url HTTPS --company NAME --provider-env ABSOLUTE] [--central-issuer HTTPS|off (--central-jwks-url HTTPS | --central-jwks-file ABSOLUTE)] [--central-local-code on|off] [--alert-webhook-file ABSOLUTE|off] [--letterhead-file ABSOLUTE|off] [--gateway-port 1024-65535]');
    options[names[args[i]]] = args[i + 1];
  }
  return options;
}

if (isMain(import.meta.url)) {
  try {
    const options = parseConfigureArgs(process.argv.slice(2));
    const result = configure(fileURLToPath(new URL('..', import.meta.url)), options);
    console.log(result.created ? 'Created operator state and private credentials.'
      : result.providerUpdated ? 'Updated MSG91 provider settings in existing operator state.'
        : result.centralUpdated ? 'Updated central sign-in settings in existing operator state.'
          : result.letterheadUpdated ? 'Updated the letterhead image in existing operator state.'
          : result.gatewayPortChanged ? 'Updated the gateway port in existing operator state.'
            : result.restSchemasUpdated ? 'Updated PostgREST\'s schema list in existing operator state (now `public` only).'
              : result.dbValuesAdded?.length ? 'Preserved existing operator state; only missing generated values were added.'
                : result.retiredKeysRemoved?.length ? `Preserved existing operator state; removed the unused ${result.retiredKeysRemoved.join(', ')}.`
                  : result.gatewayPortRenamed ? 'Preserved existing operator state; renamed KONG_HTTP_PORT to GATEWAY_HTTP_PORT in config/compose.env (the same port).'
                    : 'Preserved existing operator state unchanged.');
    // The first message above names only one change; the schema list is always reported, even beside another change.
    if (result.restSchemasUpdated && (result.providerUpdated || result.centralUpdated || result.gatewayPortChanged)) {
      console.log('Updated PostgREST\'s schema list in existing operator state (now `public` only).');
    }
    if (result.graphqlSchemaKept) console.log('Warning: PGRST_DB_SCHEMAS in config/compose.env still names graphql_public, which migration 103 removes. PostgREST will fail to find that schema; remove it from the list.');
    if (result.centralUpdated && result.providerUpdated) console.log('Updated central sign-in settings in existing operator state.');
    if (result.dbValuesAdded?.length) console.log(`Added ${result.dbValuesAdded.join(', ')} to the existing operator state: every database login now gets its own password (setup applies them to the database).`);
    if (result.monitoringUpdated && !result.created && result.webhook === undefined) console.log('Updated the monitoring files in the state: the Slack webhook is now config/slack-webhook-url (docs/MONITORING.md).');
    if (result.monitoringCleaned && !result.created) console.log('Removed the old Prometheus and Alertmanager files under config/monitoring, metrics and data/alertmanager.');
    if (result.letterhead) console.log(`Stored the letterhead image public/${result.letterhead}: the GRN, dispatch, invoice and customer stock PDFs print it at the top.`);
    else if (result.letterhead === null) console.log('Removed the letterhead image: the GRN, dispatch, invoice and customer stock PDFs are plain again.');
    if (result.webhook) console.log('Stored the Slack webhook for the monitoring checker (mode 0600, in the state).');
    else if (result.webhook === null) console.log('Removed the Slack webhook: the monitoring checker keeps alerts on this host only.');
    if (result.gatewayPortChanged) {
      const gateway = readFileSync(join(result.state, 'config', 'compose.env'), 'utf8').match(/^GATEWAY_HTTP_PORT=(.*)$/m)?.[1];
      console.log(`Gateway port is ${gateway}. ${GATEWAY_PORT_REMINDER.replace('<port>', gateway)}`);
    }
    if (result.backupKeyCreated) console.log(`Created the backup key ${join(result.state, 'config', 'backup.key')}. Backups are signed with it and a lost-host restore needs it: keep a copy away from this machine and from the backup drive.`);
    // After the state is written, so a refused command prints no warning; the warning never fails setup.
    if (options.centralJwksUrl !== undefined && options.centralIssuer !== 'off') {
      const warning = await centralKeysWarning(options.centralJwksUrl);
      if (warning) console.error(warning);
    }
  } catch (error) { console.error(`Configure: ${error.message}`); process.exitCode = 1; }
}
