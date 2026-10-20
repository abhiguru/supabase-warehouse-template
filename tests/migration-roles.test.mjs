import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

// Roles come from docker/volumes/db/00-bootstrap.sql, objects from the dump or the migrations (a restore replays the
// bootstrap, then the backup's objects, never a migration's role statement). So a migration after the baseline must not
// create, alter or drop a role, or grant membership in one. Rule: docs/CONTAINER_SECURITY.md, "Roles and migrations".
const dir = new URL('../migrations/', import.meta.url);
const stripComments = sql => sql.replace(/\/\*[\s\S]*?\*\//g, '').replace(/--[^\n]*/g, '');

test('no migration after the baseline creates, alters or drops a role, or grants a role to a role', () => {
  const later = readdirSync(dir).filter(name => name.endsWith('.sql') && name !== '00000000000000_baseline.sql');
  for (const name of later) {
    const sql = stripComments(readFileSync(new URL(name, dir), 'utf8'));
    assert.doesNotMatch(sql, /\b(CREATE|ALTER|DROP)\s+(ROLE|USER|GROUP)\b/i, `${name} changes a role: put it in docker/volumes/db/00-bootstrap.sql`);
    // GRANT <role> TO <role> has no ON; GRANT <privilege> ON <object> TO <role> does.
    for (const statement of sql.split(';')) {
      if (/^\s*(GRANT|REVOKE)\b/i.test(statement) && !/\bON\b/i.test(statement)) assert.fail(`${name} grants or revokes a role membership: ${statement.trim().slice(0, 80)}`);
    }
  }
});

test('the guard recognises what it forbids', () => {
  assert.match(stripComments('CREATE ROLE x;'), /\b(CREATE|ALTER|DROP)\s+(ROLE|USER|GROUP)\b/i);
  assert.equal(/\bON\b/i.test('GRANT pg_read_all_data TO authenticator'), false);
  assert.equal(/\bON\b/i.test('GRANT SELECT ON public.t TO authenticator'), true);
});
