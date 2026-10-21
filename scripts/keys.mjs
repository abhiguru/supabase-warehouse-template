import { createHmac, randomBytes } from 'node:crypto';

// Signing material shared by first installation (configure.mjs) and key
// rotation (rotate-keys.mjs). Nothing here reads or writes operator state.
export const SIGNING_KEY_NAMES = ['JWT_SECRET', 'ANON_KEY', 'SERVICE_ROLE_KEY'];
const SECRET_PATTERN = /^[0-9a-f]{96}$/;
const TEN_YEARS_SECONDS = 10 * 365 * 86400;

export function signRoleKey(secret, role, now = Date.now()) {
  if (!SECRET_PATTERN.test(secret || '')) throw new Error('Signing secret must be 96 hexadecimal characters.');
  if (!['anon', 'service_role'].includes(role)) throw new Error(`Unsupported API key role: ${role}.`);
  const part = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const body = `${part({ alg: 'HS256', typ: 'JWT' })}.${part({ iss: 'supabase', role, exp: Math.floor(now / 1000) + TEN_YEARS_SECONDS })}`;
  return `${body}.${createHmac('sha256', secret).update(body).digest('base64url')}`;
}

export function generateSigningKeys() {
  const secret = randomBytes(48).toString('hex');
  return { JWT_SECRET: secret, ANON_KEY: signRoleKey(secret, 'anon'), SERVICE_ROLE_KEY: signRoleKey(secret, 'service_role') };
}

// Replace whole `KEY=...` lines in an env file. Every key must already exist,
// values stay single-line, and no other line changes.
export function replaceEnvLines(text, values) {
  let result = text;
  for (const [key, value] of Object.entries(values)) {
    if (!/^[A-Z][A-Z0-9_]*$/.test(key)) throw new Error(`Unsupported variable name: ${key}`);
    if (typeof value !== 'string' || /[$\r\n#]/.test(value)) throw new Error(`Unsupported character in ${key}.`);
    const line = new RegExp(`^${key}=.*$`, 'm');
    if (!line.test(result)) throw new Error(`Missing template variable: ${key}`);
    result = result.replace(line, () => `${key}=${value}`);
  }
  return result;
}

// PostgREST exposes the `public` schema only. The earlier defaults also listed storage (no client reads it through
// /rest/v1, and it let roles with storage policies write storage.objects rows directly) and, before migration 103,
// graphql_public (a schema that no longer exists). A compose.env still holding one of the two old defaults is
// rewritten to `public`; a list an operator changed is left alone.
export function updateRestSchemas(text) {
  return text.replace(/^PGRST_DB_SCHEMAS=public,storage(?:,graphql_public)?$/m, 'PGRST_DB_SCHEMAS=public');
}
