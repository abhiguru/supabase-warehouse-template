import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const kong = readFileSync(new URL('../docker/kong.yml', import.meta.url), 'utf8');
const compose = readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8');
const deploy = name => new URL(`../deploy/${name}`, import.meta.url);

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

test('gateway takes the client address from the tunnel hop only and limits per client IP', () => {
  assert.ok(compose.includes('KONG_REAL_IP_HEADER: CF-Connecting-IP'));
  assert.ok(compose.includes('KONG_REAL_IP_RECURSIVE: "off"'));
  assert.ok(compose.includes('KONG_TRUSTED_IPS: "127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"'));
  assert.equal((kong.match(/name: rate-limiting/g) || []).length, 2);
  assert.equal((kong.match(/^\s+limit_by: ip$/gm) || []).length, 2);
  for (const service of ['rest-v1', 'functions-v1']) {
    const block = kong.slice(kong.indexOf(`- name: ${service}\n`));
    const rateLimit = block.slice(block.indexOf('name: rate-limiting'), block.indexOf('name: rate-limiting') + 400);
    assert.match(rateLimit, /policy: local[\s\S]*limit_by: ip/, `${service} rate limit is not keyed by client IP`);
  }
});

test('ingress is Cloudflare Tunnel only', () => {
  assert.ok(!existsSync(deploy('Caddyfile.example')), 'Caddy example must not ship');
  assert.ok(existsSync(deploy('cloudflared-config.example.yml')));
  assert.ok(existsSync(deploy('warehouse-tunnel.service.example')));
  const tunnel = readFileSync(deploy('cloudflared-config.example.yml'), 'utf8');
  assert.ok(tunnel.includes('service: http://127.0.0.1:18000'));
  assert.ok(tunnel.includes('noTLSVerify: false'));
  assert.ok(tunnel.includes('service: http_status:404'));
  const unit = readFileSync(deploy('warehouse-tunnel.service.example'), 'utf8');
  assert.match(unit, /^ExecStart=\/usr\/bin\/cloudflared --no-autoupdate --config \S+ tunnel run$/m);
  assert.doesNotMatch(unit, /--token(?:\s|=)/, 'tunnel tokens must never appear on the unit command line');
});

test('publisher images are pinned by digest and the notices name the versions in use', () => {
  const override = readFileSync(new URL('../docker/docker-compose.override.yml', import.meta.url), 'utf8');
  const images = [...`${compose}\n${override}`.matchAll(/^\s+image: (\S+)$/gm)].map(match => match[1]).filter(image => !image.endsWith(':local'));
  assert.ok(images.some(image => /^kong:3\.9\.3-ubuntu@sha256:[0-9a-f]{64}$/.test(image)), 'Kong is not pinned by digest');
  // PostgREST v16.4 still has no digest: the image was not available to read one
  // from when Kong was pinned (docs/CONTAINER_SECURITY.md, "Image pins").
  assert.deepEqual(images.filter(image => !/@sha256:[0-9a-f]{64}$/.test(image)), ['postgrest/postgrest:v16.4']);

  const notices = readFileSync(new URL('../THIRD_PARTY_NOTICES.md', import.meta.url), 'utf8');
  const review = readFileSync(new URL('../docs/ATTRIBUTION_REVIEW.md', import.meta.url), 'utf8');
  const base = (recipe, image) => new RegExp(`^FROM ${image}:([^@\\s]+)@sha256:`, 'm').exec(readFileSync(new URL(`../docker/${recipe}/Dockerfile`, import.meta.url), 'utf8'))?.[1];
  const versions = {
    Kong: /image: kong:([0-9.]+)-ubuntu/.exec(compose)[1],
    PostgREST: /image: postgrest\/postgrest:(v[0-9.]+)/.exec(compose)[1],
    Realtime: base('realtime', 'supabase/realtime'),
    Supavisor: base('supavisor', 'supabase/supavisor'),
    'edge-runtime': base('edge-runtime', 'supabase/edge-runtime'),
    Studio: base('studio', 'supabase/studio'),
    Gotenberg: base('gotenberg', 'gotenberg/gotenberg'),
    Grafana: base('grafana', 'grafana/grafana'),
  };
  for (const [name, version] of Object.entries(versions)) {
    assert.ok(version, `${name} version was not read`);
    const row = notices.split('\n').find(line => line.startsWith('|') && line.includes(name) && line.includes(version));
    assert.ok(row, `THIRD_PARTY_NOTICES.md does not name ${name} ${version}`);
    const short = name === 'Studio' ? version.split('-sha-')[0] : version;
    assert.ok(new RegExp(`${name} ${short.replaceAll('.', '\\.')}[,) ]`).test(review), `docs/ATTRIBUTION_REVIEW.md does not name ${name} ${short}`);
  }
  assert.doesNotMatch(`${notices}\n${review}`, /v1\.76\.2|postgrest:v14\.17|PostgREST v14\.17/);
});
