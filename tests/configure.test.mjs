import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, readdirSync, statSync, writeFileSync, rmSync, symlinkSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHmac } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { configure, parseConfigureArgs } from '../scripts/configure.mjs';
import { validateOperatorEnv } from '../scripts/doctor.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';

test('operator state is private, outside checkout, stable on rerun, and has a public-only manifest', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-config-test-'));
  const root = join(scratch, 'checkout');
  const stateDir = join(scratch, 'state');
  const providerEnv = join(scratch, 'provider.env');
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=real-provider-key\nMSG91_TEMPLATE_ID=flow-id\nMSG91_PE_ID=pe-id\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    const options = { stateDir, apiUrl: 'https://api.example.com', appUrl: 'https://app.example.com', company: 'Acme Stores', providerEnv };
    assert.equal(configure(root, options).created, true);
    const envPath = join(stateDir, 'config/compose.env');
    const manifestPath = join(stateDir, 'public/instance.json');
    const before = readFileSync(envPath);
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    assert.equal(configure(root, options).created, false);
    assert.deepEqual(readFileSync(envPath), before);
    assert.equal(statSync(stateDir).mode & 0o777, 0o700);
    assert.equal(statSync(envPath).mode & 0o777, 0o600);
    assert.equal(manifest.companyName, 'Acme Stores');
    assert.equal(manifest.canonicalOrigin, options.apiUrl);
    assert.deepEqual(manifest.capabilities, { sensors: false, printing: false });
    assert.equal(readFileSync(manifestPath, 'utf8').includes('real-provider-key'), false);
    const env = readEnv(envPath);
    assert.equal(validateOperatorEnv(env, stateDir).origin, options.apiUrl);
    // Only secrets a service reads are generated; the template carries no key nothing consumes.
    for (const unused of ['LOGFLARE_API_KEY', 'LOGFLARE_PUBLIC_ACCESS_TOKEN', 'DOCKER_SOCKET_LOCATION', 'ENABLE_PROM_METRICS', 'GOTRUE_EXTERNAL_GOOGLE_ENABLED']) assert.equal(unused in env, false, unused);
    for (const secret of ['POSTGRES_PASSWORD', 'DASHBOARD_PASSWORD', 'GRAFANA_ADMIN_PASS', 'CUPS_ADMIN_PASSWORD']) assert.match(env[secret], /^[0-9a-f]{64}$/, secret);
    // The backup key is created with the state, private, and is not a compose variable.
    const keyPath = join(stateDir, 'config/backup.key');
    assert.match(readFileSync(keyPath, 'utf8'), /^[0-9a-f]{64}\n$/);
    assert.equal(statSync(keyPath).mode & 0o777, 0o600);
    assert.equal(readFileSync(envPath, 'utf8').includes(readFileSync(keyPath, 'utf8').trim()), false);
    const keyBefore = readFileSync(keyPath, 'utf8');
    assert.equal(configure(root, options).backupKeyCreated, false, 'a rerun keeps the key');
    assert.equal(readFileSync(keyPath, 'utf8'), keyBefore);
    // An installation from before signed backups gets its key on the next setup run.
    rmSync(keyPath);
    assert.equal(configure(root, options).backupKeyCreated, true);
    assert.match(readFileSync(keyPath, 'utf8'), /^[0-9a-f]{64}\n$/);
    assert.deepEqual(readFileSync(envPath), before, 'creating the key leaves compose.env untouched');
    chmodSync(keyPath, 0o644);
    assert.throws(() => configure(root, options), /backup\.key must be an owned regular file with mode 0600/);
    chmodSync(keyPath, 0o600);
    // An empty key file is what an interrupted first creation left behind: it never signed anything and is replaced.
    writeFileSync(keyPath, '', { mode: 0o600 });
    assert.equal(configure(root, options).backupKeyCreated, true, 'an empty key file is replaced');
    assert.match(readFileSync(keyPath, 'utf8'), /^[0-9a-f]{64}\n$/);
    assert.equal(statSync(keyPath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(join(stateDir, 'config')).filter(name => name.startsWith('.backup.key')), [], 'no temporary key file is left');
    // Any other content is not a key and is never overwritten: backups may have been signed with what it should hold.
    writeFileSync(keyPath, 'not a key\n', { mode: 0o600 });
    assert.throws(() => configure(root, options), /backup\.key does not hold a backup key/);
    assert.equal(readFileSync(keyPath, 'utf8'), 'not a key\n');
    writeFileSync(keyPath, keyBefore, { mode: 0o600 });
    assert.equal(configure(root, options).backupKeyCreated, false);
    assert.throws(() => validateOperatorEnv({ ...env, ANON_KEY: env.SERVICE_ROLE_KEY }, stateDir), /Invalid ANON_KEY/);
    assert.throws(() => validateOperatorEnv({ ...env, JWT_SECRET: '0'.repeat(96) }, stateDir), /Invalid ANON_KEY/);
    assert.throws(() => validateOperatorEnv({ ...env, WAREHOUSE_PROJECT_NAME: 'warehouse-other' }, stateDir), /project differs/);
    assert.throws(() => validateOperatorEnv({ ...env, CORS_ALLOWED_ORIGIN: 'https://wrong.example.com' }, stateDir), /browser origins differ/);
    for (const [key, role] of [['ANON_KEY', 'anon'], ['SERVICE_ROLE_KEY', 'service_role']]) {
      const [header, payload, signature] = env[key].split('.');
      assert.equal(signature, createHmac('sha256', env.JWT_SECRET).update(`${header}.${payload}`).digest('base64url'));
      assert.equal(JSON.parse(Buffer.from(payload, 'base64url')).role, role);
    }
    assert.throws(() => configure(root, { ...options, company: 'Different' }), /differs/);
    assert.throws(() => configure(root, { ...options, apiUrl: 'https://other.example.com' }), /differs/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('rerun with a changed provider file replaces only the provider lines atomically', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-config-provider-'));
  const root = join(scratch, 'checkout');
  const stateDir = join(scratch, 'state');
  const providerEnv = join(scratch, 'provider.env');
  const rotatedEnv = join(scratch, 'provider-new.env');
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=first-provider-key\nMSG91_TEMPLATE_ID=flow-id\nMSG91_PE_ID=pe-id\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    const options = { stateDir, apiUrl: 'https://api.example.com', appUrl: 'https://app.example.com', company: 'Acme Stores', providerEnv };
    assert.equal(configure(root, options).created, true);
    const envPath = join(stateDir, 'config/compose.env');
    const original = readFileSync(envPath, 'utf8');
    const originalEnv = readEnv(envPath);

    // Same provider values: no write at all, bytes identical.
    const same = configure(root, options);
    assert.equal(same.created, false);
    assert.equal(same.providerUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), original);

    // Rerun without a provider file never touches the configuration either.
    const silent = configure(root, { stateDir, apiUrl: options.apiUrl, company: options.company });
    assert.equal(silent.providerUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), original);

    // New provider values: only the five provider lines change, mode stays 0600,
    // no staging file is left behind, and signing keys are preserved.
    writeFileSync(rotatedEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=second-provider-key\nMSG91_TEMPLATE_ID=flow-two\nMSG91_PE_ID=pe-two\nMSG91_SENDER_ID=SECOND\n', { mode: 0o600 });
    const updated = configure(root, { ...options, providerEnv: rotatedEnv });
    assert.equal(updated.created, false);
    assert.equal(updated.providerUpdated, true);
    assert.equal(statSync(envPath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(join(stateDir, 'config')).sort(), ['backup.key', 'compose.env']);
    const after = readFileSync(envPath, 'utf8');
    const afterEnv = readEnv(envPath);
    assert.equal(afterEnv.MSG91_AUTH_KEY, 'second-provider-key');
    assert.equal(afterEnv.MSG91_TEMPLATE_ID, 'flow-two');
    assert.equal(afterEnv.MSG91_PE_ID, 'pe-two');
    assert.equal(afterEnv.MSG91_SENDER_ID, 'SECOND');
    assert.equal(afterEnv.SMS_PROVIDER, 'msg91');
    for (const key of ['JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY', 'POSTGRES_PASSWORD', 'SECRET_KEY_BASE', 'WAREHOUSE_PROJECT_NAME', 'SITE_URL']) assert.equal(afterEnv[key], originalEnv[key], key);
    const changedLines = original.split('\n').filter((line, index) => line !== after.split('\n')[index]);
    assert.deepEqual(changedLines.map(line => line.split('=')[0]).sort(), ['MSG91_AUTH_KEY', 'MSG91_PE_ID', 'MSG91_SENDER_ID', 'MSG91_TEMPLATE_ID']);
    assert.equal(after.includes('first-provider-key'), false);
    assert.equal(validateOperatorEnv(afterEnv, stateDir).origin, options.apiUrl);

    // Rerunning with the new file is again byte-stable.
    assert.equal(configure(root, { ...options, providerEnv: rotatedEnv }).providerUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), after);

    // The CLI reports the provider replacement distinctly.
    const cli = spawnSync(process.execPath, [new URL('../scripts/configure.mjs', import.meta.url).pathname, '--state-dir', stateDir, '--provider-env', providerEnv], { encoding: 'utf8', env: { ...process.env, NODE_TEST_CONTEXT: '' } });
    assert.equal(cli.status, 0, cli.stderr);
    assert.match(cli.stdout, /Updated MSG91 provider settings in existing operator state\./);
    assert.equal(readEnv(envPath).MSG91_AUTH_KEY, 'first-provider-key');
    const stable = spawnSync(process.execPath, [new URL('../scripts/configure.mjs', import.meta.url).pathname, '--state-dir', stateDir, '--provider-env', providerEnv], { encoding: 'utf8', env: { ...process.env, NODE_TEST_CONTEXT: '' } });
    assert.match(stable.stdout, /Preserved existing operator state unchanged\./);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('central sign-in settings: off by default, set on a fresh setup or a rerun, and nothing else changes', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-config-central-'));
  const root = join(scratch, 'checkout');
  const providerEnv = join(scratch, 'provider.env');
  const issuer = 'https://login.association.example.test';
  const jwks = 'https://login.association.example.test/.well-known/jwks.json';
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=provider-key\nMSG91_TEMPLATE_ID=flow-id\nMSG91_PE_ID=pe-id\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    const base = { apiUrl: 'https://api.example.com', company: 'Acme Stores', providerEnv };

    // Fresh setup without the options: both lines exist and are empty.
    const stateDir = join(scratch, 'state');
    const envPath = join(stateDir, 'config/compose.env');
    assert.equal(configure(root, { ...base, stateDir }).created, true);
    const original = readFileSync(envPath, 'utf8');
    assert.match(original, /^CENTRAL_ISSUER=$/m);
    assert.match(original, /^CENTRAL_JWKS_URL=$/m);
    assert.match(original, /^CENTRAL_JWKS_FILE=$/m);
    assert.equal(readEnv(envPath).CENTRAL_ISSUER, '');

    // Rerun with both: exactly those two lines change, the file stays private.
    const set = configure(root, { stateDir, centralIssuer: issuer, centralJwksUrl: jwks });
    assert.equal(set.created, false);
    assert.equal(set.centralUpdated, true);
    assert.equal(set.providerUpdated, false);
    const after = readFileSync(envPath, 'utf8');
    const changed = original.split('\n').filter((line, index) => line !== after.split('\n')[index]);
    assert.deepEqual(changed, ['CENTRAL_ISSUER=', 'CENTRAL_JWKS_URL=']);
    assert.equal(original.split('\n').length, after.split('\n').length);
    assert.equal(readEnv(envPath).CENTRAL_ISSUER, issuer);
    assert.equal(readEnv(envPath).CENTRAL_JWKS_URL, jwks);
    assert.equal(statSync(envPath).mode & 0o777, 0o600);
    assert.deepEqual(readdirSync(join(stateDir, 'config')).sort(), ['backup.key', 'compose.env']);
    assert.equal(validateOperatorEnv(readEnv(envPath), stateDir).origin, base.apiUrl);

    // The same values again, or no central option at all: byte-stable.
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksUrl: jwks }).centralUpdated, false);
    assert.equal(configure(root, { stateDir }).centralUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), after);

    // Replacing, then off: back to the original bytes.
    assert.equal(configure(root, { stateDir, centralIssuer: `${issuer}/v2`, centralJwksUrl: `${jwks}?v=2` }).centralUpdated, true);
    assert.equal(readEnv(envPath).CENTRAL_ISSUER, `${issuer}/v2`);
    assert.equal(readEnv(envPath).CENTRAL_JWKS_URL, `${jwks}?v=2`);
    assert.equal(configure(root, { stateDir, centralIssuer: 'off' }).centralUpdated, true);
    assert.equal(readFileSync(envPath, 'utf8'), original);
    assert.equal(configure(root, { stateDir, centralIssuer: 'off' }).centralUpdated, false);

    // Both or neither, https only, and nothing compose.env could not hold on one line.
    const refused = [
      [{ centralIssuer: issuer }, /exactly one of --central-jwks-url and --central-jwks-file/], [{ centralJwksUrl: jwks }, /exactly one of --central-jwks-url and --central-jwks-file/],
      [{ centralIssuer: 'off', centralJwksUrl: jwks }, /leave out --central-jwks-url/],
      [{ centralIssuer: issuer, centralJwksUrl: jwks, centralJwksFile: '/nonexistent/keys.json' }, /exactly one of/],
      [{ centralIssuer: issuer, centralJwksUrl: '' }, /exactly one of/],
      [{ centralIssuer: '', centralJwksUrl: jwks }, /exactly one of --central-jwks-url and --central-jwks-file/],
      [{ centralIssuer: 'http://login.association.example.test', centralJwksUrl: jwks }, /https:\/\/ address/],
      [{ centralIssuer: issuer, centralJwksUrl: 'http://login.association.example.test/jwks.json' }, /https:\/\/ address/],
      [{ centralIssuer: 'login.association.example.test', centralJwksUrl: jwks }, /https:\/\/ address/],
      [{ centralIssuer: 'HTTPS://login.association.example.test', centralJwksUrl: jwks }, /https:\/\/ address/],
      [{ centralIssuer: 'https://user:secret@login.association.example.test', centralJwksUrl: jwks }, /without credentials/],
      [{ centralIssuer: `${issuer}?tenant=1`, centralJwksUrl: jwks }, /must not carry a query/],
      [{ centralIssuer: issuer, centralJwksUrl: `${jwks}#keys` }, /without credentials, fragment/],
      [{ centralIssuer: `${issuer}/a b`, centralJwksUrl: jwks }, /spaces/],
      [{ centralIssuer: `${issuer}/$HOME`, centralJwksUrl: jwks }, /\$ or #/],
      [{ centralIssuer: issuer, centralJwksUrl: `${jwks}\nJWT_SECRET=replaced` }, /spaces/],
      [{ centralIssuer: issuer, centralJwksUrl: `${jwks}'` }, /quotes/],
      [{ centralIssuer: issuer, centralJwksUrl: `${jwks}\\` }, /backslash/],
      [{ centralIssuer: `${issuer}/${'a'.repeat(260)}`, centralJwksUrl: jwks }, /https:\/\/ address/],
    ];
    for (const [options, message] of refused) {
      assert.throws(() => configure(root, { stateDir, ...options }), message, JSON.stringify(options));
      assert.throws(() => configure(root, { ...base, stateDir: join(scratch, 'never'), ...options }), message, `fresh ${JSON.stringify(options)}`);
    }
    assert.equal(readFileSync(envPath, 'utf8'), original, 'a refused value changes nothing');
    assert.equal(statSync(join(scratch, 'never'), { throwIfNoEntry: false }), undefined, 'a refused value creates no state');

    // A rerun still refuses to change the identity next to a central option.
    assert.throws(() => configure(root, { stateDir, company: 'Different', centralIssuer: issuer, centralJwksUrl: jwks }), /differs/);
    assert.equal(readFileSync(envPath, 'utf8'), original);

    // A state written before the two lines existed: they are appended; "off" leaves such a state alone.
    const older = original.replace(/^CENTRAL_(?:ISSUER|JWKS_URL|JWKS_FILE)=\n/gm, '');
    assert.doesNotMatch(older, /^CENTRAL_/m);
    writeFileSync(envPath, older, { mode: 0o600 });
    assert.equal(configure(root, { stateDir, centralIssuer: 'off' }).centralUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), older);
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksUrl: jwks }).centralUpdated, true);
    assert.equal(readFileSync(envPath, 'utf8'), `${older}CENTRAL_ISSUER=${issuer}\nCENTRAL_JWKS_URL=${jwks}\nCENTRAL_JWKS_FILE=\n`);
    assert.equal(configure(root, { stateDir, centralIssuer: 'off' }).centralUpdated, true);
    assert.equal(readFileSync(envPath, 'utf8'), `${older}CENTRAL_ISSUER=\nCENTRAL_JWKS_URL=\nCENTRAL_JWKS_FILE=\n`);

    // Fresh setup with the options, and with "off".
    const withCentral = join(scratch, 'state-central');
    assert.equal(configure(root, { ...base, stateDir: withCentral, centralIssuer: issuer, centralJwksUrl: jwks }).created, true);
    assert.equal(readEnv(join(withCentral, 'config/compose.env')).CENTRAL_ISSUER, issuer);
    assert.equal(readEnv(join(withCentral, 'config/compose.env')).CENTRAL_JWKS_URL, jwks);
    const withOff = join(scratch, 'state-off');
    assert.equal(configure(root, { ...base, stateDir: withOff, centralIssuer: 'off' }).created, true);
    assert.equal(readEnv(join(withOff, 'config/compose.env')).CENTRAL_ISSUER, '');

    // The command line: both options are accepted and the change is reported.
    assert.deepEqual(parseConfigureArgs(['--state-dir', stateDir, '--central-issuer', issuer, '--central-jwks-url', jwks]),
      { stateDir, centralIssuer: issuer, centralJwksUrl: jwks });
    const script = new URL('../scripts/configure.mjs', import.meta.url).pathname;
    const run = args => spawnSync(process.execPath, [script, '--state-dir', withOff, ...args], { encoding: 'utf8', env: { ...process.env, NODE_TEST_CONTEXT: '' } });
    const cli = run(['--central-issuer', issuer, '--central-jwks-url', jwks]);
    assert.equal(cli.status, 0, cli.stderr);
    assert.match(cli.stdout, /Updated central sign-in settings in existing operator state\./);
    assert.match(run(['--central-issuer', issuer, '--central-jwks-url', jwks]).stdout, /Preserved existing operator state unchanged\./);
    const bad = run(['--central-issuer', issuer]);
    assert.equal(bad.status, 1);
    assert.match(bad.stderr, /Configure: Central sign-in needs --central-issuer with exactly one of/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('central sign-in keys from a file: validated, copied into the state, replaced on a rerun, removed when off', async () => {
  const { exportJWK, generateKeyPair } = await import('jose');
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-config-central-file-'));
  const root = join(scratch, 'checkout');
  const providerEnv = join(scratch, 'provider.env');
  const issuer = 'https://login.association.example.test';
  const jwks = 'https://login.association.example.test/.well-known/jwks.json';
  const publicJwk = async kid => ({ ...(await exportJWK((await generateKeyPair('ES256', { extractable: true })).publicKey)), kid, alg: 'ES256', use: 'sig' });
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=provider-key\nMSG91_TEMPLATE_ID=flow-id\nMSG91_PE_ID=pe-id\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    const base = { apiUrl: 'https://api.example.com', company: 'Acme Stores', providerEnv };
    const first = join(scratch, 'keys-first.json');
    const second = join(scratch, 'keys-second.json');
    writeFileSync(first, JSON.stringify({ keys: [await publicJwk('key-1')] }) + '\n');
    writeFileSync(second, JSON.stringify({ keys: [await publicJwk('key-1'), await publicJwk('key-2')] }, null, 2));

    // Rerun on a state without central sign-in.
    const stateDir = join(scratch, 'state');
    const envPath = join(stateDir, 'config/compose.env');
    const copy = join(stateDir, 'public/central-jwks.json');
    configure(root, { ...base, stateDir });
    const original = readFileSync(envPath, 'utf8');
    const set = configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: first });
    assert.equal(set.centralUpdated, true);
    assert.deepEqual(readFileSync(copy), readFileSync(first), 'the copy holds the file byte for byte');
    assert.equal(statSync(copy).mode & 0o777, 0o644);
    const env = readEnv(envPath);
    assert.deepEqual([env.CENTRAL_ISSUER, env.CENTRAL_JWKS_URL, env.CENTRAL_JWKS_FILE], [issuer, '', 'central-jwks.json']);
    assert.deepEqual(readdirSync(join(stateDir, 'public')).sort(), ['central-jwks.json', 'instance.json'], 'no temporary file is left');
    assert.equal(validateOperatorEnv(env, stateDir).origin, base.apiUrl);
    const withFile = readFileSync(envPath, 'utf8');
    assert.deepEqual(original.split('\n').filter((line, index) => line !== withFile.split('\n')[index]), ['CENTRAL_ISSUER=', 'CENTRAL_JWKS_FILE=']);

    // The same file again changes nothing; without a central option the copy stays.
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: first }).centralUpdated, false);
    assert.equal(configure(root, { stateDir }).centralUpdated, false);
    assert.deepEqual(readFileSync(copy), readFileSync(first));

    // The association rotated: a rerun with the new file replaces the copy and leaves compose.env alone.
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: second }).centralUpdated, true);
    assert.deepEqual(readFileSync(copy), readFileSync(second));
    assert.equal(readFileSync(envPath, 'utf8'), withFile);
    // A copy whose mode was loosened or tightened is put right.
    chmodSync(copy, 0o600);
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: second }).centralUpdated, true);
    assert.equal(statSync(copy).mode & 0o777, 0o644);

    // Files that are refused: nothing is copied and nothing changes.
    const privateJwk = { ...(await exportJWK((await generateKeyPair('ES256', { extractable: true })).privateKey)), kid: 'leaked' };
    const duplicate = await publicJwk('same');
    const { publicKey: rsa } = await generateKeyPair('RS256', { extractable: true });
    const bad = {
      'private.json': [JSON.stringify({ keys: [await publicJwk('ok'), privateJwk] }), /private key material/],
      'not-json.json': ['<html>', /not a JSON key set/],
      'no-keys.json': [JSON.stringify({ jwks: [] }), /not usable: key set malformed/],
      'rsa-only.json': [JSON.stringify({ keys: [{ ...(await exportJWK(rsa)), kid: 'rsa' }] }), /not usable: key set holds no P-256 signature key/],
      'no-kid.json': [JSON.stringify({ keys: [{ ...(await publicJwk('x')), kid: undefined }] }), /holds no P-256 signature key/],
      'duplicate.json': [JSON.stringify({ keys: [duplicate, { ...(await publicJwk('other')), kid: 'same' }] }), /names a key id twice/],
      'big.json': [JSON.stringify({ keys: [await publicJwk('ok')], padding: 'x'.repeat(64 * 1024) }), /larger than 64 KB/],
    };
    for (const [name, [text, message]] of Object.entries(bad)) {
      const path = join(scratch, name);
      writeFileSync(path, text);
      assert.throws(() => configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: path }), message, name);
      assert.throws(() => configure(root, { ...base, stateDir: join(scratch, 'never'), centralIssuer: issuer, centralJwksFile: path }), message, `fresh ${name}`);
    }
    assert.throws(() => configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: 'keys-first.json' }), /absolute path/);
    assert.throws(() => configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: join(scratch, 'missing.json') }), /readable regular file/);
    assert.throws(() => configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: scratch }), /readable regular file/);
    assert.throws(() => configure(root, { stateDir, centralJwksFile: first }), /exactly one of/);
    assert.throws(() => configure(root, { stateDir, centralIssuer: 'off', centralJwksFile: first }), /leave out/);
    assert.deepEqual(readFileSync(copy), readFileSync(second));
    assert.equal(readFileSync(envPath, 'utf8'), withFile);
    assert.equal(statSync(join(scratch, 'never'), { throwIfNoEntry: false }), undefined);

    // Changing to an address removes the copy; changing back puts it there again; off removes all three.
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksUrl: jwks }).centralUpdated, true);
    assert.equal(statSync(copy, { throwIfNoEntry: false }), undefined);
    assert.deepEqual([readEnv(envPath).CENTRAL_JWKS_URL, readEnv(envPath).CENTRAL_JWKS_FILE], [jwks, '']);
    configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: first });
    assert.deepEqual([readEnv(envPath).CENTRAL_JWKS_URL, readEnv(envPath).CENTRAL_JWKS_FILE], ['', 'central-jwks.json']);
    assert.equal(configure(root, { stateDir, centralIssuer: 'off' }).centralUpdated, true);
    assert.equal(statSync(copy, { throwIfNoEntry: false }), undefined);
    assert.equal(readFileSync(envPath, 'utf8'), original);

    // A key file lost with the host (backups hold compose.env, not this file): the rerun puts it back.
    configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: first });
    rmSync(copy);
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksFile: first }).centralUpdated, true);
    assert.deepEqual(readFileSync(copy), readFileSync(first));

    // Fresh setup with a key file, and the command line.
    const fresh = join(scratch, 'state-fresh');
    assert.equal(configure(root, { ...base, stateDir: fresh, centralIssuer: issuer, centralJwksFile: first }).created, true);
    assert.deepEqual(readFileSync(join(fresh, 'public/central-jwks.json')), readFileSync(first));
    assert.equal(statSync(join(fresh, 'public/central-jwks.json')).mode & 0o777, 0o644);
    assert.equal(readEnv(join(fresh, 'config/compose.env')).CENTRAL_JWKS_FILE, 'central-jwks.json');
    assert.deepEqual(parseConfigureArgs(['--state-dir', fresh, '--central-issuer', issuer, '--central-jwks-file', second]),
      { stateDir: fresh, centralIssuer: issuer, centralJwksFile: second });
    const cli = spawnSync(process.execPath, [new URL('../scripts/configure.mjs', import.meta.url).pathname, '--state-dir', fresh,
      '--central-issuer', issuer, '--central-jwks-file', second], { encoding: 'utf8', env: { ...process.env, NODE_TEST_CONTEXT: '' } });
    assert.equal(cli.status, 0, cli.stderr);
    assert.match(cli.stdout, /Updated central sign-in settings in existing operator state\./);
    assert.deepEqual(readFileSync(join(fresh, 'public/central-jwks.json')), readFileSync(second));
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('setup and the edge function apply the same key set rules', () => {
  // scripts/ must run without functions/ (tests/cli-symlink.test.mjs) and the functions container
  // mounts functions/ only, so the rules are one text kept in both places.
  assert.equal(readFileSync(new URL('../scripts/central-key-set.mjs', import.meta.url), 'utf8'),
    readFileSync(new URL('../functions/central-exchange/key-set.mjs', import.meta.url), 'utf8'));
});

test('setup.sh passes the central options on and applies the issuer to the database after the auth settings', () => {
  const setup = readFileSync(new URL('../setup.sh', import.meta.url), 'utf8');
  assert.match(setup, /--admin-name\|--central-issuer\|--central-jwks-url\|--central-jwks-file\)/);
  const auth = setup.indexOf('scripts/configure-auth.sql');
  const central = setup.indexOf('scripts/configure-central.sql');
  assert.ok(auth > 0 && central > auth && central < setup.indexOf('scripts/configure-sms.sql'));
  const sql = readFileSync(new URL('../scripts/configure-central.sql', import.meta.url), 'utf8');
  // The issuer is read from the state's compose.env (never sourced) and handed to psql as a quoted variable;
  // the database container has no environment entry for it, so an upgrade does not recreate it.
  assert.match(setup, /CENTRAL_ISSUER_VALUE="\$\(sed -n 's\/\^CENTRAL_ISSUER=\/\/p' "\$STATE\/config\/compose\.env" \| head -n 1\)"/);
  assert.match(setup, /-v central_issuer="\$CENTRAL_ISSUER_VALUE" < "\$ROOT\/scripts\/configure-central\.sql"/);
  assert.doesNotMatch(setup, /(?:^|\s)(?:source|\.)\s+"?\$STATE/m);
  assert.doesNotMatch(sql, /\\getenv/);
  assert.match(sql, /VALUES \('central_issuer',:'central_issuer'\)/);
  assert.doesNotMatch(sql, /CENTRAL_JWKS/, 'the database holds the issuer only');
  const compose = readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8');
  assert.doesNotMatch(compose.slice(compose.indexOf('\n  db:\n')), /CENTRAL_/, 'the db service has no central setting');
});

test('fresh setup rejects checkout state and unprotected provider credentials', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-config-reject-'));
  const root = join(scratch, 'checkout');
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    const providerEnv = join(scratch, 'provider.env');
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=key\nMSG91_TEMPLATE_ID=id\nMSG91_PE_ID=pe\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o644 });
    // Creation modes are masked by the operator's umask; explicitly create the
    // insecure fixture so this rejection check also runs under umask 077.
    chmodSync(providerEnv, 0o644);
    const options = { stateDir: join(scratch, 'state'), apiUrl: 'https://api.example.com', appUrl: 'https://app.example.com', company: 'Acme', providerEnv };
    assert.throws(() => configure(root, { ...options, stateDir: join(root, 'state') }), /outside the checkout/);
    assert.throws(() => configure(root, options), /mode 0600/);
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY="quoted"\nMSG91_TEMPLATE_ID=id\nMSG91_PE_ID=pe\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    chmodSync(providerEnv, 0o600);
    assert.throws(() => configure(root, options), /without quotes/);
    const alias = join(scratch, 'alias');
    symlinkSync(scratch, alias, 'dir');
    assert.throws(() => configure(root, { ...options, stateDir: join(alias, 'state') }), /symlink/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('compose strips inherited values before loading private config', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-compose-env-'));
  const root = new URL('..', import.meta.url).pathname;
  const stateDir = join(scratch, 'state');
  const providerEnv = join(scratch, 'provider.env');
  const bin = join(scratch, 'bin');
  try {
    mkdirSync(bin);
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=key\nMSG91_TEMPLATE_ID=id\nMSG91_PE_ID=pe\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    configure(root, { stateDir, apiUrl: 'https://api.example.com', company: 'Acme', providerEnv });
    writeFileSync(join(bin, 'docker'), '#!/bin/sh\nif [ "$1" = ps ]; then exit 0; fi\nprintf "%s\\n" "${POSTGRES_PASSWORD-unset}"\n', { mode: 0o700 });
    const result = spawnSync('bash', [join(root, 'scripts/compose.sh'), 'config', '--quiet'], {
      encoding: 'utf8', env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: stateDir, POSTGRES_PASSWORD: 'ambient-secret' },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'unset');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('interruption while staging leaves state unpublished and rerun succeeds', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-config-interrupt-'));
  const root = join(scratch, 'checkout');
  const stateDir = join(scratch, 'state');
  const providerEnv = join(scratch, 'provider.env');
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=key\nMSG91_TEMPLATE_ID=id\nMSG91_PE_ID=pe\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    const options = { stateDir, apiUrl: 'https://api.example.com', appUrl: 'https://app.example.com', company: 'Acme', providerEnv };
    assert.throws(() => configure(root, { ...options, faultAfterManifest: true }), /Injected failure/);
    assert.equal(statSync(stateDir, { throwIfNoEntry: false }), undefined);
    assert.equal(configure(root, options).created, true);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('set-capability flips one manifest flag in place, keeps every other byte and the mode, and refuses bad input', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-capability-'));
  const root = join(scratch, 'checkout');
  const stateDir = join(scratch, 'state');
  const providerEnv = join(scratch, 'provider.env');
  const script = new URL('../scripts/set-capability.mjs', import.meta.url).pathname;
  const run = (args, state = stateDir) => spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: state } });
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=key\nMSG91_TEMPLATE_ID=id\nMSG91_PE_ID=pe\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
    configure(root, { stateDir, apiUrl: 'https://api.example.com', company: 'Acme Stores', providerEnv });
    const manifestPath = join(stateDir, 'public/instance.json');
    const envPath = join(stateDir, 'config/compose.env');
    const original = readFileSync(manifestPath, 'utf8');
    const env = readFileSync(envPath);
    const mode = statSync(manifestPath).mode & 0o777;
    assert.match(original, /"sensors": false/);

    const on = run(['sensors', 'on']);
    assert.equal(on.status, 0, on.stderr);
    assert.match(on.stdout, /Set capabilities\.sensors on/);
    assert.match(on.stdout, /restore-host/);
    assert.match(on.stdout, /npm run db:backup/);
    assert.match(on.stdout, /compose\.sh restart functions/);
    const flipped = readFileSync(manifestPath, 'utf8');
    // The same file with the one word changed: every other byte, the order and the indentation stay.
    assert.equal(flipped, original.replace('"sensors": false', '"sensors": true'));
    assert.deepEqual(JSON.parse(flipped).capabilities, { sensors: true, printing: false });
    assert.equal(statSync(manifestPath).mode & 0o777, mode, 'the mode is kept');
    assert.deepEqual(readFileSync(envPath), env, 'compose.env is not touched');
    assert.deepEqual(readdirSync(join(stateDir, 'public')), ['instance.json'], 'no staging file is left');

    const again = run(['sensors', 'on']);
    assert.equal(again.status, 0, again.stderr);
    assert.match(again.stdout, /already on/);
    assert.doesNotMatch(again.stdout, /db:backup/);
    assert.equal(readFileSync(manifestPath, 'utf8'), flipped);

    const off = run(['sensors', 'off']);
    assert.equal(off.status, 0, off.stderr);
    assert.equal(readFileSync(manifestPath, 'utf8'), original, 'off restores the original bytes');
    const printing = run(['printing', 'on']);
    assert.equal(printing.status, 0, printing.stderr);
    assert.match(printing.stdout, /503/);
    assert.equal(readFileSync(manifestPath, 'utf8'), original.replace('"printing": false', '"printing": true'));
    assert.equal(run(['printing', 'off']).status, 0);

    for (const args of [['alarms', 'on'], ['sensors', 'yes'], ['sensors', 'true'], ['Sensors', 'on'], ['sensors'], ['sensors', 'on', 'extra'], []]) {
      const refused = run(args);
      assert.equal(refused.status, 1, `${args.join(' ')} was accepted`);
      assert.match(refused.stderr, /Usage: /);
    }
    assert.match(run(['sensors', 'on'], '').stderr, /WAREHOUSE_STATE_DIR/);
    assert.match(run(['sensors', 'on'], 'relative/state').stderr, /WAREHOUSE_STATE_DIR/);
    assert.match(run(['sensors', 'on'], join(scratch, 'missing')).stderr, /operator state must be a directory/);
    // A manifest without the flag, or with a non-boolean flag, is left alone.
    writeFileSync(manifestPath, original.replace('"sensors": false', '"sensors": "no"'));
    assert.match(run(['sensors', 'on']).stderr, /no boolean capabilities\.sensors/);
    writeFileSync(manifestPath, original.replace('"sensors": false,\n', ''));
    assert.match(run(['sensors', 'on']).stderr, /no boolean capabilities\.sensors/);
    writeFileSync(manifestPath, '{ not json');
    assert.match(run(['sensors', 'on']).stderr, /not valid JSON/);
    assert.equal(readFileSync(manifestPath, 'utf8'), '{ not json');
    writeFileSync(manifestPath, original);
    chmodSync(stateDir, 0o755);
    assert.match(run(['sensors', 'on']).stderr, /mode 0700/);
    chmodSync(stateDir, 0o700);
    assert.equal(readFileSync(manifestPath, 'utf8'), original, 'nothing was changed by a refusal');
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});
