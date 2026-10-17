// Per-installation monitoring (TW-BE-008): the rendered Prometheus configuration, the optional alert
// webhook, the files setup writes into the state, and the doctor warning while alerts stay on this host.
import test from 'node:test';
import assert from 'node:assert/strict';
import { appendFileSync, chmodSync, copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { composeAvailable } from './compose-render.mjs';
import { configure, parseConfigureArgs } from '../scripts/configure.mjs';
import { alertDeliveryWarning, alertWebhookAddress, readAlertWebhook, renderPrometheusConfig } from '../scripts/monitoring-config.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const template = read('docker/prometheus.yml');
const PROJECT = 'warehouse-0f1e2d3c4b5a';

// Applies the rendered cAdvisor metric_relabel_configs (one `keep` rule) to a series' labels.
function keptByCadvisorJob(config, labels) {
  const job = config.slice(config.indexOf("job_name: 'cadvisor'"), config.indexOf("job_name: 'kong'"));
  const sources = /source_labels: \[([a-z_, ]+)\]/.exec(job)[1].split(/,\s*/);
  const regex = /regex: '([^']*)'/.exec(job)[1];
  assert.match(job, /action: keep/);
  // Prometheus joins the source labels with ";" (the default separator) and anchors the regex.
  return new RegExp(`^(?:${regex})$`).test(sources.map(source => labels[source] ?? '').join(';'));
}

test('the rendered configuration carries the installation label and nothing is left to substitute', () => {
  const config = renderPrometheusConfig(template, PROJECT);
  assert.match(config, new RegExp(`^  external_labels:\\n    installation: ${PROJECT}$`, 'm'));
  assert.match(config, new RegExp(`source_labels: \\[container_label_com_docker_compose_project, name\\]\\n\\s+regex: '${PROJECT};\\.\\*\\|;'`));
  assert.doesNotMatch(config, /\$\{/);
  assert.ok(config.includes('- /etc/prometheus/alert-rules.yml'), 'the rest of the template is unchanged');
  // Another installation gets its own file.
  assert.notEqual(renderPrometheusConfig(template, 'warehouse-ffffffffffff'), config);
});

test('only a Compose project name this repository creates is accepted', () => {
  for (const bad of ['', 'warehouse-', 'Warehouse-ABC', 'warehouse-a b', 'warehouse-a|b', "warehouse-a'b", 'warehouse-a.b', 'warehouse-a\nb', 'identity-dev', undefined]) {
    assert.throws(() => renderPrometheusConfig(template, bad), /WAREHOUSE_PROJECT_NAME must be warehouse-/, JSON.stringify(bad));
  }
  assert.throws(() => renderPrometheusConfig('global: {}\n', PROJECT), /no longer carries the project placeholder/);
  assert.throws(() => renderPrometheusConfig(`${template}\n# \${HOME}\n`, PROJECT), /variable other than the project placeholder/);
});

test('the cAdvisor job keeps its own installation and the series of no container, and drops the others', () => {
  const config = renderPrometheusConfig(template, PROJECT);
  const project = (value, name = `${value}-db-1`) => ({ container_label_com_docker_compose_project: value, name });
  assert.equal(keptByCadvisorJob(config, project(PROJECT)), true, 'its own containers');
  assert.equal(keptByCadvisorJob(config, {}), true, 'machine_* and cadvisor_version_info have no project label and no container name');
  assert.equal(keptByCadvisorJob(config, project('', '')), true, 'a series with neither a project nor a name');
  assert.equal(keptByCadvisorJob(config, project('', 'wh-ops-b8-devdb')), false, 'a `docker run` container is not an installation\'s (ContainerOOM has no Compose filter)');
  assert.equal(keptByCadvisorJob(config, project('', 'warehouse-grafana-smoke-1')), false, 'a helper container named like an installation');
  assert.equal(keptByCadvisorJob(config, project(PROJECT, '')), true, 'its own project, whatever the name');
  assert.equal(keptByCadvisorJob(config, project('warehouse-ffffffffffff')), false, 'another installation on the host');
  assert.equal(keptByCadvisorJob(config, project('central-identity-dev')), false, 'the identity stack');
  assert.equal(keptByCadvisorJob(config, project(`${PROJECT}0`)), false, 'a project whose name starts with this one');
  assert.equal(keptByCadvisorJob(config, project(PROJECT.slice(0, -1))), false, 'a project whose name is a prefix of this one');
  assert.equal(keptByCadvisorJob(config, project(`x${PROJECT}`)), false, 'a project whose name ends with this one');
});

test('the other scrape jobs are not filtered', () => {
  const config = renderPrometheusConfig(template, PROJECT);
  assert.equal([...config.matchAll(/metric_relabel_configs/g)].length, 1);
  assert.deepEqual([...config.matchAll(/job_name: '([a-z-]+)'/g)].map(match => match[1]), ['prometheus', 'postgres', 'node', 'cadvisor', 'kong']);
});

test('an alert webhook address is one https:// URL, and the error never quotes it', () => {
  assert.equal(alertWebhookAddress('https://alerts.example.test/hook/abc123\n'), 'https://alerts.example.test/hook/abc123');
  assert.equal(alertWebhookAddress('﻿  https://alerts.example.test/h?token=t  \r\n'), 'https://alerts.example.test/h?token=t');
  for (const bad of ['', 'http://alerts.example.test/h', 'ftp://alerts.example.test/h', 'https://user:pw@alerts.example.test/h', 'https://alerts.example.test/h#x',
    'https://alerts.example.test/a b', 'https://alerts.example.test/\'x', 'https://alerts.example.test/\\x', 'two\nhttps://alerts.example.test/h', 'not a url']) {
    assert.throws(() => alertWebhookAddress(bad), error => /^--alert-webhook-file must hold one https:\/\/ address/.test(error.message) && !error.message.includes('alerts.example.test'), JSON.stringify(bad));
  }
});

function fixture() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-monitoring-config-'));
  const root = join(scratch, 'checkout');
  mkdirSync(root);
  copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
  const providerEnv = join(scratch, 'provider.env');
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=isolated-no-delivery-key\nMSG91_TEMPLATE_ID=000000000000000000000001\nMSG91_PE_ID=0000000000000000001\nMSG91_SENDER_ID=CITEST\n', { mode: 0o600 });
  const stateDir = join(scratch, 'state');
  const webhookFile = join(scratch, 'webhook.txt');
  writeFileSync(webhookFile, 'https://alerts.example.test/hook/not-a-real-token\n', { mode: 0o600 });
  const options = { stateDir, apiUrl: 'https://monitoring.example.test', company: 'Monitoring Config', providerEnv };
  const monitoring = join(stateDir, 'config/monitoring');
  const files = () => ({
    prometheus: join(monitoring, 'prometheus.yml'), alertmanager: join(monitoring, 'alertmanager/alertmanager.yml'),
    webhook: join(monitoring, 'alertmanager/webhook-url'), metrics: join(stateDir, 'metrics'),
  });
  return { scratch, root, stateDir, options, webhookFile, files: files(), project: () => /^WAREHOUSE_PROJECT_NAME=(.*)$/m.exec(readFileSync(join(stateDir, 'config/compose.env'), 'utf8'))[1],
    cleanup: () => rmSync(scratch, { recursive: true, force: true }) };
}

test('setup writes the installation\'s Prometheus file, a local-only Alertmanager file and the textfile directory', () => {
  const f = fixture();
  try {
    const result = configure(f.root, f.options);
    assert.equal(result.created, true);
    const project = f.project();
    assert.match(project, /^warehouse-[0-9a-f-]{12}$/);
    assert.equal(readFileSync(f.files.prometheus, 'utf8'), renderPrometheusConfig(template, project));
    assert.equal(statSync(f.files.prometheus).mode & 0o777, 0o644, 'the prometheus container runs as another user and reads it');
    assert.equal(readFileSync(f.files.alertmanager, 'utf8'), read('docker/alertmanager.yml'), 'no webhook: the local-only receiver');
    assert.equal(existsSync(f.files.webhook), false);
    assert.equal(statSync(join(f.stateDir, 'config/monitoring')).mode & 0o777, 0o700);
    // The directory the backup scripts write and node exporter (another user) reads.
    assert.equal(statSync(f.files.metrics).mode & 0o777, 0o755);
    assert.deepEqual(readdirSync(f.files.metrics), []);
    // Alertmanager's silences and notification log: private, and the installing user's (it runs as that user).
    assert.equal(statSync(join(f.stateDir, 'data/alertmanager')).mode & 0o777, 0o700);
    assert.equal(statSync(join(f.stateDir, 'data/alertmanager')).uid, process.getuid());
    // A rerun with the same inputs changes nothing.
    const again = configure(f.root, f.options);
    assert.equal(again.created, false);
    assert.equal(again.monitoringUpdated, false);
  } finally { f.cleanup(); }
});

test('an installation from before these files gets them on the next setup run, and another installation gets its own', () => {
  const f = fixture();
  const other = fixture();
  try {
    configure(f.root, f.options);
    configure(other.root, other.options);
    assert.notEqual(f.project(), other.project());
    const expected = readFileSync(f.files.prometheus, 'utf8');
    assert.match(expected, new RegExp(`installation: ${f.project()}\\n`));
    assert.doesNotMatch(expected, new RegExp(other.project()));
    rmSync(join(f.stateDir, 'config/monitoring'), { recursive: true });
    rmSync(f.files.metrics, { recursive: true });
    const result = configure(f.root, f.options);
    assert.equal(result.monitoringUpdated, true);
    assert.equal(readFileSync(f.files.prometheus, 'utf8'), expected);
    assert.equal(statSync(f.files.metrics).mode & 0o777, 0o755);
    // A hand-edited file is put back; the content decides, not the date.
    writeFileSync(f.files.prometheus, '# edited\n', { mode: 0o644 });
    assert.equal(configure(f.root, f.options).monitoringUpdated, true);
    assert.equal(readFileSync(f.files.prometheus, 'utf8'), expected);
  } finally { f.cleanup(); other.cleanup(); }
});

test('--alert-webhook-file stores the address privately and renders a webhook receiver that reads it from the file', () => {
  const f = fixture();
  try {
    configure(f.root, f.options);
    assert.equal(readFileSync(f.files.alertmanager, 'utf8'), read('docker/alertmanager.yml'));
    const result = configure(f.root, { ...f.options, alertWebhookFile: f.webhookFile });
    assert.equal(result.monitoringUpdated, true);
    assert.equal(result.webhook, true);
    assert.doesNotMatch(JSON.stringify(result), /not-a-real-token|alerts\.example\.test/, 'the result never carries the address');
    assert.equal(readFileSync(f.files.webhook, 'utf8'), 'https://alerts.example.test/hook/not-a-real-token\n');
    assert.equal(statSync(f.files.webhook).mode & 0o777, 0o600, 'the address is a secret');
    const rendered = readFileSync(f.files.alertmanager, 'utf8');
    assert.equal(rendered, read('docker/alertmanager.webhook.yml'));
    assert.match(rendered, /webhook_configs:\n      - url_file: \/etc\/alertmanager\/webhook-url\n/);
    assert.doesNotMatch(rendered, /alerts\.example\.test/, 'the address is in the 0600 file, not in the configuration');
    assert.doesNotMatch(readFileSync(f.files.prometheus, 'utf8'), /alerts\.example\.test/);
    // A rerun without the option keeps it; a rerun with the same file changes nothing.
    assert.equal(configure(f.root, f.options).monitoringUpdated, false);
    assert.equal(readFileSync(f.files.webhook, 'utf8'), 'https://alerts.example.test/hook/not-a-real-token\n');
    assert.equal(configure(f.root, { ...f.options, alertWebhookFile: f.webhookFile }).monitoringUpdated, false);
    // A new address replaces it.
    writeFileSync(f.webhookFile, 'https://alerts.example.test/hook/second\n', { mode: 0o600 });
    assert.equal(configure(f.root, { ...f.options, alertWebhookFile: f.webhookFile }).monitoringUpdated, true);
    assert.equal(readFileSync(f.files.webhook, 'utf8'), 'https://alerts.example.test/hook/second\n');
    // `off` goes back to the local-only receiver and forgets the address.
    const off = configure(f.root, { ...f.options, alertWebhookFile: 'off' });
    assert.equal(off.monitoringUpdated, true);
    assert.equal(off.webhook, null);
    assert.equal(existsSync(f.files.webhook), false);
    assert.equal(readFileSync(f.files.alertmanager, 'utf8'), read('docker/alertmanager.yml'));
  } finally { f.cleanup(); }
});

test('a fresh setup can take the webhook, and a refused file changes nothing', () => {
  const f = fixture();
  try {
    configure(f.root, { ...f.options, alertWebhookFile: f.webhookFile });
    assert.equal(statSync(f.files.webhook).mode & 0o777, 0o600);
    assert.equal(readFileSync(f.files.alertmanager, 'utf8'), read('docker/alertmanager.webhook.yml'));
  } finally { f.cleanup(); }
  const g = fixture();
  try {
    const refuse = (alertWebhookFile, pattern) => {
      assert.throws(() => configure(g.root, { ...g.options, alertWebhookFile }), error => pattern.test(error.message) && !error.message.includes('alerts.example.test'), String(alertWebhookFile));
      assert.equal(existsSync(g.stateDir), false, 'a refused option creates no state');
    };
    refuse('relative/webhook.txt', /absolute path/);
    refuse(join(g.scratch, 'missing.txt'), /regular file/);
    const open = join(g.scratch, 'open.txt');
    writeFileSync(open, 'https://alerts.example.test/h\n', { mode: 0o644 });
    refuse(open, /mode 0600/);
    const plain = join(g.scratch, 'plain.txt');
    writeFileSync(plain, 'http://alerts.example.test/h\n', { mode: 0o600 });
    refuse(plain, /https:\/\/ address/);
    const big = join(g.scratch, 'big.txt');
    writeFileSync(big, `https://alerts.example.test/${'a'.repeat(3000)}\n`, { mode: 0o600 });
    refuse(big, /larger than 2 KB/);
    const link = join(g.scratch, 'link.txt');
    symlinkSync(g.webhookFile, link);
    refuse(link, /regular file/);
    const inside = join(g.root, 'webhook.txt');
    writeFileSync(inside, 'https://alerts.example.test/h\n', { mode: 0o600 });
    refuse(inside, /outside the checkout/);
    // An installed state keeps what it had when the new file is refused.
    configure(g.root, { ...g.options, alertWebhookFile: g.webhookFile });
    const before = readFileSync(g.files.webhook, 'utf8');
    assert.throws(() => configure(g.root, { ...g.options, alertWebhookFile: open }), /mode 0600/);
    assert.equal(readFileSync(g.files.webhook, 'utf8'), before);
    assert.equal(lstatSync(g.files.webhook).isFile(), true);
    chmodSync(open, 0o600);
  } finally { g.cleanup(); }
});

test('setup.sh passes --alert-webhook-file to configure.mjs and the option is parsed', () => {
  assert.deepEqual(parseConfigureArgs(['--state-dir', '/s', '--alert-webhook-file', '/w']), { stateDir: '/s', alertWebhookFile: '/w' });
  assert.deepEqual(parseConfigureArgs(['--state-dir', '/s', '--alert-webhook-file', 'off']), { stateDir: '/s', alertWebhookFile: 'off' });
  const setup = read('setup.sh');
  assert.match(setup, /--central-local-code\|--alert-webhook-file\)/);
  assert.match(setup, /\*\) CONFIG_ARGS\+=\("\$1" "\$2"\) ;;/, 'an option setup does not handle itself goes to configure.mjs');
});

test('doctor warns while Alertmanager has no receiver outside this host, and not once it has one', () => {
  const f = fixture();
  try {
    configure(f.root, f.options);
    const warning = alertDeliveryWarning(f.stateDir);
    assert.match(warning, /^Alerts are local only: Alertmanager is running with no receiver/);
    assert.match(warning, /--alert-webhook-file/);
    assert.match(warning, /docs\/MONITORING\.md/);
    configure(f.root, { ...f.options, alertWebhookFile: f.webhookFile });
    assert.equal(alertDeliveryWarning(f.stateDir), null);
    configure(f.root, { ...f.options, alertWebhookFile: 'off' });
    assert.match(alertDeliveryWarning(f.stateDir), /local only/);
    // doctor.mjs asks only while the alertmanager container is running.
    const doctor = read('scripts/doctor.mjs');
    assert.match(doctor, /'--profile', '\*', 'ps', '-q', 'alertmanager'\]\)\.output\.trim\(\) \? alertDeliveryWarning\(state\) : null/);
  } finally { f.cleanup(); }
});

test('readAlertWebhook leaves the state alone when the option is not given', () => {
  assert.equal(readAlertWebhook(undefined, '/nowhere'), undefined);
  assert.equal(readAlertWebhook('off', '/nowhere'), null);
});

// The label that makes `compose up` replace a running Prometheus or Alertmanager when what it mounts
// changes (neither reloads by itself; Prometheus runs without --web.enable-lifecycle).
const skipCompose = !composeAvailable() && !process.env.CI ? 'docker compose is not installed' : false;
test('compose replaces the monitoring containers when their rendered configuration or the rules change', { skip: skipCompose }, () => {
  const f = fixture();
  const repo = new URL('..', import.meta.url).pathname;
  const sha = (...parts) => createHash('sha256').update(Buffer.concat(parts.map(part => readFileSync(part)))).digest('hex');
  try {
    configure(repo, f.options);
    const labels = () => {
      const run = spawnSync('bash', [join(repo, 'scripts/compose.sh'), '--profile', '*', 'config', '--format', 'json'], {
        encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, env: { ...process.env, WAREHOUSE_STATE_DIR: f.stateDir },
      });
      assert.equal(run.status, 0, run.stderr);
      const config = JSON.parse(run.stdout);
      assert.doesNotMatch(run.stdout, /not-a-real-token|alerts\.example\.test/, 'the webhook address is in no compose value');
      return { prometheus: config.services.prometheus.labels['com.warehouse.config-sha256'], alertmanager: config.services.alertmanager.labels['com.warehouse.config-sha256'], config };
    };
    const first = labels();
    assert.equal(first.prometheus, sha(f.files.prometheus, join(repo, 'docker/alert-rules.yml')), 'rendered Prometheus configuration then the rules');
    assert.equal(first.alertmanager, sha(f.files.alertmanager));
    assert.notEqual(first.prometheus, first.alertmanager);
    assert.deepEqual({ ...labels(), config: 0 }, { ...first, config: 0 }, 'stable while nothing changes');
    // An address given to setup changes the Alertmanager file, not Prometheus'.
    configure(repo, { ...f.options, alertWebhookFile: f.webhookFile });
    const withWebhook = labels();
    assert.notEqual(withWebhook.alertmanager, first.alertmanager);
    assert.equal(withWebhook.prometheus, first.prometheus);
    // A change to the rendered Prometheus file changes only Prometheus'.
    appendFileSync(f.files.prometheus, '# changed\n');
    const edited = labels();
    assert.notEqual(edited.prometheus, withWebhook.prometheus);
    assert.equal(edited.alertmanager, withWebhook.alertmanager);
    // The mounts: setup's rendered files, read-only, and no host directory created on a miss.
    const mount = (service, target) => edited.config.services[service].volumes.find(volume => volume.target === target);
    for (const [service, target, source] of [
      ['prometheus', '/etc/prometheus/prometheus.yml', f.files.prometheus],
      ['alertmanager', '/etc/alertmanager', join(f.stateDir, 'config/monitoring/alertmanager')],
      ['node-exporter', '/var/lib/node_exporter/textfile', f.files.metrics],
    ]) {
      const volume = mount(service, target);
      assert.equal(volume.source, source, `${service} mounts ${source}`);
      assert.equal(volume.read_only, true, `${service} reads ${target} read-only`);
      assert.equal(volume.bind.create_host_path, false, `${service}: a missing source is an error, not a directory made by Docker`);
    }
    assert.deepEqual(mount('prometheus', '/etc/prometheus/alert-rules.yml').source, join(repo, 'docker/alert-rules.yml'));
    assert.ok(edited.config.services['node-exporter'].command.includes('--collector.textfile.directory=/var/lib/node_exporter/textfile'));
    assert.equal(mount('grafana', '/etc/grafana/dashboards').source, join(repo, 'docker/volumes/grafana/dashboards'));
    assert.equal(mount('grafana', '/etc/grafana/dashboards').read_only, true);
    // Alertmanager reads the 0600 address as the installing user, with its own writable storage.
    assert.equal(edited.config.services.alertmanager.user, `${process.getuid()}:${process.getgid()}`);
    // Silences and the notification log live in a state directory, so they survive the replacement `compose up` does.
    assert.ok(edited.config.services.alertmanager.command.includes('--storage.path=/alertmanager'));
    const storage = mount('alertmanager', '/alertmanager');
    assert.equal(storage.source, join(f.stateDir, 'data/alertmanager'));
    assert.notEqual(storage.read_only, true);
    assert.equal(storage.bind.create_host_path, false);
  } finally { f.cleanup(); }
});

// The shipped Grafana dashboard (TW-BE-021). scripts/grafana-check.sh runs its queries against a live Grafana
// and Prometheus in CI; these checks need neither.
test('the overview dashboard is built from the series the rules and exporters provide, on the provisioned datasource', () => {
  const dashboard = JSON.parse(read('docker/volumes/grafana/dashboards/warehouse-overview.json'));
  assert.equal(dashboard.uid, 'warehouse-overview');
  assert.equal(dashboard.title, 'Warehouse overview');
  assert.equal(dashboard.editable, false);
  const uid = /name: Prometheus\n(?:\s+#.*\n)*\s+uid: (\S+)\n/.exec(read('docker/volumes/grafana/provisioning/datasources/datasources.yml'))?.[1];
  assert.equal(uid, 'PBFA97CFB590B2093', 'the datasource uid is pinned');
  const allowed = new Set(['pg_up', 'pg_stat_activity_count', 'pg_stat_activity_max_tx_duration', 'kong_http_requests_total', 'kong_request_latency_ms_bucket',
    'node_filesystem_avail_bytes', 'node_filesystem_size_bytes', 'container_memory_usage_bytes', 'warehouse_backup_last_success_timestamp_seconds', 'up', 'ALERTS',
    'container_label_com_docker_compose_service']);
  const names = new Set();
  const ids = new Set();
  const rectangles = [];
  for (const panel of dashboard.panels) {
    assert.ok(!ids.has(panel.id), `panel id ${panel.id} is used twice`);
    ids.add(panel.id);
    const { x, y, w, h } = panel.gridPos;
    assert.ok(x >= 0 && w > 0 && x + w <= 24, `${panel.title} fits the 24 columns`);
    for (const other of rectangles) assert.ok(x + w <= other.x || other.x + other.w <= x || y + h <= other.y || other.y + other.h <= y, `${panel.title} overlaps ${other.title}`);
    rectangles.push({ x, y, w, h, title: panel.title });
    assert.deepEqual(panel.datasource, { type: 'prometheus', uid });
    assert.ok(panel.targets.length > 0, `${panel.title} has a query`);
    for (const target of panel.targets) {
      assert.deepEqual(target.datasource, { type: 'prometheus', uid });
      for (const word of target.expr.matchAll(/\b(?:pg_|kong_|node_|container_|warehouse_)[A-Za-z0-9_:]*|\b(?:up|ALERTS)\b(?=\{|$)/g)) names.add(word[0]);
    }
  }
  assert.deepEqual([...names].filter(name => !allowed.has(name)), [], 'a query names a series nothing exports');
  // What the review asked for: database, gateway, disk, container memory and backups.
  for (const series of ['pg_up', 'pg_stat_activity_count', 'pg_stat_activity_max_tx_duration', 'kong_http_requests_total', 'kong_request_latency_ms_bucket',
    'node_filesystem_avail_bytes', 'container_memory_usage_bytes', 'warehouse_backup_last_success_timestamp_seconds']) assert.ok(names.has(series), `${series} is on the dashboard`);
  // No installation is hard-coded: one dashboard serves every installation's own Grafana.
  assert.doesNotMatch(dashboard.panels.flatMap(panel => panel.targets.map(target => target.expr)).join('\n'), /warehouse-[0-9a-f-]{12}|installation|instance=|project=/);
  const provider = read('docker/volumes/grafana/provisioning/dashboards/dashboards.yml');
  assert.match(provider, /allowUiUpdates: false/);
  assert.match(provider, /path: \/etc\/grafana\/dashboards\n/);
  assert.match(read('docker/docker-compose.override.yml'), /- \.\/volumes\/grafana\/dashboards:\/etc\/grafana\/dashboards:ro\n/);
});

test('the monitoring and Grafana checks assert what this change added', () => {
  const monitoring = read('scripts/monitoring-check.sh');
  assert.match(monitoring, /status\/config/);
  assert.match(monitoring, /'installation: '\+process\.argv\[2\]/);
  assert.match(monitoring, /name!=\\"\\",container_label_com_docker_compose_project!=\\"\$project\\"/, 'no other project\'s containers and no container Compose did not start');
  assert.match(monitoring, /warehouse_monitoring_check\.prom/, 'a probe file in the backup metrics directory');
  assert.doesNotMatch(monitoring, /warehouse_backup\.prom/, 'the check never writes a backup metric of its own');
  assert.match(monitoring, /grep -c '\^ \*- alert: ' "\$ROOT\/docker\/alert-rules\.yml"/);
  const grafana = read('scripts/grafana-check.sh');
  assert.match(grafana, /dst=\/etc\/grafana\/dashboards,readonly/);
  assert.match(grafana, /api\/search\?type=dash-db/);
  assert.match(grafana, /api\/ds\/query/);
  assert.match(grafana, /Cannot read directory/);
  assert.match(grafana, /meta\.provisioned !== true/);
});

test('the CLI renders the files of a state that restore-host built, keeping no webhook', () => {
  const f = fixture();
  try {
    configure(f.root, f.options);
    const project = f.project();
    // What restore-host leaves: no monitoring files, no metrics directory, no Alertmanager state.
    rmSync(join(f.stateDir, 'config/monitoring'), { recursive: true });
    rmSync(f.files.metrics, { recursive: true });
    rmSync(join(f.stateDir, 'data/alertmanager'), { recursive: true });
    const run = spawnSync(process.execPath, [new URL('../scripts/monitoring-config.mjs', import.meta.url).pathname, f.stateDir, project], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(readFileSync(f.files.prometheus, 'utf8'), renderPrometheusConfig(template, project));
    assert.equal(statSync(f.files.metrics).mode & 0o777, 0o755);
    assert.equal(statSync(join(f.stateDir, 'data/alertmanager')).mode & 0o777, 0o700);
    assert.equal(existsSync(f.files.webhook), false);
    const bad = spawnSync(process.execPath, [new URL('../scripts/monitoring-config.mjs', import.meta.url).pathname, f.stateDir, 'identity-dev'], { encoding: 'utf8' });
    assert.notEqual(bad.status, 0);
  } finally { f.cleanup(); }
});
