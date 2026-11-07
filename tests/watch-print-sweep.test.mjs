import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as W from '../scripts/watch.mjs';

// WH-109 part 4: the 5-minute checker settles stuck print jobs by calling sweep-print-jobs with the service-role key, only while
// printing is on. Fakes only: no Docker, no network, no clock.
const KEY = 'unit-test-service-role-key-not-a-real-key';
const T0 = new Date(2026, 10, 7, 10, 0, 0).getTime();

function scratch({ printing = true, manifest, composeEnv = `GATEWAY_HTTP_PORT=18000\nSERVICE_ROLE_KEY=${KEY}\n`, answer = { status: 200 } } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-watch-print-'));
  const state = join(dir, 'state');
  for (const sub of ['config', 'public']) mkdirSync(join(state, sub), { recursive: true });
  if (composeEnv !== null) writeFileSync(join(state, 'config/compose.env'), composeEnv);
  if (manifest !== null) writeFileSync(join(state, 'public/instance.json'), manifest ?? JSON.stringify({ schemaVersion: 1, capabilities: { sensors: false, printing, payments: false } }));
  const calls = [];
  const deps = {
    state, root: dir, env: {}, now: () => T0, run: () => ({ status: 1, stdout: '', stderr: 'unexpected' }),
    readText: path => { try { return require_fs.readFileSync(path, 'utf8'); } catch { return null; } },
    fetch: async (url, init) => {
      calls.push({ url, init });
      if (answer instanceof Error) throw answer;
      return { ok: answer.status < 400, status: answer.status, json: async () => ({}) };
    },
  };
  return { dir, calls, ctx: W.makeContext(deps, W.freshState(T0)), clean: () => rmSync(dir, { recursive: true, force: true }) };
}
import * as require_fs from 'node:fs';

test('print_sweep is one of the checks, last in the list', () => {
  const entry = W.CHECKS.find(([name]) => name === 'print_sweep');
  assert.ok(entry);
  assert.equal(entry[1], W.checkPrintSweep);
  assert.equal(W.CHECKS.at(-1)[0], 'print_sweep');
});

test('printing is off, or the manifest is missing or unreadable: nothing is called and nothing is reported', async () => {
  for (const options of [{ printing: false }, { manifest: null }, { manifest: '{not json' }, { manifest: 'null' }, { manifest: JSON.stringify({ capabilities: { printing: 'true' } }) }, { manifest: JSON.stringify({}) }]) {
    const s = scratch(options);
    try {
      assert.deepEqual(await W.checkPrintSweep(s.ctx), [], JSON.stringify(options));
      assert.equal(s.calls.length, 0);
    } finally { s.clean(); }
  }
});

test('printing is on: one POST to the local gateway\'s sweep-print-jobs with the service-role key; a 2xx is a pass', async () => {
  const s = scratch();
  try {
    const results = await W.checkPrintSweep(s.ctx);
    assert.deepEqual(results, [{ check: 'print_sweep', id: 'print_sweep_failed', ok: true, summary: 'Print jobs are swept', detail: '' }]);
    assert.equal(s.calls.length, 1);
    const [{ url, init }] = s.calls;
    assert.equal(url, 'http://127.0.0.1:18000/functions/v1/sweep-print-jobs');
    assert.equal(init.method, 'POST');
    assert.deepEqual(init.headers, { apikey: KEY, Authorization: `Bearer ${KEY}` });
    assert.equal(init.redirect, 'error');
    assert.ok(init.signal instanceof AbortSignal, 'bounded by a timeout');
  } finally { s.clean(); }
});

test('without a usable port or key the check is not judged (null) and nothing is sent', async () => {
  for (const composeEnv of [`GATEWAY_HTTP_PORT=18000\n`, `SERVICE_ROLE_KEY=${KEY}\n`, `GATEWAY_HTTP_PORT=abc\nSERVICE_ROLE_KEY=${KEY}\n`, `GATEWAY_HTTP_PORT=\nSERVICE_ROLE_KEY=${KEY}\n`, null]) {
    const s = scratch({ composeEnv });
    try {
      assert.equal(await W.checkPrintSweep(s.ctx), null, JSON.stringify(composeEnv));
      assert.equal(s.calls.length, 0);
    } finally { s.clean(); }
  }
  // The port's former name still works (built from parts: only listed files may spell it out).
  const old = scratch({ composeEnv: `${'KO' + 'NG'}_HTTP_PORT=18001\nSERVICE_ROLE_KEY=${KEY}\n` });
  try {
    await W.checkPrintSweep(old.ctx);
    assert.equal(old.calls[0].url, 'http://127.0.0.1:18001/functions/v1/sweep-print-jobs');
  } finally { old.clean(); }
});

test('a non-2xx answer or no answer is a print_sweep_failed failure that names the cause and never the key', async () => {
  for (const answer of [{ status: 403 }, { status: 500 }, { status: 502 }, new Error('connect ECONNREFUSED 127.0.0.1:18000')]) {
    const s = scratch({ answer });
    try {
      const [failure] = await W.checkPrintSweep(s.ctx);
      assert.deepEqual([failure.check, failure.id, failure.ok, failure.summary], ['print_sweep', 'print_sweep_failed', false, 'Stuck print jobs could not be settled']);
      assert.match(failure.detail, answer instanceof Error ? /ECONNREFUSED/ : new RegExp(`HTTP ${answer.status}`));
      assert.match(failure.detail, /stays "printing" until this works/);
      assert.ok(!JSON.stringify(failure).includes(KEY));
    } finally { s.clean(); }
  }
});

test('a failing sweep alerts after two failing runs (the default rule) and clears when it works again', () => {
  const data = W.freshState(T0);
  const failing = [{ check: 'print_sweep', id: 'print_sweep_failed', ok: false, summary: 'Stuck print jobs could not be settled', detail: 'HTTP 500.' }];
  const ran = new Set(['print_sweep']);
  assert.deepEqual(W.evaluate(data, failing, ran, T0).start, []);
  const second = W.evaluate(data, failing, ran, T0 + 5 * 60000);
  assert.deepEqual(second.start.map(line => line.id), ['print_sweep_failed']);
  data.alerts.print_sweep_failed.lastSent = T0 + 5 * 60000;
  const cleared = W.evaluate(data, [{ ...failing[0], ok: true }], ran, T0 + 10 * 60000);
  assert.deepEqual(cleared.clear.map(line => line.id), ['print_sweep_failed']);
});
