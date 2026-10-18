// Every alert rule in docker/alert-rules.yml has a promtool test that fires and one that stays quiet
// (docker/alert-rules.test.yml). Until 2026-10-17 one rule of 17 was tested. promtool itself runs in
// scripts/alert-rules-check.sh and scripts/monitoring-check.sh; this file keeps the test file complete
// without Docker, and runs promtool when the pinned image is already on the host.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

const alerts = () => [...read('docker/alert-rules.yml').matchAll(/^\s+- alert: (\S+)\s*$/gm)].map(match => match[1]);

// The shape alert-rules.test.yml documents at its top: `alertname: Name` followed by `exp_alerts: []`
// (the rule stays quiet) or by `exp_alerts:` and `- exp_labels:` (it fires). Anything else is refused,
// so a case cannot hide from this check by being formatted differently.
function cases() {
  const lines = read('docker/alert-rules.test.yml').split('\n');
  const found = [];
  lines.forEach((line, index) => {
    const match = line.match(/^\s+alertname: (\S+)\s*$/);
    if (!match) return;
    if (/^\s+exp_alerts: \[\]\s*$/.test(lines[index + 1] ?? '')) found.push({ alert: match[1], fires: false });
    else if (/^\s+exp_alerts:\s*$/.test(lines[index + 1] ?? '') && /^\s+- exp_labels:\s*$/.test(lines[index + 2] ?? '')) found.push({ alert: match[1], fires: true });
    else assert.fail(`alert-rules.test.yml line ${index + 1}: ${match[1]} is followed by neither "exp_alerts: []" nor "exp_alerts:" with "- exp_labels:"`);
  });
  return found;
}

test('there are 20 alert rules with distinct names, two of them the backup rules', () => {
  const names = alerts();
  assert.equal(names.length, 20);
  assert.equal(new Set(names).size, 20);
  assert.ok(names.includes('BackupMissing') && names.includes('BackupFailed'));
});

test('every alert rule has a promtool case that fires and one that stays quiet', () => {
  const found = cases();
  const missing = [];
  for (const alert of alerts()) {
    for (const fires of [true, false]) {
      // Watchdog (vector(1)) fires by design and cannot stay quiet.
      if (alert === 'Watchdog' && !fires) continue;
      if (!found.some(item => item.alert === alert && item.fires === fires)) missing.push(`${alert} (${fires ? 'fires' : 'stays quiet'})`);
    }
  }
  assert.deepEqual(missing, [], `alert-rules.test.yml lacks a case for: ${missing.join(', ')}`);
});

test('every alertname in the rule tests is a rule that exists', () => {
  const names = new Set(alerts());
  const unknown = [...new Set(cases().map(item => item.alert).filter(alert => !names.has(alert)))];
  assert.deepEqual(unknown, [], `alert-rules.test.yml tests rules that do not exist: ${unknown.join(', ')}`);
});

test('the backup rules read the series that the backup scripts write', () => {
  const rules = read('docker/alert-rules.yml');
  const writer = read('scripts/backup-metrics.sh');
  for (const metric of ['warehouse_backup_last_success_timestamp_seconds', 'warehouse_backup_last_attempt_success']) {
    assert.ok(rules.includes(metric), `${metric} is not in an alert rule`);
    assert.ok(writer.includes(`${metric}{kind=`), `${metric} is not written by backup-metrics.sh`);
  }
  // 26 hours: a daily backup and two hours of slack (owner decision D9).
  assert.match(rules, /alert: BackupMissing\n(?:\s+#.*\n)*\s+expr: \(time\(\) - warehouse_backup_last_success_timestamp_seconds\{kind="disk"\} > 26 \* 3600\) or absent\(warehouse_backup_last_success_timestamp_seconds\{kind="disk"\}\)\n/);
});

test('the rule checks run promtool from the pinned image with no network', () => {
  const script = read('scripts/alert-rules-check.sh');
  assert.match(script, /--network none/);
  assert.match(script, /prom\\\/prometheus:\[\^ \]\*@sha256/, 'the image is read from the recipe, by digest');
  assert.match(script, /prom\\\/alertmanager:\[\^ \]\*@sha256/);
  assert.equal([...script.matchAll(/docker run --rm --network none/g)].length, 2, 'both containers have no network');
  assert.match(read('docker/prometheus/Dockerfile'), /^FROM prom\/prometheus:v[0-9.]+@sha256:[0-9a-f]{64}$/m);
  assert.match(read('package.json'), /"test:alert-rules": "bash scripts\/alert-rules-check\.sh"/);
});

// With the pinned image on the host (CI pulls it for the monitoring check; a contributor machine may not
// have it), the real promtool must accept the rules, the rendered configuration and every case. Never pulled here.
const pinned = [['prometheus', 'prom/prometheus'], ['alertmanager', 'prom/alertmanager']]
  .map(([recipe, image]) => new RegExp(`^FROM (${image}:[^ ]*@sha256:[0-9a-f]{64})$`, 'm').exec(read(`docker/${recipe}/Dockerfile`))?.[1]);
const imagePresent = pinned.every(image => image && spawnSync('docker', ['image', 'inspect', image], { stdio: 'ignore' }).status === 0);
test('promtool and amtool accept the rules, the rendered configuration, both Alertmanager files and every case', { skip: imagePresent ? false : 'the pinned Prometheus and Alertmanager images are not on this host' }, () => {
  const result = spawnSync('bash', [new URL('../scripts/alert-rules-check.sh', import.meta.url).pathname], { encoding: 'utf8', timeout: 240000 });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /passed promtool and amtool/);
});
