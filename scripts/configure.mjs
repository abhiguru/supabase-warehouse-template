import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { randomBytes, createHmac } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function configure(root) {
  const target = resolve(root, 'docker/.env');
  if (existsSync(target)) return false; // Never read, regenerate, or overwrite existing credentials.
  let template = readFileSync(resolve(root, '.env.example'), 'utf8');
  const secret = randomBytes(48).toString('hex');
  const jwt = (role) => {
    const part = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const body = `${part({ alg: 'HS256', typ: 'JWT' })}.${part({ iss: 'supabase', role, exp: Math.floor(Date.now() / 1000) + 10 * 365 * 86400 })}`;
    return `${body}.${createHmac('sha256', secret).update(body).digest('base64url')}`;
  };
  const values = {
    POSTGRES_PASSWORD: randomBytes(24).toString('hex'),
    JWT_SECRET: secret,
    ANON_KEY: jwt('anon'),
    SERVICE_ROLE_KEY: jwt('service_role'),
    SECRET_KEY_BASE: randomBytes(64).toString('hex'),
    VAULT_ENC_KEY: randomBytes(16).toString('hex'),
  };
  for (const key of ['DASHBOARD_PASSWORD', 'GRAFANA_ADMIN_PASS', 'CUPS_ADMIN_PASSWORD',
    'LOGFLARE_LOGGER_BACKEND_API_KEY', 'LOGFLARE_PUBLIC_ACCESS_TOKEN',
    'LOGFLARE_PRIVATE_ACCESS_TOKEN', 'LOGFLARE_API_KEY']) {
    values[key] = randomBytes(32).toString('hex');
  }
  for (const [key, value] of Object.entries(values)) {
    const line = new RegExp(`^${key}=.*$`, 'm');
    if (!line.test(template)) throw new Error(`Missing template variable: ${key}`);
    template = template.replace(line, `${key}=${value}`);
  }
  // Exclusive creation also protects against concurrent setup and symlinks.
  writeFileSync(target, template, { mode: 0o600, flag: 'wx' });
  return true;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const created = configure(fileURLToPath(new URL('..', import.meta.url)));
  console.log(created ? 'Created fresh docker/.env; no credentials printed.' : 'Preserved existing docker/.env unchanged.');
}
