import { spawnSync } from 'node:child_process';
import { chmodSync, lstatSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { readEnv, root, operatorEnvPath } from './doctor-common.mjs';
import { isMain } from './is-main.mjs';

export function redactServiceLog(text, env) {
  for (const [key, value] of Object.entries(env)) {
    if (!value || !/(PASSWORD|SECRET|TOKEN|KEY|PASS)/.test(key)) continue;
    for (const encoded of [value, encodeURIComponent(value), JSON.stringify(value).slice(1, -1)]) {
      text = text.split(encoded).join('[REDACTED]');
    }
  }
  return text
    .replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[REDACTED JWT]')
    .replace(/((?:postgres(?:ql)?|ecto):\/\/[^:\s/@]+:)[^@\s]+@/g, '$1[REDACTED]@');
}

const SERVICES = ['supavisor', 'gateway', 'gateway-lan', 'functions', 'rest'];
const profileOf = service => (service === 'supavisor' ? ['--profile', 'pooler'] : service === 'gateway-lan' ? ['--profile', 'lan'] : []);

export function diagnoseService(service, {
  run = (command, args) => spawnSync(command, args, { encoding: 'utf8', timeout: 15000 }),
  env = () => readEnv(operatorEnvPath()),
  report = message => console.error(message),
} = {}) {
  try {
    if (!SERVICES.includes(service)) throw new Error();
    // The ownership wrapper must succeed before inspecting any container.
    const profile = profileOf(service);
    const found = run('bash', [root + '/scripts/compose.sh', ...profile, 'ps', '-a', '-q', service]);
    const id = found.stdout?.trim();
    if (found.status !== 0 || !/^[a-f0-9]{12,64}$/.test(id)) throw new Error();
    const inspected = run('docker', ['inspect', '--format', '{{json .State}}', id]);
    if (inspected.status !== 0) throw new Error();
    const state = JSON.parse(inspected.stdout);
    report(JSON.stringify({ service, status: state.Status, exitCode: state.ExitCode,
      oomKilled: state.OOMKilled, health: state.Health?.Status }));
    const logs = run('docker', ['logs', '--tail', '60', id]);
    report(redactServiceLog((logs.stdout || '') + (logs.stderr || ''), env()));
  } catch {
    report('Service diagnostics unavailable; no configuration was printed.');
  }
}

// Why a start failed: every service that is not running and healthy, with its
// last 30 log lines, redacted. `up --wait` itself only names the container.
// Never fails: it is a hint printed while the caller reports its own failure.
export function showUnhealthyServices({
  run = (command, args) => spawnSync(command, args, { encoding: 'utf8', timeout: 30000 }),
  env = () => readEnv(operatorEnvPath()),
  report = message => console.error(message),
} = {}) {
  try {
    const listed = run('bash', [root + '/scripts/compose.sh', 'ps', '--all', '--format', '{{.Service}} {{.State}} {{.Health}}']);
    if (listed.status !== 0) return;
    const secrets = env();
    for (const line of (listed.stdout || '').split('\n')) {
      const [service, state, health] = line.trim().split(/\s+/);
      if (!service) continue;
      if (state === 'running' && (!health || health === 'healthy')) continue;
      report(`Service ${service} is ${state}${health ? ` (${health})` : ''}. Its last log lines:`);
      const logs = run('bash', [root + '/scripts/compose.sh', 'logs', '--no-color', '--tail', '30', service]);
      report(redactServiceLog((logs.stdout || '') + (logs.stderr || ''), secrets));
    }
  } catch {
    report('Service diagnostics unavailable; no configuration was printed.');
  }
}

// A recreated container starts with an empty log, so what explains a failure is gone once an upgrade, a key rotation or a password
// rotation recreates the services. Called by those scripts just before the recreate: the last `since` of each service's log,
// through redactServiceLog, in <state>/diagnostics/pre-<label>-<utc>/<service>.log (directory 0700, files 0600). Only the newest
// `keep` such directories stay. Best effort: it never throws and never fails the caller; a failure prints one line.
const STAMPED = /^pre-[a-z0-9-]+-\d{8}T\d{6}Z$/;
export function saveLogs({
  label, since = '48h', keep = 5,
  stateDir = process.env.WAREHOUSE_STATE_DIR,
  run = (command, args) => spawnSync(command, args, { encoding: 'utf8', timeout: 120000, maxBuffer: 256 * 1024 * 1024 }),
  env = () => readEnv(operatorEnvPath()),
  now = () => new Date(),
  report = message => console.error(message),
} = {}) {
  let made = null;
  try {
    if (typeof label !== 'string' || !/^[a-z0-9-]{1,40}$/.test(label)) throw new Error('label');
    if (!/^\d+[smhd]$/.test(since)) throw new Error('since');
    if (typeof stateDir !== 'string' || !stateDir.startsWith('/')) throw new Error('state');
    const secrets = env();
    const base = join(stateDir, 'diagnostics');
    mkdirSync(base, { recursive: true, mode: 0o700 });
    if (!lstatSync(base).isDirectory()) throw new Error('diagnostics');
    chmodSync(base, 0o700);
    const stamp = now().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
    made = join(base, `pre-${label}-${stamp}`);
    mkdirSync(made, { mode: 0o700 });
    chmodSync(made, 0o700);
    let saved = 0;
    for (const service of SERVICES) {
      const logs = run('bash', [root + '/scripts/compose.sh', ...profileOf(service), 'logs', '--timestamps', '--no-color', '--since', since, service]);
      const text = (logs.stdout || '') + (logs.stderr || '');
      if (logs.status !== 0 || !text.trim()) continue;
      const file = join(made, `${service}.log`);
      writeFileSync(file, redactServiceLog(text, secrets), { mode: 0o600 });
      chmodSync(file, 0o600);
      saved += 1;
    }
    if (saved === 0) throw new Error('nothing');
    const old = readdirSync(base).filter(name => STAMPED.test(name) && lstatSync(join(base, name)).isDirectory())
      .sort((a, b) => a.slice(-16).localeCompare(b.slice(-16)) || a.localeCompare(b));
    for (const name of old.slice(0, Math.max(0, old.length - keep))) rmSync(join(base, name), { recursive: true, force: true });
    report(`Saved the last ${since} of ${saved} service logs, redacted, in ${made}`);
  } catch {
    if (made) { try { rmSync(made, { recursive: true, force: true }); } catch { /* best effort */ } }
    report('Service logs were not saved before the restart (continuing).');
  }
}

if (isMain(import.meta.url)) {
  const services = process.argv.slice(2);
  if (services[0] === '--unhealthy') showUnhealthyServices();
  else if (services[0] === 'save') saveLogs({ label: services[1] });
  else for (const service of services.length ? services : ['supavisor']) diagnoseService(service);
}
