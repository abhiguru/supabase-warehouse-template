// Maintainer-only generator. Input must be a reviewed, schema-only pg_dump.
// Never accepts a data dump. No database or credential access is performed here.
import { readFileSync, writeFileSync } from 'node:fs';
const [input, output] = process.argv.slice(2);
if (!input || !output) throw new Error('Usage: node scripts/import-schema.mjs reviewed-schema.sql generated-baseline.sql');
const source = readFileSync(input, 'utf8');
if (/^(COPY .* FROM stdin|INSERT INTO)/m.test(source)) throw new Error('Refusing a dump containing table data');
const omitted = [];
let sql = source.split(/\n--\n(?=-- Name:)/).filter(block => {
  const name = block.match(/CREATE FUNCTION (?:public|utils)\.([^(]+)/)?.[1];
  if (name && (/^test_|_test$|_backup$|^backup_|^auth_test$|^get_signed_image_url$|^init_msg91_config$/.test(name))) {
    omitted.push(name); return false;
  }
  return true;
}).join('\n--\n');
// The remaining UUID literal was an old operator fallback, not a portable identity.
sql = sql.replace(/(v_user_id\s*:=\s*COALESCE\(auth\.uid\(\),\s*)'[0-9a-f-]{36}'::uuid/gi, '$1NULL::uuid');
// Remove dump metadata/comments; never retain local usernames or object comments.
sql = sql.replace(/^--.*\n/gm, '').replace(/^\\(?:un)?restrict .*\n/gm, '').replace(/[\t ]+$/gm, '');
sql = sql.replace(/\n{4,}/g, '\n\n\n');
sql = sql.replace('CREATE SCHEMA public;', 'CREATE SCHEMA IF NOT EXISTS public;');
// Custom auth does not run GoTrue's session-table migrations.
sql = sql.replace(/ALTER TABLE ONLY public\.user_session_activity\s+ADD CONSTRAINT user_session_activity_auth_session_id_fkey[^;]+;/, '');
const prohibited = {
  credentials: /ghp_[a-zA-Z0-9]{20,}|github_pat_|BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY|eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]+\./,
  deployment: /gurucold|guru cold|gurunanak|abhinav/i,
  phoneLiteral: /'(?:\+?91)?[6-9][0-9]{9}'/,
  privateAddress: /https?:\/\/(?:10\.|192\.168\.|172\.(?:1[6-9]|2[0-9]|3[01])\.)/,
};
for (const [kind, pattern] of Object.entries(prohibited)) {
  if (pattern.test(sql)) throw new Error(`Review required: ${kind} marker remains; no output written`);
}
const bootstrap = `-- Generated schema-only warehouse baseline. No production rows or credentials.
-- Import overrides/security/auth are applied before any API service starts.
CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pgjwt WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;
`;
const lockdown = `
-- Fail closed even when the upstream image has permissive default privileges.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public, utils FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
`;
writeFileSync(output, bootstrap + sql.trim() + '\n' + lockdown);
console.log(JSON.stringify({ generated: output, tables: (sql.match(/CREATE TABLE /g) || []).length, functions: (sql.match(/CREATE FUNCTION /g) || []).length, omittedDevelopmentFunctions: omitted }));
