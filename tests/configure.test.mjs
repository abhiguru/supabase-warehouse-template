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
      [{ centralIssuer: issuer }, /needs both/], [{ centralJwksUrl: jwks }, /needs both/],
      [{ centralIssuer: 'off', centralJwksUrl: jwks }, /leave out --central-jwks-url/],
      [{ centralIssuer: '', centralJwksUrl: jwks }, /needs both/],
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
    const older = original.replace(/^CENTRAL_(?:ISSUER|JWKS_URL)=\n/gm, '');
    assert.doesNotMatch(older, /CENTRAL_ISSUER=|CENTRAL_JWKS_URL=/);
    writeFileSync(envPath, older, { mode: 0o600 });
    assert.equal(configure(root, { stateDir, centralIssuer: 'off' }).centralUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), older);
    assert.equal(configure(root, { stateDir, centralIssuer: issuer, centralJwksUrl: jwks }).centralUpdated, true);
    assert.equal(readFileSync(envPath, 'utf8'), `${older}CENTRAL_ISSUER=${issuer}\nCENTRAL_JWKS_URL=${jwks}\n`);
    assert.equal(configure(root, { stateDir, centralIssuer: 'off' }).centralUpdated, true);
    assert.equal(readFileSync(envPath, 'utf8'), `${older}CENTRAL_ISSUER=\nCENTRAL_JWKS_URL=\n`);

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
    assert.match(bad.stderr, /Configure: Central sign-in needs both/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('setup.sh passes the central options on and applies the issuer to the database after the auth settings', () => {
  const setup = readFileSync(new URL('../setup.sh', import.meta.url), 'utf8');
  assert.match(setup, /--admin-name\|--central-issuer\|--central-jwks-url\)/);
  const auth = setup.indexOf('scripts/configure-auth.sql');
  const central = setup.indexOf('scripts/configure-central.sql');
  assert.ok(auth > 0 && central > auth && central < setup.indexOf('scripts/configure-sms.sql'));
  const sql = readFileSync(new URL('../scripts/configure-central.sql', import.meta.url), 'utf8');
  assert.match(sql, /\\getenv central_issuer CENTRAL_ISSUER/);
  assert.doesNotMatch(sql, /CENTRAL_JWKS_URL/, 'the database holds the issuer only');
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
