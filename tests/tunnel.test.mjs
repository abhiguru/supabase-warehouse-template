// scripts/tunnel.sh: adopting a tunnel credential into the state (and refusing the
// account certificate or another installation's tunnel), writing the systemd unit
// through shims, and backups carrying the credential.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, rmSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { repo } from './backup-test-helpers.mjs';

const TUNNEL = '0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d';
const HOST = 'warehouse.example.test';
const config = (creds, { host = HOST, extra = '' } = {}) => `# connector config
tunnel: ${TUNNEL}
credentials-file: ${creds}
${extra}ingress:
  - hostname: ${host}
    service: http://127.0.0.1:18000
    originRequest:
      httpHostHeader: ${host}
  - service: http_status:404
`;
const creds = (id = TUNNEL) => JSON.stringify({ AccountTag: 'acct', TunnelSecret: 'c2VjcmV0', TunnelID: id, Endpoint: '' });
// A fake connector token: the right shape (one line of 40+ token characters), no entropy.
const TOKEN = 'placeholder-token-' + 'x'.repeat(40);

function fixture(prefix) {
  const scratch = mkdtempSync(join(tmpdir(), prefix));
  const state = join(scratch, 'acme');
  for (const dir of ['', 'config', 'public', 'data', 'data/storage']) mkdirSync(join(state, dir), { mode: 0o700 });
  writeFileSync(join(state, 'config/compose.env'), 'WAREHOUSE_PROJECT_NAME=warehouse-test\n', { mode: 0o600 });
  writeFileSync(join(state, 'public/instance.json'), JSON.stringify({ schemaVersion: 1, canonicalOrigin: `https://${HOST}` }) + '\n');
  const priv = join(scratch, 'private'); mkdirSync(priv, { mode: 0o700 });
  writeFileSync(join(priv, 'tunnel.json'), creds(), { mode: 0o600 });
  writeFileSync(join(priv, 'config.yml'), config(join(priv, 'tunnel.json')), { mode: 0o600 });
  writeFileSync(join(priv, 'token'), TOKEN + '\n', { mode: 0o600 });
  const units = join(scratch, 'units');
  const bin = join(scratch, 'bin'); mkdirSync(bin);
  const log = join(scratch, 'calls.log'); writeFileSync(log, '');
  writeFileSync(join(bin, 'systemctl'), '#!/bin/sh\necho "systemctl $*" >> "$FAKE_LOG"\n[ "$1" = is-active ] && [ "$FAKE_INACTIVE" = yes ] && exit 3\nexit 0\n', { mode: 0o755 });
  writeFileSync(join(bin, 'id'), '#!/bin/sh\nif [ "$1" = -u ]; then echo "${FAKE_UID:-$(/usr/bin/id -u)}"; exit 0; fi\nexec /usr/bin/id "$@"\n', { mode: 0o755 });
  writeFileSync(join(bin, 'getent'), '#!/bin/sh\ncase "$1" in passwd) echo "installer:x:$2:$2::/home/installer:/bin/sh" ;; group) echo "installer:x:$2:" ;; esac\n', { mode: 0o755 });
  const run = (args, extra = {}) => spawnSync('bash', [join(repo, 'scripts/tunnel.sh'), ...args], { encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, WAREHOUSE_STATE_DIR: state, WAREHOUSE_TUNNEL_UNIT_DIR: units,
      FAKE_LOG: log, SUDO_UID: String(process.getuid()), SUDO_GID: String(process.getgid()), ...extra } });
  const asRoot = (args, extra = {}) => run(args, { FAKE_UID: '0', ...extra });
  return { scratch, state, priv, units, log, run, asRoot, calls: () => readFileSync(log, 'utf8') };
}
const clean = f => rmSync(f.scratch, { recursive: true, force: true });
const mode = path => statSync(path).mode & 0o777;

test('adopt --config copies the credential into the state and points the config at it', () => {
  const f = fixture('warehouse-tunnel-adopt-');
  try {
    const result = f.run(['adopt', '--config', join(f.priv, 'config.yml')]);
    assert.equal(result.status, 0, result.stderr);
    const dest = join(f.state, 'config/tunnel');
    assert.deepEqual(readdirSync(dest).sort(), ['config.yml', 'credentials.json']);
    assert.equal(mode(dest), 0o700);
    for (const file of ['config.yml', 'credentials.json']) assert.equal(mode(join(dest, file)), 0o600, file);
    assert.equal(readFileSync(join(dest, 'credentials.json'), 'utf8'), creds());
    assert.equal(readFileSync(join(dest, 'config.yml'), 'utf8'), config(join(dest, 'credentials.json')));
    assert.match(result.stdout, /install-service --state/);
    assert.deepEqual(readdirSync(join(f.state, 'config')).sort(), ['compose.env', 'tunnel'], 'no staging left');
    const again = f.run(['adopt', '--config', join(f.priv, 'config.yml')]);
    assert.equal(again.status, 1); assert.match(again.stderr, /already exists/);
  } finally { clean(f); }
});

test('adopt --token-file copies a dashboard token', () => {
  const f = fixture('warehouse-tunnel-token-');
  try {
    const result = f.run(['adopt', '--token-file', join(f.priv, 'token')]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(f.state, 'config/tunnel/token'), 'utf8'), TOKEN + '\n');
    assert.equal(mode(join(f.state, 'config/tunnel/token')), 0o600);
  } finally { clean(f); }
});

test('adopt refuses the account certificate, another tunnel or hostname, and bad arguments, creating nothing', () => {
  const f = fixture('warehouse-tunnel-refuse-');
  const cases = [
    [[], /exactly one of/],
    [['--config', 'x', '--token-file', 'y'], /exactly one of/],
    [['--config', 'CFG:extra=origincert: /home/u/.cloudflared/cert.pem\n'], /origincert/],
    [['--config', 'CFG:host=other.example.test'], /does not route warehouse\.example\.test/],
    [['--config', 'CFG:creds=mismatch'], /not the credentials JSON of tunnel/],
    [['--config', 'CFG:creds=pem'], /certificate or key block/],
    [['--token-file', 'TOKEN:multi'], /single-line connector token/],
    [['--token-file', 'TOKEN:pem'], /certificate or key block/],
  ];
  try {
    for (const [args, pattern] of cases) {
      const resolved = args.map(arg => {
        if (arg.startsWith('CFG:')) {
          const [key, ...rest] = arg.slice(4).split('='); const value = rest.join('=');
          let credsFile = join(f.priv, 'tunnel.json');
          if (key === 'creds') {
            credsFile = join(f.priv, `creds-${value}.json`);
            writeFileSync(credsFile, value === 'pem' ? '-----BEGIN ARGO TUNNEL TOKEN-----\nabc\n-----END ARGO TUNNEL TOKEN-----\n' : creds('ffffffff-ffff-4fff-8fff-ffffffffffff'));
          }
          const file = join(f.priv, `config-${key}.yml`);
          writeFileSync(file, config(credsFile, key === 'host' ? { host: value } : key === 'extra' ? { extra: value } : {}));
          return file;
        }
        if (arg.startsWith('TOKEN:')) {
          const file = join(f.priv, `token-${arg.slice(6)}`);
          writeFileSync(file, arg.endsWith('multi') ? `${TOKEN}\n${TOKEN}\n` : '-----BEGIN PRIVATE KEY-----\n');
          return file;
        }
        return arg;
      });
      const result = f.run(['adopt', ...resolved]);
      assert.equal(result.status, 1, `${args}: ${result.stdout}`);
      assert.match(result.stderr, pattern, String(args));
      assert.equal(existsSync(join(f.state, 'config/tunnel')), false, `${args}: nothing adopted`);
    }
    assert.deepEqual(readdirSync(join(f.state, 'config')), ['compose.env'], 'no staging left behind');
    const root = f.asRoot(['adopt', '--config', join(f.priv, 'config.yml')]);
    assert.equal(root.status, 1); assert.match(root.stderr, /not as root/);
  } finally { clean(f); }
});

test('install-service writes the unit for the state copy, as the sudo user, and restarts it', () => {
  const f = fixture('warehouse-tunnel-service-');
  try {
    let result = f.asRoot(['install-service']);
    assert.equal(result.status, 1); assert.match(result.stderr, /adopt first/);
    assert.equal(f.run(['adopt', '--config', join(f.priv, 'config.yml')]).status, 0);
    result = f.run(['install-service']);
    assert.equal(result.status, 1); assert.match(result.stderr, /with sudo/);
    result = f.asRoot(['install-service'], { SUDO_UID: '' });
    assert.equal(result.status, 1); assert.match(result.stderr, /SUDO_UID/);
    mkdirSync(f.units);
    writeFileSync(join(f.units, 'warehouse-acme-tunnel.service'), '[Service]\nExecStart=/usr/bin/cloudflared --config /home/u/private/config.yml tunnel run\n');
    result = f.asRoot(['install-service', '--state', f.state]);
    assert.equal(result.status, 0, result.stderr);
    const unit = readFileSync(join(f.units, 'warehouse-acme-tunnel.service'), 'utf8');
    assert.match(unit, new RegExp(`^ExecStart=/usr/bin/cloudflared --no-autoupdate --config ${f.state}/config/tunnel/config\\.yml tunnel run$`, 'm'));
    assert.match(unit, /^User=installer$/m);
    assert.equal(mode(join(f.units, 'warehouse-acme-tunnel.service')), 0o644);
    assert.ok(readdirSync(f.units).some(name => name.startsWith('warehouse-acme-tunnel.service.before-state-copy.')), 'previous unit kept');
    assert.match(f.calls(), /systemctl daemon-reload\nsystemctl enable warehouse-acme-tunnel\.service\nsystemctl restart warehouse-acme-tunnel\.service/);
    const status = f.run(['status']);
    assert.match(status.stdout, new RegExp(`locally managed tunnel ${TUNNEL}`));
    assert.match(status.stdout, /reads the state copy/);
    const failed = f.asRoot(['install-service'], { FAKE_INACTIVE: 'yes' });
    assert.equal(failed.status, 1); assert.match(failed.stderr, /did not start/);
  } finally { clean(f); }
});

test('install-service uses the token when the state holds a dashboard token', () => {
  const f = fixture('warehouse-tunnel-service-token-');
  try {
    assert.equal(f.run(['adopt', '--token-file', join(f.priv, 'token')]).status, 0);
    const result = f.asRoot(['install-service']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(readFileSync(join(f.units, 'warehouse-acme-tunnel.service'), 'utf8'),
      new RegExp(`^ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file ${f.state}/config/tunnel/token$`, 'm'));
  } finally { clean(f); }
});

test('status reports a state without a tunnel credential', () => {
  const f = fixture('warehouse-tunnel-status-');
  try {
    const result = f.run(['status']);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /not in the state; backups do not carry it/);
    assert.match(result.stdout, /Test override: WAREHOUSE_TUNNEL_UNIT_DIR=/);
    assert.match(result.stdout, /is not installed/);
  } finally { clean(f); }
});
