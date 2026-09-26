import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, statSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHmac } from 'node:crypto';
import { configure } from '../scripts/configure.mjs';
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
    for (const [key, role] of [['ANON_KEY', 'anon'], ['SERVICE_ROLE_KEY', 'service_role']]) {
      const [header, payload, signature] = env[key].split('.');
      assert.equal(signature, createHmac('sha256', env.JWT_SECRET).update(`${header}.${payload}`).digest('base64url'));
      assert.equal(JSON.parse(Buffer.from(payload, 'base64url')).role, role);
    }
    assert.throws(() => configure(root, { ...options, company: 'Different' }), /differs/);
    assert.throws(() => configure(root, { ...options, apiUrl: 'https://other.example.com' }), /differs/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('fresh setup rejects checkout state and unprotected provider credentials', () => {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-config-reject-'));
  const root = join(scratch, 'checkout');
  try {
    mkdirSync(root);
    copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
    const providerEnv = join(scratch, 'provider.env');
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=key\nMSG91_TEMPLATE_ID=id\nMSG91_PE_ID=pe\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o644 });
    const options = { stateDir: join(scratch, 'state'), apiUrl: 'https://api.example.com', appUrl: 'https://app.example.com', company: 'Acme', providerEnv };
    assert.throws(() => configure(root, { ...options, stateDir: join(root, 'state') }), /outside the checkout/);
    assert.throws(() => configure(root, options), /mode 0600/);
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
