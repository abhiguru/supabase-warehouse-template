import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';
import { validateOperatorEnv } from '../scripts/doctor.mjs';
import { readEnv } from '../scripts/doctor-common.mjs';
import { isFixtureAddress, isProviderPlaceholder } from '../scripts/provider-placeholder.mjs';
import { deliverOtp } from '../functions/operator-otp/provider.ts';

// X-7 (incident TW-ENV-008): the edge function, the installer and the doctor decide "this is not a
// provider value" with one rule. Nothing here can reach a provider; sends are injected.
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('setup and the edge function apply the same placeholder rule', () => {
  // scripts/ runs without functions/ and the functions container mounts functions/ only
  // (as for the key set rules), so the rule is one text kept in both places.
  assert.equal(read('scripts/provider-placeholder.mjs'), read('functions/operator-otp/provider-placeholder.mjs'));
  assert.match(read('functions/operator-otp/provider.ts'), /from '\.\/provider-placeholder\.mjs'/);
  for (const file of ['scripts/doctor.mjs', 'scripts/configure.mjs']) {
    assert.match(read(file), /from '\.\/provider-placeholder\.mjs'/, file);
    assert.doesNotMatch(read(file), /your-\|changeme/, `${file} keeps its own copy of the rule`);
  }
  assert.doesNotMatch(read('functions/operator-otp/provider.ts'), /startsWith\('your-'\)/);
});

test('empty values, template text and the fixture sentinel are placeholders; a real-looking value is not', () => {
  for (const value of [undefined, null, '', '   ', 42, 'your-msg91-auth-key', 'YOUR-KEY', 'changeme', 'CHANGEME-x', 'fake_key', 'isolated-no-delivery-key', 'Isolated-x']) {
    assert.equal(isProviderPlaceholder(value), true, JSON.stringify(value));
  }
  for (const value of ['694a8ea0cd30ae1f432f445a', 'a1b2c3d4e5', 'real-provider-key', 'my-isolated-key', 'yours-truly']) {
    assert.equal(isProviderPlaceholder(value), false, value);
  }
  // Allowing the sentinel lets only the sentinel through.
  const allow = { allowFixtureSentinel: true };
  assert.equal(isProviderPlaceholder('isolated-no-delivery-key', allow), false);
  assert.equal(isProviderPlaceholder('  isolated-x', allow), false);
  for (const value of [undefined, '', '  ', 'your-key', 'changeme', 'fake_key']) assert.equal(isProviderPlaceholder(value, allow), true, JSON.stringify(value));
  // Only a reserved .test address is a fixture address.
  for (const address of ['https://backend-core.example.test', 'https://x.test', 'https://TEST', 'https://a.b.example.TEST/']) assert.equal(isFixtureAddress(address), true, address);
  for (const address of ['https://api.example.com', 'https://attest', 'https://test.example.com', 'https://mytest', 'not a url', undefined, '']) assert.equal(isFixtureAddress(address), false, String(address));
});

test('the edge function refuses everything the rule calls a placeholder, with no request', async () => {
  let sent = false;
  const send = async () => { sent = true; return Response.json({ type: 'success', message: 'x' }); };
  for (const value of ['', 'your-key', 'changeme', 'fake_key', 'isolated-no-delivery-key']) {
    await assert.rejects(deliverOtp('919888888801', '123456', value, '694a8ea0cd30ae1f432f445a', send), { code: 'provider_configuration' }, value);
  }
  assert.equal(sent, false);
});

function install(apiUrl, authKey) {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-placeholder-test-'));
  const root = join(scratch, 'checkout');
  const stateDir = join(scratch, 'state');
  const providerEnv = join(scratch, 'provider.env');
  mkdirSync(root);
  copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
  writeFileSync(providerEnv, `SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=${authKey}\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=0000000000000000001\nMSG91_SENDER_ID=CITEST\n`, { mode: 0o600 });
  return { scratch, root, stateDir, providerEnv, options: { stateDir, apiUrl, company: 'Fictional Placeholder Warehouse', providerEnv } };
}

test('the installer and the doctor accept the fixture sentinel only for a .test address', () => {
  // CI and the fixtures install with isolated-no-delivery-key on *.example.test.
  const fixture = install('https://backend-core.example.test', 'isolated-no-delivery-key');
  try {
    assert.equal(configure(fixture.root, fixture.options).created, true);
    const env = readEnv(join(fixture.stateDir, 'config/compose.env'));
    assert.equal(validateOperatorEnv(env, fixture.stateDir).origin, 'https://backend-core.example.test');
    // A rerun with the sentinel on the same fixture state still works.
    assert.equal(configure(fixture.root, fixture.options).created, false);
    // Template text never passes, on any address.
    assert.throws(() => validateOperatorEnv({ ...env, MSG91_AUTH_KEY: 'your-msg91-auth-key' }, fixture.stateDir), /Missing production MSG91 setting: MSG91_AUTH_KEY/);
    assert.throws(() => validateOperatorEnv({ ...env, MSG91_TEMPLATE_ID: '' }, fixture.stateDir), /Missing production MSG91 setting: MSG91_TEMPLATE_ID/);
  } finally { rmSync(fixture.scratch, { recursive: true, force: true }); }

  // A real address refuses the sentinel at install time ...
  const real = install('https://api.example.com', 'isolated-no-delivery-key');
  try {
    assert.throws(() => configure(real.root, real.options), /Missing production provider setting: MSG91_AUTH_KEY\./);
    assert.throws(() => configure(real.root, { ...real.options, providerEnv: undefined }), /Fresh setup requires/);
  } finally { rmSync(real.scratch, { recursive: true, force: true }); }

  // ... and the doctor refuses a state that already carries it (a fixture value pasted into a live install).
  const live = install('https://api.example.com', 'real-provider-key');
  try {
    configure(live.root, live.options);
    const env = readEnv(join(live.stateDir, 'config/compose.env'));
    assert.equal(validateOperatorEnv(env, live.stateDir).origin, 'https://api.example.com');
    assert.throws(() => validateOperatorEnv({ ...env, MSG91_AUTH_KEY: 'isolated-no-delivery-key' }, live.stateDir), /Missing production MSG91 setting: MSG91_AUTH_KEY/);
    assert.throws(() => validateOperatorEnv({ ...env, MSG91_AUTH_KEY: '  ' }, live.stateDir), /Missing production MSG91 setting: MSG91_AUTH_KEY/);
    // A rerun that replaces the key by the sentinel is refused too, and changes nothing.
    const sentinel = join(live.scratch, 'sentinel.env');
    writeFileSync(sentinel, readFileSync(live.providerEnv, 'utf8').replace('real-provider-key', 'isolated-no-delivery-key'), { mode: 0o600 });
    const before = readFileSync(join(live.stateDir, 'config/compose.env'));
    assert.throws(() => configure(live.root, { ...live.options, providerEnv: sentinel }), /Missing production provider setting: MSG91_AUTH_KEY\./);
    assert.deepEqual(readFileSync(join(live.stateDir, 'config/compose.env')), before);
  } finally { rmSync(live.scratch, { recursive: true, force: true }); }
});
