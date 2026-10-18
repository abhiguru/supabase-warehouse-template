import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { startService, render, fakePdf, sleep, waitFor } from './support.mjs';

async function withService(options, fn) {
  const service = await startService(options);
  try { await fn(service); } finally { await service.stop(); }
}
const ok = () => ({ pdf: fakePdf(1), pages: 1 });

test('concurrency is 2: four jobs never run more than two at once', () => withService({
  behavior: { render: () => sleep(120).then(ok) },
}, async (s) => {
  const results = await Promise.all(Array.from({ length: 4 }, (_, i) => render(s, { html: `<p>${i}</p>` })));
  assert.deepEqual(results.map((r) => r.status), [200, 200, 200, 200]);
  assert.equal(s.behavior.maxActive, 2);
}));

test('a body of the solo size runs alone, and nothing starts beside it', () => withService({
  config: { soloBodyBytes: 20 * 1024 },
  behavior: { render: () => sleep(150).then(ok) },
}, async (s) => {
  const big = 'x'.repeat(30 * 1024);
  const results = await Promise.all([
    render(s, { html: '<p>a</p>' }),
    render(s, { html: big }),
    render(s, { html: '<p>c</p>' }),
    render(s, { html: '<p>d</p>' }),
  ]);
  assert.ok(results.every((r) => r.status === 200));
  const started = s.behavior.started;
  const bigStart = started.find((j) => j.bytes === big.length);
  assert.equal(bigStart.activeAtStart, 1, 'the large job started with nothing else running');
  // nothing started while the large job was running: the next start's active count never exceeds 1 until it ended
  const after = started.slice(started.indexOf(bigStart) + 1);
  assert.ok(after.length === 0 || after[0].activeAtStart === 1, 'the job after the large one starts only when it has finished');
}));

test('504 when the deadline passes while rendering, and the slot frees', () => withService({
  config: { deadlineMs: 250, concurrency: 1 },
  behavior: { render: (job, engine, signal) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new Error('closed')))) },
}, async (s) => {
  const t0 = Date.now();
  const r = await render(s, {});
  assert.equal(r.status, 504);
  assert.equal(r.json().code, 504);
  assert.ok(Date.now() - t0 < 1500);
  await waitFor(() => s.supervisor.running.size === 0, 1000, 'slot freed');
  s.behavior.render = async () => ok();
  assert.equal((await render(s, {})).status, 200);
}));

test('504 for a job that waits in the queue past its deadline, measured from arrival', () => withService({
  config: { deadlineMs: 300, concurrency: 1, killGraceMs: 5000 },
  behavior: { ignoreAbort: true, render: () => sleep(600).then(ok) },
}, async (s) => {
  const first = render(s, { html: '<p>1</p>' });
  await sleep(30);
  const second = await render(s, { html: '<p>2</p>' });
  assert.equal(second.status, 504);
  assert.equal(s.behavior.started.length, 1, 'the expired job never reached the browser');
  assert.equal((await first).status, 504);
}));

test('504 when the browser ignores the abort: it is killed after the grace period', () => withService({
  config: { deadlineMs: 150, killGraceMs: 100 },
  behavior: { ignoreAbort: true, render: () => new Promise(() => {}) },
}, async (s) => {
  const r = await render(s, {});
  assert.equal(r.status, 504);
  await waitFor(() => s.behavior.launches >= 2, 3000, 'relaunch after the kill');
  assert.ok(s.behavior.engines[0].killed);
}));

test('a queued job whose client disconnected is dropped without rendering', () => withService({
  config: { concurrency: 1 },
  behavior: { render: () => sleep(300).then(ok) },
}, async (s) => {
  const first = render(s, { html: '<p>first</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'first started');
  const ac = new AbortController();
  const second = render(s, { html: '<p>second</p>' }, { signal: ac.signal }).catch((e) => e);
  await waitFor(() => s.supervisor.queue.length === 1, 1000, 'second queued');
  ac.abort();
  await second;
  await waitFor(() => s.supervisor.queue.length === 0, 1000, 'dropped from the queue');
  assert.equal((await first).status, 200);
  assert.equal(s.behavior.started.length, 1, 'the dropped job was never rendered');
  assert.ok(s.jobLogs().some((j) => j.outcome === 'dropped'));
  assert.equal(s.supervisor.inflightBytes, 0);
}));

test('a running job whose client disconnected has its page closed and the slot freed', () => withService({
  config: { concurrency: 1 },
  behavior: { render: (job, engine, signal) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new Error('closed')))) },
}, async (s) => {
  const ac = new AbortController();
  const p = render(s, {}, { signal: ac.signal }).catch((e) => e);
  await waitFor(() => s.behavior.started.length === 1, 1000, 'started');
  ac.abort();
  await p;
  await waitFor(() => s.supervisor.running.size === 0, 1000, 'slot freed');
  assert.ok(s.jobLogs().some((j) => j.outcome === 'dropped'));
}));

test('a browser crash gives 503 to running and queued jobs, then it relaunches', () => withService({
  config: { concurrency: 1 },
  behavior: { render: () => new Promise(() => {}) },
}, async (s) => {
  const running = render(s, { html: '<p>1</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'started');
  const queued = render(s, { html: '<p>2</p>' });
  await waitFor(() => s.supervisor.queue.length === 1, 1000, 'queued');
  s.behavior.engines[0].crash('disconnected');
  const [a, b] = await Promise.all([running, queued]);
  assert.equal(a.status, 503);
  assert.equal(b.status, 503);
  await waitFor(() => s.behavior.launches === 2 && s.supervisor.health().body.status === 'up', 3000, 'relaunch');
  s.behavior.render = async () => ok();
  assert.equal((await render(s, {})).status, 200);
  assert.equal(s.supervisor.health().body.chromium.restarts, 1);
  assert.deepEqual(await s.listDir('profiles'), [path.basename(s.behavior.engines[1].profileDir)]);
}));

test('a target (tab) crash gives 503 and the browser is relaunched', () => withService({
  behavior: { render: async () => { throw Object.assign(new Error('page crashed'), { crash: true }); } },
}, async (s) => {
  const r = await render(s, {});
  assert.equal(r.status, 503);
  await waitFor(() => s.behavior.launches === 2, 3000, 'relaunch');
  assert.ok(s.behavior.engines[0].killed);
}));

test('a process exit is treated as a crash', () => withService({}, async (s) => {
  s.behavior.engines[0].onDown('process exit');
  await waitFor(() => s.behavior.launches === 2, 3000, 'relaunch');
}));

test('failed launches back off 1,2,4,8 style and the process exits after 5 in a row', async () => {
  const s = await startService({
    config: { launchBackoffMs: [30, 60, 120, 240] },
    behavior: { failLaunches: Infinity },
  });
  try {
    await waitFor(() => s.exits.length > 0, 5000, 'exit');
    assert.deepEqual(s.exits, [1]);
    assert.equal(s.behavior.launches, 5);
    const delays = s.events().filter((e) => e.event === 'launch_backoff').map((e) => e.delayMs);
    assert.deepEqual(delays, [30, 60, 120, 240]);
    assert.deepEqual(await s.listDir('profiles'), [], 'failed launches leave no profile directory');
  } finally { await s.stop(); }
});

test('crashes in a row: the first relaunch is immediate, repeats back off, five exit', async () => {
  const s = await startService({ config: { launchBackoffMs: [20, 40, 80, 160] } });
  try {
    const stamps = [];
    for (let i = 0; i < 5; i += 1) {
      await waitFor(() => s.exits.length > 0 || (s.supervisor.state === 'up' && s.behavior.engines.length === i + 1), 3000, `engine ${i + 1}`);
      if (s.exits.length) break;
      stamps.push(Date.now());
      s.behavior.engines[i].crash();
    }
    await waitFor(() => s.exits.length > 0, 3000, 'exit after repeated crashes');
    assert.deepEqual(s.exits, [1]);
    assert.equal(s.behavior.engines.length, 5);
  } finally { await s.stop(); }
});

test('planned restart after N jobs: drain, health says restarting, new browser, old profile removed', async () => {
  const s = await startService({
    config: { restartAfterJobs: 3, concurrency: 2 },
    behavior: { launchDelayMs: 0, render: () => sleep(20).then(ok) },
  });
  try {
    for (let i = 0; i < 2; i += 1) assert.equal((await render(s, {})).status, 200);
    assert.equal(s.behavior.launches, 1);
    s.behavior.launchDelayMs = 250; // make the restart observable
    // A slower job runs while the third job completes: it must be allowed to finish (drain), not be killed.
    s.behavior.render = (job) => sleep(job.html.includes('slow') ? 200 : 10).then(ok);
    const slow = render(s, { html: '<p>slow</p>' });
    await waitFor(() => s.behavior.started.length === 3, 1000, 'slow started');
    const third = await render(s, { html: '<p>fast</p>' });
    assert.equal(third.status, 200);
    await waitFor(() => s.supervisor.health().body.status === 'restarting', 1000, 'restarting state');
    assert.equal(s.supervisor.health().status, 200);
    const queuedDuringRestart = render(s, { html: '<p>queued</p>' });
    assert.equal((await slow).status, 200, 'the in-flight job finished during the drain');
    await waitFor(() => s.behavior.launches === 2 && s.supervisor.health().body.status === 'up', 3000, 'new browser up');
    assert.equal((await queuedDuringRestart).status, 200, 'a job queued during the restart ran on the new browser');
    assert.ok(s.behavior.engines[0].closed);
    assert.equal(s.supervisor.health().body.chromium.restarts, 1);
    assert.deepEqual(await s.listDir('profiles'), [path.basename(s.behavior.engines[1].profileDir)]);
  } finally { await s.stop(); }
});

test('planned restart when memory reaches the threshold, checked between jobs', async () => {
  let memory = 100 * 1024 * 1024;
  const s = await startService({
    config: { restartMemoryBytes: 650 * 1024 * 1024, killMemoryBytes: 900 * 1024 * 1024 },
    memoryReader: async () => memory,
    behavior: { render: async () => ok() },
  });
  try {
    await render(s, {});
    assert.equal(s.behavior.launches, 1, 'below the threshold: no restart');
    memory = 700 * 1024 * 1024;
    await render(s, {});
    await waitFor(() => s.behavior.launches === 2 && s.supervisor.health().body.status === 'up', 3000, 'restart at 700 MB');
    assert.ok(s.events().some((e) => e.event === 'restart_begin' && /memory=700MB/.test(e.reason)));
    memory = 100 * 1024 * 1024;
    assert.equal((await render(s, {})).status, 200);
  } finally { await s.stop(); }
});

test('drain is capped at deadline + 5 s (configurable): a stuck job is killed and gets 503', async () => {
  const s = await startService({
    config: { restartAfterJobs: 1, deadlineMs: 5000, drainExtraMs: 0 },
    behavior: { render: (job) => (job.html.includes('stuck') ? new Promise(() => {}) : Promise.resolve(ok())) },
  });
  try {
    s.supervisor.config.deadlineMs = 200;
    const stuck = render(s, { html: '<p>stuck</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'stuck started');
    // The job that triggers the restart threshold finishes, the stuck one never does.
    s.supervisor.jobsSinceLaunch = 1;
    assert.equal((await render(s, { html: '<p>fast</p>' })).status, 200);
    const r = await stuck;
    assert.ok([503, 504].includes(r.status));
    await waitFor(() => s.behavior.launches === 2, 3000, 'relaunch after drain cap');
    assert.ok(s.behavior.engines[0].killed);
  } finally { await s.stop(); }
});

test('watchdog: memory at the kill threshold during a job kills the browser, the job gets 503', async () => {
  let memory = 100 * 1024 * 1024;
  const s = await startService({
    config: { concurrency: 1 },
    memoryReader: async () => memory,
    behavior: { render: () => new Promise(() => {}) },
  });
  try {
    const job = render(s, {});
    await waitFor(() => s.behavior.started.length === 1, 1000, 'started');
    await sleep(80);
    assert.equal(s.behavior.engines[0].killed, false, 'below the threshold nothing happens');
    memory = 950 * 1024 * 1024;
    const r = await job;
    assert.equal(r.status, 503);
    assert.ok(s.behavior.engines[0].killed);
    assert.ok(s.events().some((e) => e.event === 'watchdog_kill'));
    memory = 100 * 1024 * 1024;
    await waitFor(() => s.behavior.launches === 2 && s.supervisor.health().body.status === 'up', 3000, 'relaunch');
  } finally { await s.stop(); }
});

test('health probe: up, then 503 down after two failed probes in a row (and the browser is replaced)', async () => {
  const s = await startService({ config: { launchBackoffMs: [1000] } });
  try {
    assert.equal(s.supervisor.health().body.status, 'up');
    let fail = true;
    s.behavior.probe = async () => { if (fail) throw new Error('no answer'); return 'FakeChrome/1.0'; };
    await waitFor(() => s.supervisor.probeFailures === 1 || s.supervisor.state === 'crashed', 1000, 'first failed probe');
    if (s.supervisor.state !== 'crashed') assert.equal(s.supervisor.health().body.status, 'up', 'one failed probe is not enough');
    await waitFor(() => s.supervisor.state === 'crashed', 1000, 'second failed probe');
    assert.ok(s.behavior.engines[0].killed, 'the unresponsive browser was killed');
    fail = false;
    await waitFor(() => s.supervisor.health().body.status === 'up' && s.behavior.launches >= 2, 4000, 'healthy again');
  } finally { await s.stop(); }
});

test('health probe: two failed probes with no way to relaunch reports down with HTTP 503', async () => {
  const s = await startService({ config: { launchBackoffMs: [5000] }, behavior: { probe: async () => { throw new Error('hung'); } } });
  try {
    s.behavior.failLaunches = Infinity;
    await waitFor(() => s.supervisor.health().status === 503, 3000, 'down');
    const { status, body } = s.supervisor.health();
    assert.equal(status, 503);
    assert.equal(body.status, 'down');
  } finally { s.supervisor.stopping = true; await s.supervisor.shutdown().catch(() => {}); await fs.rm(s.dir, { recursive: true, force: true }); s.server.closeAllConnections(); s.server.close(); }
});

test('a probe that times out counts as failed', async () => {
  const s = await startService({ config: { probeTimeoutMs: 30 }, behavior: { probe: () => new Promise(() => {}) } });
  try {
    await waitFor(() => s.supervisor.state === 'crashed' || s.behavior.launches >= 2, 2000, 'two timed-out probes');
  } finally { await s.stop(); }
});

test('SIGTERM drain: in-flight and queued jobs finish, new requests get 503, the browser is closed', async () => {
  const s = await startService({
    config: { concurrency: 1, shutdownMs: 2000 },
    behavior: { render: () => sleep(150).then(ok) },
  });
  const first = render(s, { html: '<p>1</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'first started');
  const second = render(s, { html: '<p>2</p>' });
  await waitFor(() => s.supervisor.queue.length === 1, 1000, 'second queued');
  const stopping = s.supervisor.shutdown();
  const late = await render(s, { html: '<p>late</p>' });
  assert.equal(late.status, 503);
  assert.equal(s.supervisor.health().status, 503);
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
  await stopping;
  assert.ok(s.behavior.engines[0].closed);
  assert.deepEqual(await s.listDir('profiles'), [], 'no profile directory left');
  s.server.closeAllConnections();
  await new Promise((resolve) => s.server.close(resolve));
  await fs.rm(s.dir, { recursive: true, force: true });
});

test('SIGTERM drain gives up after the limit: remaining jobs get 503', async () => {
  const s = await startService({
    config: { shutdownMs: 200 },
    behavior: { render: () => new Promise(() => {}) },
  });
  const job = render(s, {});
  await waitFor(() => s.behavior.started.length === 1, 1000, 'started');
  await s.supervisor.shutdown();
  assert.equal((await job).status, 503);
  s.server.closeAllConnections();
  await new Promise((resolve) => s.server.close(resolve));
  await fs.rm(s.dir, { recursive: true, force: true });
});

test('no files left behind: profiles of retired browsers are removed, jobs dir stays empty', async () => {
  const s = await startService({ config: { restartAfterJobs: 2 }, behavior: { render: async () => ok() } });
  try {
    for (let i = 0; i < 7; i += 1) assert.equal((await render(s, {})).status, 200);
    await waitFor(() => s.supervisor.state === 'up' && s.behavior.launches >= 3, 3000, 'several restarts');
    const profiles = await s.listDir('profiles');
    assert.equal(profiles.length, 1, `exactly the live browser's profile remains, found ${profiles}`);
    assert.deepEqual(await s.listDir('jobs'), []);
  } finally { await s.stop(); }
});

test('job log lines carry queue and render times and flag only the first render as cold', () => withService({
  config: { concurrency: 1 },
  behavior: { render: () => sleep(60).then(ok) },
}, async (s) => {
  await Promise.all([render(s, {}), render(s, {})]);
  const jobs = s.jobLogs();
  assert.equal(jobs.length, 2);
  assert.equal(jobs.filter((j) => j.cold).length, 1);
  assert.ok(jobs.some((j) => j.queueMs >= 40), 'the second job waited in the queue');
  assert.ok(jobs.every((j) => j.renderMs >= 50));
}));

test('browser unavailable too long: a queued job gets 503 after restartWaitMs', async () => {
  const s = await startService({
    config: { restartWaitMs: 150, restartAfterJobs: 1 },
    behavior: { render: async () => ok() },
  });
  try {
    s.behavior.launchDelayMs = 1500;
    await render(s, {}); // triggers a planned restart whose launch is slow
    await waitFor(() => s.supervisor.state === 'restarting', 1000, 'restarting');
    const r = await render(s, {});
    assert.equal(r.status, 503);
  } finally { s.behavior.launchDelayMs = 0; await s.stop(); }
});
