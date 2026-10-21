// Container health can precede gateway readiness after a container is recreated.
export async function waitForHttp(name, url, headers = {}, {
  fetchImpl = fetch, now = Date.now,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  timeoutMs = 90000, intervalMs = 1000, init = {},
} = {}) {
  const deadline = now() + timeoutMs;
  let lastFailure = 'connection unavailable';
  // At least one attempt, even with timeoutMs 0 (health --wait 0). The first attempt always gets a few seconds
  // (a request through the gateway takes longer than 1 ms); later attempts are cut to what is left of the wait.
  const FIRST_ATTEMPT_FLOOR_MS = 5000;
  for (let attempt = 0; attempt === 0 || now() < deadline; attempt += 1) {
    let response;
    try {
      response = await fetchImpl(url, {
        ...init, headers, redirect: 'error',
        signal: AbortSignal.timeout(Math.min(10000, Math.max(attempt === 0 ? FIRST_ATTEMPT_FLOOR_MS : 1, deadline - now()))),
      });
    } catch {
      // Do not print URLs, headers or transport errors that may contain secrets.
      lastFailure = 'connection unavailable';
    }
    if (response) {
      await response.body?.cancel();
      if (response.ok) return;
      lastFailure = `HTTP ${response.status}`;
      if (![502, 503, 504].includes(response.status)) {
        throw new Error(`${name}: ${lastFailure}`);
      }
    }
    const remaining = deadline - now();
    if (remaining > 0) await sleep(Math.min(intervalMs, remaining));
  }
  throw new Error(`${name}: readiness timed out (${lastFailure})`);
}
