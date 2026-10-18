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
    killMemoryBytes: int(env, 'KILL_MEMORY_MB', 900) * MB,
    watchdogIntervalMs: int(env, 'WATCHDOG_INTERVAL_MS', 1000),
    probeIntervalMs: int(env, 'PROBE_INTERVAL_MS', 2000),
    probeTimeoutMs: int(env, 'PROBE_TIMEOUT_MS', 5000),
    drainExtraMs: int(env, 'DRAIN_EXTRA_MS', 5000),
    launchBackoffMs: (env.LAUNCH_BACKOFF_MS || '1000,2000,4000,8000').split(',').map(Number),
    maxLaunchFailures: int(env, 'MAX_LAUNCH_FAILURES', 5),
    shutdownMs: int(env, 'SHUTDOWN_MS', 20000),
    closeTimeoutMs: int(env, 'CLOSE_TIMEOUT_MS', 5000),

    // Per-job behaviour. Each switch exists so one variable can be changed at a time.
    context: oneOf(env, 'RENDERER_CONTEXT', ['shared', 'perjob'], 'perjob'),
    js: oneOf(env, 'RENDERER_JS', ['on', 'off'], 'off'),
    load: oneOf(env, 'RENDERER_LOAD', ['intercept', 'file'], 'intercept'),
    fontsReady: oneOf(env, 'RENDERER_FONTS_READY', ['on', 'off'], 'on'),
    fontsReadyCapMs: int(env, 'FONTS_READY_CAP_MS', 2000),

    // Server.
    keepAliveTimeoutMs: 65000,
    headersTimeoutMs: 66000,
  };
  return { ...config, ...overrides };
}
