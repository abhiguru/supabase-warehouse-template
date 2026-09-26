import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const kong = readFileSync(new URL('../docker/kong.yml', import.meta.url), 'utf8');
const compose = readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8');

test('gateway uses an exact configured browser origin and payload limits', () => {
  assert.ok(kong.includes('origins: [${CORS_ALLOWED_ORIGIN}]'));
  assert.ok(!kong.includes('origins: [*]'));
  assert.ok(kong.match(/name: request-size-limiting/g).length >= 4);
  assert.ok(compose.includes('request-size-limiting'));
  assert.ok(compose.includes('CORS_ALLOWED_ORIGIN:'));
});

test('gateway refreshes replaced Compose upstream addresses within readiness budget', () => {
  assert.ok(compose.includes('KONG_DNS_VALID_TTL: "5"'));
  assert.ok(compose.includes('KONG_DNS_STALE_TTL: "1"'));
  assert.ok(compose.includes('KONG_DNS_NOT_FOUND_TTL: "1"'));
});

test('operator gateway cannot route Studio or postgres-meta', () => {
  assert.doesNotMatch(kong, /url: http:\/\/(?:studio|meta):/);
  assert.equal((compose.match(/^\s+ports:/gm) || []).length, 1);
});
