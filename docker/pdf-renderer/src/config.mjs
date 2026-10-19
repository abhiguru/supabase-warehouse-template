// Environment-driven settings. Every value has a safe default; tests pass overrides.

const MB = 1024 * 1024;

function int(env, name, def) {
  const raw = env[name];
  if (raw === undefined || raw === '') return def;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative number, got ${JSON.stringify(raw)}`);
  return n;
}

function oneOf(env, name, allowed, def) {
  const raw = env[name];
  if (raw === undefined || raw === '') return def;
  if (!allowed.includes(raw)) throw new Error(`${name} must be one of ${allowed.join('|')}, got ${JSON.stringify(raw)}`);
  return raw;
}

export function loadConfig(env = process.env, overrides = {}) {
  const config = {
    port: int(env, 'PORT', 3000),
    host: env.HOST || '0.0.0.0',
    executablePath: env.CHS_PATH || '/opt/chs/chrome-headless-shell',
    profilesDir: env.PROFILES_DIR || '/tmp/profiles',
    jobsDir: env.JOBS_DIR || '/tmp/jobs',

    // Request limits.
    maxBodyBytes: int(env, 'MAX_BODY_MB', 48) * MB,
    maxQueueBytes: int(env, 'MAX_QUEUE_MB', 100) * MB,
    maxQueue: int(env, 'MAX_QUEUE', 10),
    concurrency: int(env, 'CONCURRENCY', 2),
    soloBodyBytes: int(env, 'SOLO_BODY_MB', 8) * MB,
    deadlineMs: int(env, 'DEADLINE_MS', 25000),
    // How long a queued job may wait while no browser is available before it gets 503.
    restartWaitMs: int(env, 'RESTART_WAIT_MS', 15000),
    // After a deadline, how long the page may take to close before the browser is killed.
    killGraceMs: int(env, 'KILL_GRACE_MS', 3000),

    // Supervisor.
    restartAfterJobs: int(env, 'RESTART_AFTER_JOBS', 100),
    restartMemoryBytes: int(env, 'RESTART_MEMORY_MB', 650) * MB,
    killMemoryBytes: int(env, 'KILL_MEMORY_MB', 1100) * MB,
    // The container's cgroup figure only delays reading new bodies while jobs run; it never kills the browser.
    // A second job does not start while the browser's own memory is at or above this (large bitmaps, shared memory).
    secondJobChromeBytes: int(env, 'SECOND_JOB_CHROME_MB', 500) * MB,
    containerGuardBytes: int(env, 'CONTAINER_GUARD_MB', 1200) * MB,
    watchdogIntervalMs: int(env, 'WATCHDOG_INTERVAL_MS', 1000),
    probeIntervalMs: int(env, 'PROBE_INTERVAL_MS', 2000),
    probeTimeoutMs: int(env, 'PROBE_TIMEOUT_MS', 5000),
    // Failed probes in a row before the unresponsive browser is killed (health says down from the second).
    probeKillAfter: int(env, 'PROBE_KILL_AFTER', 5),
    drainExtraMs: int(env, 'DRAIN_EXTRA_MS', 5000),
    launchBackoffMs: (env.LAUNCH_BACKOFF_MS || '1000,2000,4000,8000').split(',').map(Number),
    maxLaunchFailures: int(env, 'MAX_LAUNCH_FAILURES', 5),
    shutdownMs: int(env, 'SHUTDOWN_MS', 20000),
    closeTimeoutMs: int(env, 'CLOSE_TIMEOUT_MS', 5000),

    // Per-job behaviour. Each switch exists so one variable can be changed at a time.
    context: oneOf(env, 'RENDERER_CONTEXT', ['shared', 'perjob'], 'perjob'),
    js: oneOf(env, 'RENDERER_JS', ['on', 'off'], 'off'),
    // intercept: the document is served from memory; file: written to /tmp/jobs/<id>; auto: file for bodies of
    // soloBodyBytes or more (no base64 copy through the DevTools pipe), intercept for the rest.
    load: oneOf(env, 'RENDERER_LOAD', ['intercept', 'file', 'auto'], 'auto'),
    // Content-Security-Policy header on the in-memory document (blocks data: frames and objects). Only sent with scripts
    // off (the policy would also stop inline scripts) and not possible in file mode.
    csp: oneOf(env, 'RENDERER_CSP', ['on', 'off'], 'on'),
    fontsReady: oneOf(env, 'RENDERER_FONTS_READY', ['on', 'off'], 'on'),
    fontsReadyCapMs: int(env, 'FONTS_READY_CAP_MS', 2000),

    // Server.
    keepAliveTimeoutMs: 65000,
    headersTimeoutMs: 66000,
  };
  const result = { ...config, ...overrides };
  validateConfig(result);
  return result;
}

export function validateConfig(c) {
  const problems = [];
  const need = (ok, text) => { if (!ok) problems.push(text); };
  need(Number.isInteger(c.port) && c.port >= 0 && c.port <= 65535, 'PORT must be 0-65535');
  need(Number.isInteger(c.concurrency) && c.concurrency >= 1, 'CONCURRENCY must be at least 1');
  need(Number.isInteger(c.maxQueue) && c.maxQueue >= 1, 'MAX_QUEUE must be at least 1');
  need(c.maxBodyBytes > 0, 'MAX_BODY_MB must be positive');
  need(c.maxQueueBytes >= c.maxBodyBytes, 'MAX_QUEUE_MB must be at least MAX_BODY_MB');
  need(c.soloBodyBytes > 0, 'SOLO_BODY_MB must be positive');
  need(c.deadlineMs > 0, 'DEADLINE_MS must be positive');
  need(c.restartAfterJobs >= 1, 'RESTART_AFTER_JOBS must be at least 1');
  need(c.restartMemoryBytes > 0 && c.killMemoryBytes > c.restartMemoryBytes, 'KILL_MEMORY_MB must be above RESTART_MEMORY_MB');
  need(c.probeIntervalMs > 0 && c.probeTimeoutMs > 0 && c.watchdogIntervalMs > 0, 'probe and watchdog intervals must be positive');
  need(c.probeKillAfter >= 2, 'PROBE_KILL_AFTER must be at least 2');
  need(Array.isArray(c.launchBackoffMs) && c.launchBackoffMs.length > 0 && c.launchBackoffMs.every((n) => Number.isFinite(n) && n >= 0), 'LAUNCH_BACKOFF_MS must be a comma list of numbers');
  need(Number.isInteger(c.maxLaunchFailures) && c.maxLaunchFailures >= 1, 'MAX_LAUNCH_FAILURES must be at least 1');
  need(c.shutdownMs >= 0 && c.closeTimeoutMs > 0 && c.killGraceMs >= 0 && c.restartWaitMs >= 0, 'timeouts must be non-negative');
  if (problems.length) throw new Error(`invalid configuration: ${problems.join('; ')}`);
}
