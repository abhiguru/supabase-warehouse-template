// What Slack would receive, from the pinned Alertmanager image with the rendered docker/alertmanager.slack.yml and a
// local fake receiver in place of Slack (the webhook file holds the fake's http address). Needs Docker and the image
// already on the host (CI pulls it for npm run test:alert-rules); skipped otherwise. Only the timing is shortened.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { renderSlackConfig } from '../scripts/monitoring-config.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const image = /^FROM (prom\/alertmanager:[^ ]*@sha256:[0-9a-f]{64})$/m.exec(read('docker/alertmanager/Dockerfile'))?.[1];
const present = image && spawnSync('docker', ['image', 'inspect', image], { stdio: 'ignore' }).status === 0;
const PROJECT = 'warehouse-0f1e2d3c4b5a';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function freePort() {
  const server = createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise(resolve => server.close(resolve));
  return port;
}

test('firing, resolved, mixed and heartbeat alerts reach Slack as designed; the synthetic alert does not', { skip: !present && 'the pinned Alertmanager image is not on this host', timeout: 90000 }, async () => {
  const messages = [];
  const slack = createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => { const attachment = JSON.parse(body).attachments[0]; messages.push({ title: attachment.title, text: attachment.text, color: attachment.color, fallback: attachment.fallback, link: attachment.title_link }); res.end('ok'); });
  });
  await new Promise(resolve => slack.listen(0, '127.0.0.1', resolve));
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-delivery-'));
  const name = `warehouse-delivery-test-${process.pid}`;
  try {
    const config = renderSlackConfig(read('docker/alertmanager.slack.yml'), PROJECT, "Fictional Cold Storage")
      .replaceAll('group_wait: 30s', 'group_wait: 1s').replaceAll('group_interval: 5m', 'group_interval: 1s');
    writeFileSync(join(dir, 'alertmanager.yml'), config);
    writeFileSync(join(dir, 'webhook-url'), `http://127.0.0.1:${slack.address().port}/services/T0000000/B0000000/fictional\n`);
    chmodSync(dir, 0o755);
    for (const file of ['alertmanager.yml', 'webhook-url']) chmodSync(join(dir, file), 0o644);
    const port = await freePort();
    const run = spawnSync('docker', ['run', '-d', '--rm', '--name', name, '--label', 'com.docker.compose.project=warehouse-delivery-test', '--network', 'host', '--user', `${process.getuid()}:${process.getgid()}`,
      '-v', `${dir}:/etc/alertmanager:ro`, image, '--config.file=/etc/alertmanager/alertmanager.yml', `--web.listen-address=127.0.0.1:${port}`, '--cluster.listen-address=', '--storage.path=/tmp'], { encoding: 'utf8' });
    assert.equal(run.status, 0, run.stderr);
    let up = false;
    for (let i = 0; i < 40 && !up; i++) { up = await fetch(`http://127.0.0.1:${port}/-/ready`).then(r => r.ok, () => false); if (!up) await sleep(250); }
    assert.ok(up, 'Alertmanager started with the rendered configuration');
    const now = Date.now();
    const at = seconds => new Date(now + seconds * 1000).toISOString();
    const alert = (labels, summary, endsAt) => ({ labels, annotations: { summary, description: `${summary} detail` }, startsAt: at(-1), ...(endsAt ? { endsAt } : {}) });
    const post = alerts => fetch(`http://127.0.0.1:${port}/api/v2/alerts`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(alerts) }).then(r => assert.equal(r.status, 200));
    await post([
      alert({ alertname: 'DiskFull', severity: 'critical' }, 'disk is full', at(3600)),
      alert({ alertname: 'ShortLived', severity: 'warning' }, 'short lived', at(5)),
      alert({ alertname: 'Mixed', severity: 'warning', instance: 'a' }, 'mixed a stays', at(3600)),
      alert({ alertname: 'Mixed', severity: 'warning', instance: 'b' }, 'mixed b goes', at(5)),
      alert({ alertname: 'Watchdog', severity: 'heartbeat' }, 'Monitoring is alive', at(5)),
      alert({ alertname: 'WarehouseSynthetic', severity: 'warning' }, 'local delivery test', at(3600)),
    ]);
    await sleep(15000);
    const of = alertname => messages.filter(message => message.title.includes(alertname));
    // Firing.
    assert.equal(of('DiskFull').length, 1);
    assert.equal(of('DiskFull')[0].title, `[FIRING] DiskFull - Fictional Cold Storage (${PROJECT})`);
    assert.equal(of('DiskFull')[0].text, 'disk is full: disk is full detail\n');
    assert.equal(of('DiskFull')[0].color, 'danger');
    // Resolved: a firing message and then a resolved one.
    assert.deepEqual(of('ShortLived').map(message => message.title.split(' - ')[0]), ['[FIRING] ShortLived', '[RESOLVED] ShortLived']);
    assert.equal(of('ShortLived')[1].color, 'good');
    // Mixed group: the first message lists both as firing; once b has gone, a is firing and b is under Resolved.
    const mixed = of('Mixed');
    assert.ok(mixed.length >= 2, JSON.stringify(mixed));
    const firing = mixed.filter(message => !/Resolved:/.test(message.text)).map(message => message.text).join('');
    assert.match(firing, /mixed a stays/, 'listed as firing');
    assert.match(firing, /mixed b goes/, 'listed as firing while it was');
    const last = mixed.at(-1);
    assert.equal(last.text, 'mixed a stays: mixed a stays detail\nResolved:\nmixed b goes\n');
    // Heartbeat: one "alive" message, and none when the Watchdog resolves (Prometheus gone).
    const heartbeat = messages.filter(message => message.title.startsWith('Monitoring is alive'));
    assert.equal(heartbeat.length, 1, JSON.stringify(heartbeat));
    assert.equal(heartbeat[0].title, `Monitoring is alive - Fictional Cold Storage (${PROJECT})`);
    assert.equal(messages.some(message => /RESOLVED\] Watchdog/.test(message.title)), false);
    // The synthetic alert of npm run test:monitoring goes nowhere.
    assert.equal(of('WarehouseSynthetic').length, 0);
    // Every message: no internal link, and the preview names the facility.
    for (const message of messages) {
      assert.ok(!message.link, 'no title link');
      assert.equal(message.fallback, message.title);
      assert.doesNotMatch(JSON.stringify(message), /:\d{4,5}\/#/);
    }
    // The synthetic alert is still retained by Alertmanager (the monitoring check looks for it there).
    const retained = await fetch(`http://127.0.0.1:${port}/api/v2/alerts`).then(r => r.json());
    assert.ok(retained.some(item => item.labels.alertname === 'WarehouseSynthetic'));
  } finally {
    spawnSync('docker', ['stop', '--timeout', '1', name], { stdio: 'ignore' });
    await new Promise(resolve => slack.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  }
});
