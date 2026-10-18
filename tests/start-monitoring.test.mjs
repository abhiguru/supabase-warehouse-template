// With a Slack webhook stored, setup.sh and start.sh start the monitoring services (scripts/start-monitoring.sh);
// without one (`--alert-webhook-file off`) monitoring stays optional. A stub compose.sh records what would run.
import test from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configure } from '../scripts/configure.mjs';

const repo = new URL('..', import.meta.url).pathname;
const read = path => readFileSync(join(repo, path), 'utf8');
const SERVICES = 'prometheus alertmanager postgres-exporter node-exporter cadvisor';

function fixture({ webhook, composeStatus = 0 }) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-start-monitoring-'));
  const root = join(dir, 'checkout');
  mkdirSync(join(root, 'scripts'), { recursive: true });
  copyFileSync(join(repo, 'scripts/start-monitoring.sh'), join(root, 'scripts/start-monitoring.sh'));
  const log = join(dir, 'compose.log');
  writeFileSync(join(root, 'scripts/compose.sh'), `#!/usr/bin/env bash\necho "$*" >> '${log}'\nexit ${composeStatus}\n`);
  chmodSync(join(root, 'scripts/compose.sh'), 0o755);
  const state = join(dir, 'state');
  mkdirSync(join(state, 'config/monitoring/alertmanager'), { recursive: true });
  if (webhook) writeFileSync(join(state, 'config/monitoring/alertmanager/webhook-url'), 'https://hooks.slack.com/services/T0000000/B0000000/fictionalfictionalfictional\n', { mode: 0o600 });
  const run = (...args) => spawnSync('bash', [join(root, 'scripts/start-monitoring.sh'), ...args], { encoding: 'utf8', env: { ...process.env, WAREHOUSE_STATE_DIR: state } });
  return { dir, run, calls: () => (existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n') : []), cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

test('a stored Slack webhook starts the five monitoring services; start never builds, setup builds what is missing', () => {
  const f = fixture({ webhook: true });
  try {
    assert.equal(f.run().status, 0);
    assert.deepEqual(f.calls(), [`--profile monitoring up -d --no-build --wait --wait-timeout 180 ${SERVICES}`]);
    rmSync(join(f.dir, 'compose.log'));
    assert.equal(f.run('--build').status, 0);
    assert.deepEqual(f.calls(), [`--profile monitoring build ${SERVICES}`, `--profile monitoring up -d --wait --wait-timeout 180 ${SERVICES}`]);
  } finally { f.cleanup(); }
});

test('without a webhook (off) nothing is started: monitoring stays optional', () => {
  const f = fixture({ webhook: false });
  try {
    assert.equal(f.run().status, 0);
    assert.equal(f.run('--build').status, 0);
    assert.deepEqual(f.calls(), []);
  } finally { f.cleanup(); }
});

test('a monitoring service that does not start is a loud warning, not a failed start', () => {
  const f = fixture({ webhook: true, composeStatus: 1 });
  try {
    const run = f.run();
    assert.equal(run.status, 0);
    assert.match(run.stderr, /Warning: the monitoring services did not start .* no alert will reach Slack/);
    const built = f.run('--build');
    assert.equal(built.status, 0);
    assert.match(built.stderr, /monitoring images did not build, so no alert will reach Slack/);
  } finally { f.cleanup(); }
});

test('setup.sh and start.sh call it after the optional services are replaced; stop.sh takes every profile down', () => {
  const setup = read('setup.sh');
  assert.ok(setup.indexOf('start-monitoring.sh" --build') > setup.indexOf('build-images.sh" --replace-optional'));
  const start = read('start.sh');
  assert.ok(start.indexOf('start-monitoring.sh') > start.indexOf('build-images.sh" --replace-optional'));
  assert.doesNotMatch(start, /start-monitoring\.sh" --build/, 'start.sh never builds');
  assert.match(read('stop.sh'), /--profile '\*' down/);
});

test('--company refuses what breaks the Alertmanager file: DEL, C1 controls (NEL), line and paragraph separators', () => {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-company-'));
  try {
    const root = join(dir, 'checkout');
    mkdirSync(root);
    copyFileSync(join(repo, '.env.example'), join(root, '.env.example'));
    const providerEnv = join(dir, 'provider.env');
    writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=0000000000000000001\nMSG91_SENDER_ID=CITEST\n', { mode: 0o600 });
    for (const bad of ['\u007f', '\u0080', '\u0085', '\u009f', ' ', ' ', '\n', '\u0000']) {
      assert.throws(() => configure(root, { stateDir: join(dir, 'bad'), apiUrl: 'https://company.example.test', company: `Acme${bad}Cold`, providerEnv }), /--company must be a printable name/, JSON.stringify(bad));
      assert.equal(existsSync(join(dir, 'bad')), false);
    }
    assert.equal(configure(root, { stateDir: join(dir, 'ok'), apiUrl: 'https://company.example.test', company: 'Gujarat Cold Storage ગુજરાત', providerEnv }).created, true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
