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
let releaseFirst;

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
  // The first job is held until the test releases it: no timing decides whether the second one is still queued.
  behavior: { render: () => new Promise((resolve) => { releaseFirst = () => resolve(ok()); }) },
}, async (s) => {
  const first = render(s, { html: '<p>first</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'first started');
  const ac = new AbortController();
  const second = render(s, { html: '<p>second</p>' }, { signal: ac.signal }).catch((e) => e);
  await waitFor(() => s.supervisor.queue.length === 1, 1000, 'second queued');
  ac.abort();
  await second;
  await waitFor(() => s.supervisor.queue.length === 0, 1000, 'dropped from the queue');
  releaseFirst();
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

test('a browser crash gives 503 to running jobs; queued jobs wait for the relaunched browser', () => withService({
  config: { concurrency: 1 },
  behavior: { render: (job) => (job.html.includes('hang') ? new Promise(() => {}) : Promise.resolve(ok())) },
}, async (s) => {
  const running = render(s, { html: '<p>hang</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'started');
  const queued = render(s, { html: '<p>queued</p>' });
  await waitFor(() => s.supervisor.queue.length === 1, 1000, 'queued');
  s.behavior.engines[0].crash('disconnected');
  assert.equal((await running).status, 503);
  const second = await queued;
  assert.equal(second.status, 200, 'the queued job ran on the new browser');
  assert.equal(s.behavior.launches, 2);
  assert.equal(s.behavior.engines[1].rendered.length, 1);
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

test('repeated crashes back off but never exit the process', async () => {
  const s = await startService({ config: { launchBackoffMs: [20, 40, 80, 160] } });
  try {
    for (let i = 0; i < 6; i += 1) {
      await waitFor(() => s.supervisor.state === 'up' && s.behavior.engines.length === i + 1, 3000, `engine ${i + 1} up`);
      s.behavior.engines[i].crash();
    }
    await waitFor(() => s.supervisor.state === 'up' && s.behavior.engines.length === 7, 3000, 'engine 7 up');
    assert.deepEqual(s.exits, [], 'crashes alone never exit');
    const delays = s.events().filter((e) => e.event === 'launch_backoff').map((e) => e.delayMs);
    assert.deepEqual(delays, [20, 40, 80, 160, 160], 'the first crash relaunches at once, repeats back off');
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
    config: { restartMemoryBytes: 650 * 1024 * 1024, killMemoryBytes: 1100 * 1024 * 1024 },
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

test('drain is capped at deadline + extra: a stuck job is failed and the browser replaced', async () => {
  const s = await startService({
    config: { restartAfterJobs: 1, deadlineMs: 10000, drainExtraMs: 0 },
    behavior: { ignoreAbort: true, render: (job) => (job.html.includes('stuck') ? new Promise(() => {}) : Promise.resolve(ok())) },
  });
  try {
    const stuck = render(s, { html: '<p>stuck</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'stuck started');
    // The job's own deadline (10 s) is far away; only the drain cap can end the wait. Shrink the cap after the job started.
    s.supervisor.config.deadlineMs = 150;
    s.supervisor.jobsSinceLaunch = 0;
    assert.equal((await render(s, { html: '<p>fast</p>' })).status, 200); // reaches restartAfterJobs = 1
    const t0 = Date.now();
    const r = await stuck;
    assert.equal(r.status, 503, 'the stuck job was failed by the drain cap, not by its own 10 s deadline');
    assert.ok(Date.now() - t0 < 3000);
    await waitFor(() => s.behavior.launches === 2, 3000, 'relaunch after the drain cap');
    assert.ok(s.behavior.engines[0].killed);
    assert.ok(s.events().some((e) => e.event === 'drain_timeout'));
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
    memory = 1200 * 1024 * 1024;
    const r = await job;
    assert.equal(r.status, 503);
    assert.ok(s.behavior.engines[0].killed);
    assert.ok(s.events().some((e) => e.event === 'watchdog_kill'));
    memory = 100 * 1024 * 1024;
    await waitFor(() => s.behavior.launches === 2 && s.supervisor.health().body.status === 'up', 3000, 'relaunch');
  } finally { await s.stop(); }
});

test('health probe: down (503) from the second failed probe; recovers if the browser answers again, without a relaunch', async () => {
  const s = await startService({ config: { probeKillAfter: 1000 } });
  try {
    assert.equal(s.supervisor.health().body.status, 'up');
    let fail = true;
    s.behavior.probe = async () => { if (fail) throw new Error('no answer'); return 'FakeChrome/1.0'; };
    await waitFor(() => s.supervisor.probeFailures >= 2, 2000, 'two failed probes');
    assert.equal(s.supervisor.health().status, 503);
    assert.equal(s.supervisor.health().body.status, 'down');
    assert.equal(s.behavior.engines[0].killed, false, 'a browser that may come back is not killed yet');
    fail = false;
    await waitFor(() => s.supervisor.health().body.status === 'up', 2000, 'up again');
    assert.equal(s.behavior.launches, 1, 'no relaunch');
  } finally { await s.stop(); }
});

test('health probe: an unresponsive browser is killed after probeKillAfter failures and replaced', async () => {
  const s = await startService({ config: { probeKillAfter: 4 } });
  try {
    s.behavior.probe = async () => { throw new Error('hung'); };
    await waitFor(() => s.behavior.engines[0].killed, 3000, 'killed');
    s.behavior.probe = async () => 'FakeChrome/1.0';
    await waitFor(() => s.behavior.launches === 2 && s.supervisor.health().body.status === 'up', 3000, 'replaced');
  } finally { await s.stop(); }
});

test('a probe that times out counts as failed', async () => {
  const s = await startService({ config: { probeTimeoutMs: 30, probeKillAfter: 2 }, behavior: { probe: () => new Promise(() => {}) } });
  try {
    await waitFor(() => s.behavior.engines[0].killed, 2000, 'killed after two timed-out probes');
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

test('a browser that cannot be started: queued jobs get 503 after restartWaitMs, new requests at once', async () => {
  const s = await startService({
    config: { restartWaitMs: 150, concurrency: 1, launchBackoffMs: [400, 400, 400, 400] },
    behavior: { render: (job) => (job.html.includes('hang') ? new Promise(() => {}) : Promise.resolve(ok())) },
  });
  try {
    const running = render(s, { html: '<p>hang</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'started');
    const queued = render(s, { html: '<p>queued</p>' });
    await waitFor(() => s.supervisor.queue.length === 1, 1000, 'queued');
    s.behavior.failLaunches = Infinity;
    s.behavior.engines[0].crash();
    assert.equal((await running).status, 503);
    assert.equal((await queued).status, 503);
    await waitFor(() => s.supervisor.launchFailures > 0, 2000, 'launch failure');
    assert.equal((await render(s, {})).status, 503);
    assert.equal(s.supervisor.health().status, 503);
  } finally { s.behavior.failLaunches = 0; await s.stop(); }
});

test('queued jobs wait through a healthy planned restart for longer than restartWaitMs', async () => {
  const s = await startService({
    config: { restartWaitMs: 100, restartAfterJobs: 1 },
    behavior: { render: async () => ok() },
  });
  try {
    s.behavior.launchDelayMs = 500;
    await render(s, {}); // triggers the planned restart with a slow launch
    await waitFor(() => s.supervisor.state === 'restarting', 1000, 'restarting');
    const r = await render(s, {});
    assert.equal(r.status, 200, 'waited for the new browser instead of timing out');
    assert.equal(s.behavior.launches, 2);
  } finally { s.behavior.launchDelayMs = 0; await s.stop(); }
});

test('crash during a planned-restart drain: exactly one new browser, nothing orphaned', async () => {
  const s = await startService({
    config: { restartAfterJobs: 1, concurrency: 2 },
    behavior: { render: (job) => (job.html.includes('hang') ? new Promise(() => {}) : Promise.resolve(ok())) },
  });
  try {
    const hung = render(s, { html: '<p>hang</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'hung started');
    assert.equal((await render(s, { html: '<p>fast</p>' })).status, 200); // triggers the planned restart; the hung job blocks the drain
    await waitFor(() => s.supervisor.state === 'restarting', 1000, 'draining');
    s.behavior.engines[0].crash('disconnected');
    assert.equal((await hung).status, 503);
    await waitFor(() => s.supervisor.state === 'up' && s.behavior.launches === 2, 3000, 'one replacement');
    await sleep(200);
    assert.equal(s.behavior.launches, 2, 'no second launch');
    assert.equal(s.behavior.engines.filter((e) => !e.killed && !e.closed).length, 1, 'only the new browser is alive');
    assert.deepEqual(await s.listDir('profiles'), [path.basename(s.behavior.engines[1].profileDir)]);
  } finally { await s.stop(); }
});

test('memory watchdog during a planned-restart drain: exactly one new browser, nothing orphaned', async () => {
  let memory = 100 * 1024 * 1024;
  const s = await startService({
    config: { restartAfterJobs: 1, concurrency: 2 },
    memoryReader: async () => memory,
    behavior: { render: (job) => (job.html.includes('hang') ? new Promise(() => {}) : Promise.resolve(ok())) },
  });
  try {
    const hung = render(s, { html: '<p>hang</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'hung started');
    assert.equal((await render(s, { html: '<p>fast</p>' })).status, 200);
    await waitFor(() => s.supervisor.state === 'restarting', 1000, 'draining');
    memory = 1200 * 1024 * 1024;
    assert.equal((await hung).status, 503);
    memory = 100 * 1024 * 1024;
    await waitFor(() => s.supervisor.state === 'up' && s.behavior.launches === 2, 3000, 'one replacement');
    await sleep(200);
    assert.equal(s.behavior.launches, 2);
    assert.equal(s.behavior.engines.filter((e) => !e.killed && !e.closed).length, 1);
    assert.deepEqual(await s.listDir('profiles'), [path.basename(s.behavior.engines[1].profileDir)]);
  } finally { await s.stop(); }
});

test('a stuck page during a drain does not start a second transition either', async () => {
  const s = await startService({
    config: { restartAfterJobs: 1, deadlineMs: 300, killGraceMs: 50, concurrency: 2 },
    behavior: { ignoreAbort: true, render: (job) => (job.html.includes('hang') ? new Promise(() => {}) : Promise.resolve(ok())) },
  });
  try {
    const hung = render(s, { html: '<p>hang</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'hung started');
    await render(s, { html: '<p>fast</p>' });
    assert.equal((await hung).status, 504);
    await waitFor(() => s.supervisor.state === 'up' && s.behavior.launches === 2, 3000, 'one replacement');
    await sleep(200);
    assert.equal(s.behavior.launches, 2);
    assert.equal(s.behavior.engines.filter((e) => !e.killed && !e.closed).length, 1);
  } finally { await s.stop(); }
});

test('jobs that end by deadline or client disconnect count toward restartAfterJobs', async () => {
  const s = await startService({
    config: { restartAfterJobs: 2, deadlineMs: 120, concurrency: 1 },
    behavior: { render: (job, engine, signal) => new Promise((_, reject) => signal.addEventListener('abort', () => reject(new Error('closed')))) },
  });
  try {
    assert.equal((await render(s, {})).status, 504);
    await waitFor(() => s.supervisor.running.size === 0, 1000, 'slot freed');
    assert.equal((await render(s, {})).status, 504);
    await waitFor(() => s.behavior.launches === 2, 3000, 'restart after two timed-out jobs');
  } finally { await s.stop(); }
});

test('the client is answered before the page is cleaned up; the slot is freed after the cleanup', async () => {
  let cleanedAt = 0;
  const s = await startService({
    config: { concurrency: 1 },
    behavior: { render: async () => ({ pdf: fakePdf(1), pages: 1, cleanup: async () => { await sleep(300); cleanedAt = Date.now(); } }) },
  });
  try {
    const t0 = Date.now();
    const first = await render(s, { html: '<p>1</p>' });
    const answeredAt = Date.now();
    assert.equal(first.status, 200);
    assert.ok(answeredAt - t0 < 250, `answered after ${answeredAt - t0} ms, before the 300 ms cleanup`);
    assert.equal(cleanedAt, 0, 'cleanup was still running when the client was answered');
    const second = await render(s, { html: '<p>2</p>' });
    assert.equal(second.status, 200);
    assert.ok(s.behavior.started[1], 'second job ran');
    assert.ok(cleanedAt > 0, 'the first cleanup finished before the second job was served');
    assert.equal(s.behavior.maxActive <= 1, true);
  } finally { await s.stop(); }
});

test('container guard: no new body is read while the container is near its limit and a job runs; never kills the browser', async () => {
  let container = 100 * 1024 * 1024;
  let gate;
  const s = await startService({
    config: { concurrency: 2, containerGuardBytes: 1200 * 1024 * 1024 },
    containerMemory: async () => container,
    behavior: { render: (job) => (job.html.includes('hold') ? new Promise((resolve) => { gate = () => resolve(ok()); }) : Promise.resolve(ok())) },
  });
  try {
    const first = render(s, { html: '<p>hold</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'first running');
    container = 1300 * 1024 * 1024;
    await waitFor(() => s.supervisor.containerBytes >= 1300 * 1024 * 1024, 1000, 'guard reading');
    const second = render(s, { html: '<p>second</p>' });
    await waitFor(() => s.supervisor.queue.length === 1, 1000, 'queued');
    await sleep(150);
    assert.equal(s.behavior.started.length, 1, 'second is held back');
    assert.equal(s.behavior.engines[0].killed, false);
    gate();
    assert.equal((await first).status, 200);
    assert.equal((await second).status, 200, 'with nothing running the guard lets the next job in');
    assert.equal(s.behavior.launches, 1, 'no browser restart for container memory');
  } finally { await s.stop(); }
});

test('solo by memory: no second concurrent job while the browser already holds 500 MB', async () => {
  let chrome = 100 * 1024 * 1024;
  let gate;
  const s = await startService({
    config: { concurrency: 2 },
    memoryReader: async () => chrome,
    behavior: { render: (job) => (job.html.includes('hold') ? new Promise((resolve) => { gate = () => resolve(ok()); }) : Promise.resolve(ok())) },
  });
  try {
    const first = render(s, { html: '<p>hold</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'first running');
    chrome = 600 * 1024 * 1024;
    await waitFor(() => s.supervisor.chromeBytes >= 600 * 1024 * 1024, 1000, 'chrome reading');
    const second = render(s, { html: '<p>second</p>' });
    await waitFor(() => s.supervisor.queue.length === 1, 1000, 'queued');
    await sleep(150);
    assert.equal(s.behavior.started.length, 1);
    chrome = 100 * 1024 * 1024; // watchdog tick refreshes the reading and lets the second job in
    await waitFor(() => s.behavior.started.length === 2, 2000, 'second started once memory dropped');
    gate();
    assert.equal((await first).status, 200);
    assert.equal((await second).status, 200);
  } finally { await s.stop(); }
});

test('a crash during shutdown fails queued jobs at once instead of stranding them', async () => {
  const s = await startService({
    config: { concurrency: 1, shutdownMs: 5000 },
    behavior: { render: () => new Promise(() => {}) },
  });
  const running = render(s, { html: '<p>1</p>' });
  await waitFor(() => s.behavior.started.length === 1, 1000, 'running');
  const queued = render(s, { html: '<p>2</p>' });
  await waitFor(() => s.supervisor.queue.length === 1, 1000, 'queued');
  const stopping = s.supervisor.shutdown();
  const t0 = Date.now();
  s.behavior.engines[0].crash();
  assert.equal((await running).status, 503);
  assert.equal((await queued).status, 503);
  assert.ok(Date.now() - t0 < 2000, 'failed at once, not after the 5 s shutdown limit');
  await stopping;
  s.server.closeAllConnections();
  await new Promise((resolve) => s.server.close(resolve));
  await fs.rm(s.dir, { recursive: true, force: true });
});

test('after a relaunch the old browser memory figure is gone: /health shows 0 and two jobs may run together', async () => {
  // Only the first browser reports memory (700 MB, above the 500 MB second-job limit); the new one reports nothing yet.
  const s = await startService({
    config: { concurrency: 2 },
    memoryReader: async (engine) => (engine.id === 1 ? 700 * 1024 * 1024 : null),
    behavior: { render: (job) => (job.html.includes('hang') ? new Promise(() => {}) : sleep(60).then(ok)) },
  });
  try {
    const running = render(s, { html: '<p>hang</p>' });
    await waitFor(() => s.behavior.started.length === 1, 1000, 'started');
    await waitFor(() => s.supervisor.health().body.chromium.memoryMB === 700, 1000, 'the first browser reading reaches /health');
    s.behavior.engines[0].crash('disconnected');
    assert.equal((await running).status, 503);
    await waitFor(() => s.behavior.launches === 2 && s.supervisor.health().body.status === 'up', 3000, 'new browser up');
    assert.equal(s.supervisor.chromeBytes, 0);
    assert.equal(s.supervisor.health().body.chromium.memoryMB, 0, 'not the old 700');
    const both = await Promise.all([render(s, { html: '<p>a</p>' }), render(s, { html: '<p>b</p>' })]);
    assert.deepEqual(both.map((r) => r.status), [200, 200]);
    assert.equal(s.behavior.maxActive, 2, 'the stale figure did not make the jobs run one at a time');
  } finally { await s.stop(); }
});
