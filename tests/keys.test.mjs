import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { generateSigningKeys, replaceEnvLines, signRoleKey, SIGNING_KEY_NAMES } from '../scripts/keys.mjs';

const decode = token => {
  const [header, payload, signature] = token.split('.');
  return { header: JSON.parse(Buffer.from(header, 'base64url')), payload: JSON.parse(Buffer.from(payload, 'base64url')), signature, body: `${header}.${payload}` };
};

test('signRoleKey produces HS256 Supabase role keys with a ten-year expiry', () => {
  const secret = 'ab'.repeat(48);
  const now = Date.UTC(2026, 9, 8, 12, 0, 0);
  const token = signRoleKey(secret, 'anon', now);
  const { header, payload, signature, body } = decode(token);
  assert.deepEqual(header, { alg: 'HS256', typ: 'JWT' });
  assert.equal(payload.iss, 'supabase');
  assert.equal(payload.role, 'anon');
  assert.equal(payload.exp, Math.floor(now / 1000) + 10 * 365 * 86400);
  assert.equal(signature, createHmac('sha256', secret).update(body).digest('base64url'));
  assert.equal(decode(signRoleKey(secret, 'service_role', now)).payload.role, 'service_role');
  assert.throws(() => signRoleKey('short', 'anon'), /96 hexadecimal/);
  assert.throws(() => signRoleKey(secret, 'authenticated'), /Unsupported API key role/);
});

test('generateSigningKeys yields a fresh 96-hex secret and keys that verify against it', () => {
  const first = generateSigningKeys();
  const second = generateSigningKeys();
  assert.deepEqual(Object.keys(first), SIGNING_KEY_NAMES);
  assert.match(first.JWT_SECRET, /^[0-9a-f]{96}$/);
  assert.notEqual(first.JWT_SECRET, second.JWT_SECRET);
  assert.notEqual(first.ANON_KEY, second.ANON_KEY);
  for (const [key, role] of [['ANON_KEY', 'anon'], ['SERVICE_ROLE_KEY', 'service_role']]) {
    const { payload, signature, body } = decode(first[key]);
    assert.equal(payload.role, role);
    assert.equal(signature, createHmac('sha256', first.JWT_SECRET).update(body).digest('base64url'));
  }
});

test('replaceEnvLines rewrites whole matching lines and nothing else', () => {
  const text = '# header\nJWT_SECRET=old # comment\nGOTRUE_JWT_SECRET=keep\nANON_KEY=old-anon\n\nSITE_URL=https://app.example.com\nSERVICE_ROLE_KEY=old-service\n';
  const updated = replaceEnvLines(text, { JWT_SECRET: 'new', SERVICE_ROLE_KEY: 'new-service' });
  assert.equal(updated, '# header\nJWT_SECRET=new\nGOTRUE_JWT_SECRET=keep\nANON_KEY=old-anon\n\nSITE_URL=https://app.example.com\nSERVICE_ROLE_KEY=new-service\n');
  assert.equal(replaceEnvLines(text, {}), text);
  assert.equal(replaceEnvLines(text, { ANON_KEY: 'old-anon' }), text.replace('ANON_KEY=old-anon', 'ANON_KEY=old-anon'));
  assert.throws(() => replaceEnvLines(text, { MISSING: 'x' }), /Missing template variable: MISSING/);
  assert.throws(() => replaceEnvLines(text, { JWT_SECRET: 'a\nb' }), /Unsupported character in JWT_SECRET/);
  assert.throws(() => replaceEnvLines(text, { JWT_SECRET: 'has#hash' }), /Unsupported character/);
  assert.throws(() => replaceEnvLines(text, { JWT_SECRET: 'has$dollar' }), /Unsupported character/);
  assert.throws(() => replaceEnvLines(text, { 'bad-name': 'x' }), /Unsupported variable name/);
  assert.throws(() => replaceEnvLines(text, { JWT_SECRET: 42 }), /Unsupported character/);
});
