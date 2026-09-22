import test from 'node:test';
import assert from 'node:assert/strict';
import { redactServiceLog } from '../scripts/service-diagnostics.mjs';

test('service diagnostics redact literal, URL and JSON encoded credentials', () => {
  const secret = 'fictional p@ss"\\word';
  const variants = [secret, encodeURIComponent(secret), JSON.stringify(secret).slice(1, -1)];
  const result = redactServiceLog(variants.join('\n'), { POSTGRES_PASSWORD: secret });
  for (const value of variants) assert.ok(!result.includes(value));
  assert.match(result, /REDACTED/);
});

test('service diagnostics hide derived JWTs and database URL passwords', () => {
  const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const token = [part({ alg: 'HS256' }), part({ sub: 'fictional' }), 'test_signature'].join('.');
  const text = `${token} ecto://admin:fictional-derived-secret@db/postgres`;
  const result = redactServiceLog(text, {});
  assert.ok(!result.includes('test_signature'));
  assert.ok(!result.includes('fictional-derived-secret'));
  assert.match(result, /@db\/postgres/);
});

test('service diagnostics preserve useful errors and handle empty values', () => {
  assert.equal(redactServiceLog('connection refused at db:5432', { JWT_SECRET: '', POSTGRES_HOST: 'db' }), 'connection refused at db:5432');
});
