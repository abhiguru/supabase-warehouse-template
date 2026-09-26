import { performance } from 'node:perf_hooks';
import { readEnv, operatorEnvPath } from './doctor-common.mjs';

const env = readEnv(operatorEnvPath());
const url = `http://127.0.0.1:${env.KONG_HTTP_PORT}/rest/v1/feature_flags?select=id&limit=1`;
const total = Number(process.env.LOAD_REQUESTS || 100);
const concurrency = Number(process.env.LOAD_CONCURRENCY || 10);
const limitMs = Number(process.env.LOAD_P95_LIMIT_MS || 5000);
const durations = [];
let next = 0;
let failures = 0;

async function worker() {
  while (next < total) {
    next += 1;
    const start = performance.now();
    try {
      const response = await fetch(url, { headers: { apikey: env.ANON_KEY }, signal: AbortSignal.timeout(15000) });
      const body = await response.json();
      if (!response.ok || !Array.isArray(body)) failures += 1;
    } catch { failures += 1; }
    durations.push(performance.now() - start);
  }
}
await Promise.all(Array.from({ length: concurrency }, worker));
durations.sort((a, b) => a - b);
const p95 = durations[Math.ceil(durations.length * 0.95) - 1];
if (failures || p95 > limitMs) throw new Error(`Load smoke failed: failures=${failures}, p95=${p95.toFixed(1)}ms, limit=${limitMs}ms`);
console.log(`HTTP load smoke passed: ${total} requests, concurrency ${concurrency}, failures 0, p95 ${p95.toFixed(1)}ms.`);
