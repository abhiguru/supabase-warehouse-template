// Container health can precede gateway readiness after a container is recreated.
export async function waitForHttp(name, url, headers = {}, {
  fetchImpl = fetch, now = Date.now,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  timeoutMs = 90000, intervalMs = 1000,
} = {}) {
  const deadline = now() + timeoutMs;
  let lastFailure = 'connection unavailable';
  while (now() < deadline) {
    let response;
    try {
      response = await fetchImpl(url, {
        headers, redirect: 'error',
        signal: AbortSignal.timeout(Math.max(1, Math.min(10000, deadline - now()))),
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
