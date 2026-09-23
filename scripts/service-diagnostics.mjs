import { spawnSync } from 'node:child_process';
import { readEnv, root } from './doctor-common.mjs';
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

export function diagnoseService(service, {
  run = (command, args) => spawnSync(command, args, { encoding: 'utf8', timeout: 15000 }),
  env = () => readEnv(root + '/docker/.env'),
  report = message => console.error(message),
} = {}) {
  try {
    if (!['supavisor', 'kong', 'functions', 'rest'].includes(service)) throw new Error();
    // The ownership wrapper must succeed before inspecting any container.
    const profile = service === 'supavisor' ? ['--profile', 'pooler'] : [];
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

if (isMain(import.meta.url)) {
  const services = process.argv.slice(2);
  for (const service of services.length ? services : ['supavisor']) diagnoseService(service);
}
