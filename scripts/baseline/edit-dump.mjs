// The explicit edits that turn a raw `pg_dump --schema-only` of a chain-built database into the baseline body.
// Each edit is one small, commented step of editDump(); nothing is changed by hand.
// Usage: node edit-dump.mjs <raw.sql> <removed-roles, comma separated>  (prints the edited text on stdout)
import { readFileSync } from 'node:fs';
import { isMain } from '../is-main.mjs';

// Roles of the image that the new bootstrap does not create (design 4.7 and 13): no grants to them, no defaults for them.
export const DEFAULT_REMOVED_ROLES = [
  'postgres', 'dashboard_user', 'supabase_auth_admin', 'supabase_functions_admin', 'supabase_read_only_user',
  'supabase_realtime_admin', 'supabase_replication_admin', 'supabase_etl_admin', 'warehouse_list_refresher', 'warehouse_monitoring',
];
// The removed roles the CHAIN creates (warehouse_*). The others are the old image's own roles and always exist on it;
// these must be gone at the chain's end (a chain migration drops them), or dump-baseline.sh fails (review M8).
export const chainCreatedRoles = roles => roles.filter(r => r.startsWith('warehouse_'));
// Event triggers of the image's PostgREST setup point at the excluded `extensions` schema (design 13, M3).
export const STRIPPED_EVENT_TRIGGERS = ['pgrst_ddl_watch', 'pgrst_drop_watch'];
// Functions the image already has in `auth`; the chain only redefines them. Their owner becomes supabase_admin (M3).
export const AUTH_FUNCTIONS = ['email', 'jwt', 'role', 'uid'];

const HEADER_RE = /^--\n-- (?:Name|Data for Name): .*?; Type: ([A-Z ]+?); Schema: .*\n--\n/m;

// Splits dump text into [{ type, text }] blocks, one per "-- Name: …; Type: …" header; the text before the first header
// is a block with type ''.
export function splitBlocks(text) {
  const lines = text.split('\n');
  const blocks = [{ type: '', lines: [] }];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === '--' && /^-- (?:Name|Data for Name): .*; Type: [A-Z ]+; Schema: /.test(lines[i + 1] ?? '') && lines[i + 2] === '--') {
      const type = lines[i + 1].match(/; Type: ([A-Z ]+); Schema: /)[1];
      blocks.push({ type, name: lines[i + 1].match(/: (.*?); (?:Type)/)[1], schema: lines[i + 1].match(/; Schema: ([^;]*);?/)[1], lines: [] });
    }
    blocks.at(-1).lines.push(lines[i]);
  }
  return blocks.map(b => ({ type: b.type, name: b.name ?? '', schema: b.schema ?? '', text: b.lines.join('\n') }));
}

const escapeRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// True when a top-level ACL statement names one of the removed roles.
export function namesRemovedRole(line, roles) {
  const names = roles.map(escapeRe).join('|');
  if (/^ALTER DEFAULT PRIVILEGES FOR ROLE /.test(line)) {
    return new RegExp(`^ALTER DEFAULT PRIVILEGES FOR ROLE (?:${names}) |(?: TO| FROM) (?:${names})(?: WITH GRANT OPTION)?;$`).test(line);
  }
  return new RegExp(`^(?:GRANT|REVOKE) .*(?: TO| FROM) (?:${names})(?: WITH GRANT OPTION)?;$`).test(line);
}

export function editDump(raw, { removedRoles = DEFAULT_REMOVED_ROLES } = {}) {
  const roles = removedRoles;
  let blocks = splitBlocks(raw);

  // E1. The dump's own header (SET lines, search_path) and psql meta commands (\restrict, \connect) are dropped;
  // the baseline writes its own transaction-local header.
  blocks[0].text = blocks[0].text.split('\n').filter(l => !/^(SET |SELECT pg_catalog\.set_config\(|\\)/.test(l)).join('\n');
  blocks = blocks.map(b => ({ ...b, text: b.text.split('\n').filter(l => !/^\\(un)?restrict /.test(l)).join('\n') }));

  // E2. Event triggers that point at the excluded `extensions` schema are removed (whole block). With `-n` pg_dump skips
  // event triggers anyway, so today this is only a guard.
  blocks = blocks.filter(b => !(b.type === 'EVENT TRIGGER' && STRIPPED_EVENT_TRIGGERS.some(n => b.text.includes(`CREATE EVENT TRIGGER ${n} `))));

  // E3. Grants and default privileges that name a removed role are removed, in ACL and DEFAULT ACL blocks only
  // (a GRANT line inside a function body is never touched).
  blocks = blocks.map(b => (b.type === 'ACL' || b.type === 'DEFAULT ACL')
    ? { ...b, text: b.text.split('\n').filter(l => !namesRemovedRole(l, roles)).join('\n') }
    : b);

  // E4. The image's `public` schema exists: do not create it. `auth` may or may not exist (image or bootstrap).
  // E5. The auth functions exist in the image: replace them instead of creating them, and make supabase_admin their owner
  // (supabase_auth_admin is a removed role). Each edit stays inside the block of that very object.
  const ownerRe = roles.map(escapeRe).join('|');
  blocks = blocks.map(b => {
    let t = b.text;
    if (b.type === 'SCHEMA' && b.name === 'public') t = t.replace(/^CREATE SCHEMA public;\n/m, '');
    if (b.type === 'SCHEMA' && b.name === 'auth') t = t.replace(/^CREATE SCHEMA auth;\n/m, 'CREATE SCHEMA IF NOT EXISTS auth;\n');
    if (b.type === 'FUNCTION' && b.schema === 'auth') {
      const fn = AUTH_FUNCTIONS.find(f => b.name === `${f}()`);
      if (fn) {
        t = t.replace(new RegExp(`^CREATE FUNCTION auth\\.${fn}\\(\\)`, 'm'), `CREATE OR REPLACE FUNCTION auth.${fn}()`);
        t = t.replace(new RegExp(`^ALTER FUNCTION auth\\.${fn}\\(\\) OWNER TO (?:${ownerRe});$`, 'm'), `ALTER FUNCTION auth.${fn}() OWNER TO supabase_admin;`);
      }
    }
    return { ...b, text: t };
  });

  let text = blocks.map(b => b.text).join('\n');

  // E6. Session settings that the dump sets for itself become transaction-local (the runner wraps a file in BEGIN/COMMIT).
  // They sit between blocks, so this is the one edit that is not scoped to a block; the check below catches any other SET.
  text = text.replace(/^SET default_tablespace = '';$/gm, "SET LOCAL default_tablespace = '';");
  text = text.replace(/^SET default_table_access_method = (\w+);$/gm, 'SET LOCAL default_table_access_method = $1;');

  // Check: no removed role is left as an owner or in an ACL statement. Only top-level statements are looked at:
  // "ALTER … OWNER TO role;" lines, and the lines of ACL and DEFAULT ACL blocks (never function bodies).
  const left = [];
  const sessionAuth = new RegExp(`^SET SESSION AUTHORIZATION '?(?:${ownerRe})'?;$`);
  for (const b of splitBlocks(text)) {
    for (const line of b.text.split('\n')) {
      const owner = line.match(/^ALTER [A-Z ]+ .* OWNER TO (\S+);$/);
      if ((owner && roles.includes(owner[1])) || ((b.type === 'ACL' || b.type === 'DEFAULT ACL') && namesRemovedRole(line, roles))) left.push(line);
      // pg_dump writes this when a grantor is not the owner: the grants after it would run as a removed role.
      if (sessionAuth.test(line)) left.push(line);
      // A session-level setting would leak into the files applied after the baseline (design 13, M2).
      if (b.type !== 'FUNCTION' && (/^SET (?!LOCAL |SESSION AUTHORIZATION)/.test(line) || /^SELECT pg_catalog\.set_config\(.*, false\)/.test(line))) left.push(line);
    }
  }
  if (left.length) throw new Error(`A removed role or a session-level setting is still in the dump after the edits:\n${left.slice(0, 10).join('\n')}`);
  return text.replace(/\n{3,}/g, '\n\n').replace(/^\n+/, '');
}

if (isMain(import.meta.url)) {
  const [file, removed] = process.argv.slice(2);
  const removedRoles = removed ? removed.split(',').filter(Boolean) : DEFAULT_REMOVED_ROLES;
  process.stdout.write(editDump(readFileSync(file, 'utf8'), { removedRoles }));
}
