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

// ---- create: the guided login, tunnel, DNS route and adoption (fake cloudflared, never the real one) ----
const NEW_ID = '11111111-2222-4333-8444-555555555555';
function createFixture(prefix) {
  const f = fixture(prefix);
  const home = join(f.scratch, 'home'); mkdirSync(home);
  const tmp = join(f.scratch, 'tmp'); mkdirSync(tmp);
  writeFileSync(join(f.scratch, 'bin/cloudflared'), `#!/bin/sh
# Fake connector: records every call, never talks to Cloudflare.
echo "cloudflared $*" >> "$FAKE_LOG"
case "$1" in
  --config) [ "$FAKE_VALIDATE_FAIL" = yes ] && exit 1; echo "OK"; exit 0 ;;
esac
[ "$1" = tunnel ] || exit 2
shift
case "$1" in
  login)
    [ "$FAKE_LOGIN_FAIL" = yes ] && exit 1
    mkdir -p "$HOME/.cloudflared"; echo "-----BEGIN CERTIFICATE-----" > "$HOME/.cloudflared/cert.pem"
    [ "$FAKE_LOGIN_WRITE_FAIL" = yes ] && exit 1
    exit 0 ;;
esac
[ "$1" = --origincert ] || exit 2
cert="$2"; shift 2
[ -f "$cert" ] || { echo "no cert at $cert" >&2; exit 2; }
echo "cert-exists $cert" >> "$FAKE_LOG"
echo "tmpdir-mode $(stat -c %a "$(dirname "$cert")")" >> "$FAKE_LOG"
[ -e "$HOME/.cloudflared/cert.pem" ] && echo "home-cert-present" >> "$FAKE_LOG"
case "$1" in
  list) echo "\${FAKE_LIST_JSON:-[]}" ;;
  create)
    [ "$FAKE_CREATE_FAIL" = yes ] && { echo "create refused" >&2; exit 1; }
    # create --credentials-file FILE NAME
    printf '{"AccountTag":"acct","TunnelSecret":"c2VjcmV0","TunnelID":"${NEW_ID}"}' > "$3"
    chmod 0400 "$3"   # as the real cloudflared does
    if [ "$FAKE_CREATE_QUIET" = yes ]; then echo "done"; else echo "Created tunnel $4 with id ${NEW_ID}"; fi ;;
  route)
    [ "$FAKE_ROUTE_FAIL" = yes ] && { echo "record already exists" >&2; exit 1; }
    echo "Added CNAME \${FAKE_ROUTE_HOST:-$4} which will route to this tunnel" ;;
esac
`, { mode: 0o755 });
  writeFileSync(join(f.scratch, 'bin/shred'), '#!/bin/sh\necho "shred $*" >> "$FAKE_LOG"\nexec /usr/bin/shred "$@"\n', { mode: 0o755 });
  const runCreate = (args = [], extra = {}) => f.run(['create', ...args], { HOME: home, TMPDIR: tmp, ...extra });
  const callLines = () => f.calls().split('\n').filter(line => line.startsWith('cloudflared '));
  return { ...f, home, tmp, runCreate, callLines };
}
const leftovers = c => ({ cert: existsSync(join(c.home, '.cloudflared/cert.pem')), tmp: readdirSync(c.tmp) });

test('create logs in, creates the tunnel and route, adopts it, and leaves no certificate or temp files', () => {
  const c = createFixture('warehouse-tunnel-create-');
  try {
    writeFileSync(join(c.state, 'config/compose.env'), 'GATEWAY_HTTP_PORT=18123\n', { mode: 0o600 });
    const result = c.runCreate();
    assert.equal(result.status, 0, result.stderr + result.stdout);
    const calls = c.callLines().filter(line => !line.startsWith('cloudflared cert-exists'));
    assert.deepEqual(calls.map(line => line.replace(/ \/\S+/g, ' P')), [
      'cloudflared tunnel login',
      'cloudflared tunnel --origincert P list --output json',
      'cloudflared tunnel --origincert P create --credentials-file P warehouse-acme',
      `cloudflared tunnel --origincert P route dns ${NEW_ID} ${HOST}`,
      'cloudflared --config P tunnel ingress validate',
    ]);
    assert.ok(!c.calls().includes('--overwrite-dns'), 'never overwrites a DNS record');
    const dest = join(c.state, 'config/tunnel');
    assert.deepEqual(readdirSync(dest).sort(), ['config.yml', 'credentials.json']);
    const written = readFileSync(join(dest, 'config.yml'), 'utf8');
    assert.match(written, new RegExp(`^tunnel: ${NEW_ID}$`, 'm'));
    assert.match(written, new RegExp(`^credentials-file: ${dest}/credentials\\.json$`, 'm'));
    assert.match(written, new RegExp(`hostname: ${HOST.replace(/\./g, '\\.')}`));
    assert.match(written, /service: http:\/\/127\.0\.0\.1:18123$/m);
    assert.match(written, new RegExp(`httpHostHeader: ${HOST.replace(/\./g, '\\.')}`));
    assert.doesNotMatch(written, /origincert/);
    assert.match(readFileSync(join(dest, 'credentials.json'), 'utf8'), new RegExp(NEW_ID));
    assert.match(result.stdout, /install-service --state/);
    assert.deepEqual(leftovers(c), { cert: false, tmp: [] });
    // the cert was in a private (0700) directory while it was used, and no copy stayed in the home folder
    assert.ok(c.calls().match(/cert-exists (\S+)\/cert\.pem/));
    assert.match(c.calls(), /tmpdir-mode 700/); assert.doesNotMatch(c.calls(), /tmpdir-mode (?!700)/);
    assert.doesNotMatch(c.calls(), /home-cert-present/);
    // shredded, including the read-only (0400) credentials file cloudflared writes
    assert.match(c.calls(), /shred -fu -- \S+\/cert\.pem/);
    assert.match(c.calls(), new RegExp(`shred -fu -- \\S+/warehouse-acme\\.json`));
    assert.match(c.calls(), /shred -fu -- \S+\/config\.yml/);
    // already adopted now: refuse, nothing more is called
    const before = c.callLines().length;
    const again = c.runCreate();
    assert.equal(again.status, 1); assert.match(again.stderr, /already has a tunnel credential.*status/s);
    assert.equal(c.callLines().length, before);
  } finally { clean(c); }
});

test('create refuses a name already taken in the account and creates nothing', () => {
  const c = createFixture('warehouse-tunnel-create-taken-');
  try {
    const result = c.runCreate([], { FAKE_LIST_JSON: JSON.stringify([{ id: 'x', name: 'warehouse-acme' }]) });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /already exists in this account/);
    const calls = c.calls();
    assert.doesNotMatch(calls, / create /); assert.doesNotMatch(calls, /route dns/);
    assert.equal(existsSync(join(c.state, 'config/tunnel')), false);
    assert.deepEqual(leftovers(c), { cert: false, tmp: [] });
    const other = c.runCreate(['--name', 'warehouse-other'], { FAKE_LIST_JSON: JSON.stringify([{ id: 'x', name: 'warehouse-acme' }]) });
    assert.equal(other.status, 0, other.stderr);
    assert.match(c.calls(), /create --credentials-file \S+warehouse-other\.json warehouse-other/);
  } finally { clean(c); }
});

test('create stops on a DNS conflict, says how to delete the tunnel, and shreds the certificate', () => {
  const c = createFixture('warehouse-tunnel-create-dns-');
  try {
    const result = c.runCreate([], { FAKE_ROUTE_FAIL: 'yes' });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /not overwritten/);
    assert.match(result.stderr, new RegExp(`${NEW_ID}.*dashboard`, 's'));
    assert.doesNotMatch(c.calls(), /--overwrite-dns/);
    assert.doesNotMatch(c.calls(), /ingress validate/);
    assert.equal(existsSync(join(c.state, 'config/tunnel')), false);
    assert.deepEqual(leftovers(c), { cert: false, tmp: [] });
  } finally { clean(c); }
});

test('create removes the certificate and temp files when any later step fails', () => {
  for (const failure of [{ FAKE_CREATE_FAIL: 'yes' }, { FAKE_VALIDATE_FAIL: 'yes' }, { FAKE_LOGIN_FAIL: 'yes' }]) {
    const c = createFixture('warehouse-tunnel-create-fail-');
    try {
      const result = c.runCreate([], failure);
      assert.equal(result.status, 1, JSON.stringify(failure));
      assert.equal(existsSync(join(c.state, 'config/tunnel')), false, JSON.stringify(failure));
      assert.deepEqual(leftovers(c), { cert: false, tmp: [] }, JSON.stringify(failure));
    } finally { clean(c); }
  }
});

test('create refuses root, an existing account certificate, and a bad name', () => {
  const c = createFixture('warehouse-tunnel-create-refuse-');
  try {
    assert.match(c.asRoot(['create'], { HOME: c.home }).stderr, /not as root/);
    assert.match(c.runCreate(['--name', 'bad name']).stderr, /Not a usable tunnel name/);
    mkdirSync(join(c.home, '.cloudflared'));
    writeFileSync(join(c.home, '.cloudflared/cert.pem'), 'old');
    const result = c.runCreate();
    assert.equal(result.status, 1); assert.match(result.stderr, /already exists/);
    assert.equal(readFileSync(join(c.home, '.cloudflared/cert.pem'), 'utf8'), 'old', 'a certificate that was there before is not touched');
    assert.equal(c.callLines().length, 0);
  } finally { clean(c); }
});

test('create stops when the picked domain does not contain the hostname (exit 0, wrong record)', () => {
  const c = createFixture('warehouse-tunnel-create-zone-');
  try {
    const result = c.runCreate([], { FAKE_ROUTE_HOST: `${HOST}.other-zone.test` });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /record was not created for warehouse\.example\.test/);
    assert.match(result.stderr, new RegExp(`Delete tunnel warehouse-acme \\(${NEW_ID}\\)`));
    assert.match(result.stderr, /domain that contains/);
    assert.doesNotMatch(c.calls(), /ingress validate/);
    assert.equal(existsSync(join(c.state, 'config/tunnel')), false);
    assert.deepEqual(leftovers(c), { cert: false, tmp: [] });
  } finally { clean(c); }
});

test('create reads the tunnel id from the credentials file and tells how to clean up after a later failure', () => {
  const c = createFixture('warehouse-tunnel-create-late-');
  try {
    const result = c.runCreate([], { FAKE_CREATE_QUIET: 'yes', FAKE_VALIDATE_FAIL: 'yes' });
    assert.equal(result.status, 1);
    assert.match(c.calls(), new RegExp(`route dns ${NEW_ID} `));
    assert.match(result.stderr, new RegExp(`Delete tunnel warehouse-acme \\(${NEW_ID}\\) and the warehouse\\.example\\.test record in the Cloudflare dashboard`));
  } finally { clean(c); }
});

test('create uses KONG_HTTP_PORT when GATEWAY_HTTP_PORT is absent, and GATEWAY_HTTP_PORT first', () => {
  for (const [env, port] of [['KONG_HTTP_PORT=18456\n', 18456], ['KONG_HTTP_PORT=18456\nGATEWAY_HTTP_PORT=18457\n', 18457]]) {
    const c = createFixture('warehouse-tunnel-create-port-');
    try {
      writeFileSync(join(c.state, 'config/compose.env'), env, { mode: 0o600 });
      assert.equal(c.runCreate().status, 0);
      assert.match(readFileSync(join(c.state, 'config/tunnel/config.yml'), 'utf8'), new RegExp(`service: http://127\\.0\\.0\\.1:${port}$`, 'm'));
    } finally { clean(c); }
  }
});

test('create removes a certificate that login wrote before it failed', () => {
  const c = createFixture('warehouse-tunnel-create-loginfail-');
  try {
    const result = c.runCreate([], { FAKE_LOGIN_WRITE_FAIL: 'yes' });
    assert.equal(result.status, 1);
    assert.equal(existsSync(join(c.home, '.cloudflared/cert.pem')), false, 'the account certificate does not survive');
    assert.deepEqual(leftovers(c).tmp, []);
  } finally { clean(c); }
});
