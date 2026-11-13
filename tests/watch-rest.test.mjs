// WH-18: the checker probes REST through the gateway (checkApiRest, alert rest_down), and a planned stop leaves rest_down out of the
// support report. Fakes only: no Docker, no network, no clock.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as W from '../scripts/watch.mjs';
import { buildReport, PLANNED_STOP_KINDS, ATTENTION_KINDS } from '../scripts/support-link.mjs';

const ANON = 'eyJhbGciOiJIUzI1NiJ9.anon-key-must-not-leak.signature';
const URL_REST = 'http://127.0.0.1:18000/rest/v1/rpc/get_public_config';

// A context with a recording fetch: `answer` is a status number, or a function that throws.
function ctxWith(answer, env = { GATEWAY_HTTP_PORT: '18000', ANON_KEY: ANON }) {
  const seen = [];
  return {
    seen,
    env_: () => env,
    fetch: async (url, options) => {
      seen.push({ url, options });
      if (typeof answer === 'function') return answer(url, options);
      return { ok: answer < 400, status: answer, json: async () => ({}) };
    },
  };
}

test('checkApiRest: any 2xx or 4xx means REST answered (clears)', async () => {
  for (const status of [200, 204, 400, 401, 404, 429]) {
    const [r] = await W.checkApiRest(ctxWith(status));
    assert.deepEqual([r.check, r.id, r.ok], ['api_rest', 'rest_down', true], `HTTP ${status}`);
  }
});

test('checkApiRest: every 5xx raises', async () => {
  for (const status of [500, 502, 503, 504]) {
    const [r] = await W.checkApiRest(ctxWith(status));
    assert.deepEqual([r.id, r.ok], ['rest_down', false], `HTTP ${status}`);
    assert.match(r.summary, /REST is not answering/);
  }
});

test('checkApiRest: a refused connection and a timeout raise', async () => {
  const refused = Object.assign(new TypeError('fetch failed'), { cause: Object.assign(new Error('connect ECONNREFUSED 127.0.0.1:18000'), { code: 'ECONNREFUSED' }) });
  const [a] = await W.checkApiRest(ctxWith(() => { throw refused; }));
  assert.equal(a.ok, false);
  assert.match(a.detail, /ECONNREFUSED/);
  const timeout = new DOMException('The operation was aborted due to timeout', 'TimeoutError');
  const [b] = await W.checkApiRest(ctxWith(() => { throw timeout; }));
  assert.equal(b.ok, false);
  assert.match(b.detail, /timeout/i);
});

test('checkApiRest: the request is an anonymous POST of get_public_config, with a time limit and no redirects', async () => {
  const ctx = ctxWith(200);
  await W.checkApiRest(ctx);
  assert.equal(ctx.seen.length, 1);
  const { url, options } = ctx.seen[0];
  assert.equal(url, URL_REST);
  assert.equal(options.method, 'POST');
  assert.equal(options.headers.apikey, ANON);
  assert.equal(options.redirect, 'error');
  assert.ok(options.signal instanceof AbortSignal, 'a timeout signal is passed');
  // Anonymous: the anon key only, never an Authorization header or the service key.
  assert.ok(!Object.keys(options.headers).some(k => k.toLowerCase() === 'authorization'));
});

test('checkApiRest: a missing gateway port is a check error, not a silent pass', async () => {
  await assert.rejects(() => W.checkApiRest(ctxWith(200, { ANON_KEY: ANON })), /GATEWAY_HTTP_PORT/);
});

test('checkApiRest: no secret is in the alert text (summary or detail), failing or not', async () => {
  const leaky = Object.assign(new Error(`request to ${URL_REST} with apikey ${ANON} failed`), { cause: { code: 'ECONNRESET' } });
  for (const answer of [503, () => { throw leaky; }, 200]) {
    for (const r of await W.checkApiRest(ctxWith(answer))) {
      for (const field of [r.summary, r.detail]) {
        assert.ok(!String(field).includes(ANON), 'the anon key is not in the text');
        assert.ok(!String(field).includes('apikey'), 'no header name or value');
      }
    }
  }
});

test('rest_down is raised after two failing runs, not one, and cleared by a passing run', async () => {
  const data = W.freshState(Date.now());
  const run = async answer => {
    const results = await W.checkApiRest(ctxWith(answer));
    return W.evaluate(data, results, new Set(['api_rest']), Date.now());
  };
  let out = await run(503);
  assert.equal(out.start.length, 0, 'one failing run is not an alert');
  out = await run(503);
  assert.deepEqual(out.start.map(a => a.id), ['rest_down']);
  data.alerts.rest_down.lastSent = Date.now();
  out = await run(200);
  assert.deepEqual(out.clear.map(a => a.id), ['rest_down']);
});

test('a passing run between two failing runs resets the count', async () => {
  const data = W.freshState(Date.now());
  const run = async answer => W.evaluate(data, await W.checkApiRest(ctxWith(answer)), new Set(['api_rest']), Date.now());
  await run(500);
  await run(200);
  const out = await run(500);
  assert.equal(out.start.length, 0);
});

test('the check is in the checker\'s list, after api_local', () => {
  const names = W.CHECKS.map(([name]) => name);
  assert.ok(W.CHECKS.some(([name, fn]) => name === 'api_rest' && fn === W.checkApiRest));
  assert.equal(names.indexOf('api_rest'), names.indexOf('api_local') + 1);
});

test('support report: rest_down is a planned-stop kind, so a planned stop does not list or count it', () => {
  assert.ok(PLANNED_STOP_KINDS.has('rest_down'));
  const base = { now: Date.UTC(2026, 10, 13), alerts: [{ id: 'rest_down', since: 1000 }, { id: 'api_down', since: 2000 }] };
  const planned = buildReport({ ...base, planned: { kind: 'upgrade' } });
  const text = JSON.stringify(planned);
  assert.ok(!text.includes('rest_down'), 'left out during a planned stop');
  const live = buildReport(base);
  assert.ok(JSON.stringify(live).includes('rest_down'), 'listed when no stop is planned');
});

test('rest_down is not an attention kind (Product has not asked for it)', () => {
  assert.ok(!ATTENTION_KINDS.has('rest_down'));
});
