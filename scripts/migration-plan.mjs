import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

// Definition files (migrations/definitions/*.sql): functions that setup applies again whenever the file's checksum changes, after the
// numbered files. A file holds only CREATE OR REPLACE FUNCTION, COMMENT ON FUNCTION, GRANT/REVOKE ... ON FUNCTION and ALTER FUNCTION ... SET
// or RESET (no table, no data, no owner, rename, schema or SECURITY change): the numbered chain keeps those. And it concerns one function:
// every statement names the function of the file's REVOKE ALL ON FUNCTION line, so a file cannot grant or re-create another one.
// definitionProblems returns what in a file is something else; the plan is not built (nothing reaches the database) when a file has such
// a statement.
const FUNCTION_NAME = '[a-z_][a-z0-9_]*\\.[a-z_][a-z0-9_]*';
// What may follow ALTER FUNCTION name(args): SET param TO|= value[, value] and RESET param|ALL, one or more. A parameter or an argument
// named `set` cannot pass for the clause: the argument list is cut out first.
const ALTER_ACTIONS = /^(?:\s*(?:SET\s+(?!SCHEMA\b)[a-z_][a-z0-9_.]*\s*(?:TO|=)\s*(?:DEFAULT|[^\s,;]+(?:\s*,\s*[^\s,;]+)*)|RESET\s+(?:ALL|[a-z_][a-z0-9_.]*)))+\s*$/i;

// The text of a SQL file outside comments and quotes: comments, 'strings', "identifiers" and $tag$ bodies are replaced by a placeholder,
// so what is left is the statements themselves. Returns null for an unterminated quote or comment.
function bareSql(sql) {
  let out = '';
  for (let i = 0; i < sql.length;) {
    const rest = sql.slice(i);
    let m;
    if (rest.startsWith('--')) { const end = sql.indexOf('\n', i); i = end < 0 ? sql.length : end; continue; }
    if (rest.startsWith('/*')) {
      let depth = 0, j = i;
      for (; j < sql.length; j++) {
        if (sql.startsWith('/*', j)) { depth++; j++; } else if (sql.startsWith('*/', j) && --depth === 0) { j++; break; }
      }
      if (depth !== 0) return null;
      i = j + 1; out += ' '; continue;
    }
    if (rest[0] === "'") {
      // E'...' takes a backslash as an escape; a plain string does not.
      const escapes = /(?:^|[^A-Za-z0-9_$])[eE]$/.test(out);
      let j = i + 1;
      for (; j < sql.length; j++) {
        if (escapes && sql[j] === '\\') { j++; continue; }
        if (sql[j] === "'") { if (sql[j + 1] === "'") { j++; continue; } break; }
      }
      if (j >= sql.length) return null;
      i = j + 1; out += "''"; continue;
    }
    if (rest[0] === '"') { const end = sql.indexOf('"', i + 1); if (end < 0) return null; i = end + 1; out += '"x"'; continue; }
    if ((m = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(rest)) && !/[A-Za-z0-9_]$/.test(out)) {
      const end = sql.indexOf(m[0], i + m[0].length);
      if (end < 0) return null;
      i = end + m[0].length; out += "''"; continue;
    }
    out += sql[i]; i++;
  }
  return out;
}

// The function a statement names, from the text that starts at its name: { name: 'schema.name', args: 'normalised argument types', rest }.
// null when the name is not schema-qualified, lower-case and unquoted, or the argument list is not closed.
function functionReference(text) {
  const head = new RegExp(`^(${FUNCTION_NAME})\\s*\\(`, 'i').exec(text);
  if (!head) return null;
  let depth = 1, i = head[0].length;
  for (; i < text.length && depth > 0; i++) { if (text[i] === '(') depth++; else if (text[i] === ')') depth--; }
  if (depth !== 0) return null;
  const args = text.slice(head[0].length, i - 1).replace(/\s+/g, ' ').replace(/ ?([(),[\]]) ?/g, '$1').trim().toLowerCase();
  return { name: head[1].toLowerCase(), args, rest: text.slice(i).trim() };
}

// One statement of a definition file: { reference, revokeAll } when it is allowed, null when it is not.
function classify(statement) {
  let m;
  if ((m = /^CREATE\s+OR\s+REPLACE\s+FUNCTION\s+/i.exec(statement))) {
    const reference = functionReference(statement.slice(m[0].length));
    return reference && { reference, create: true };
  }
  if ((m = /^COMMENT\s+ON\s+FUNCTION\s+/i.exec(statement))) {
    const reference = functionReference(statement.slice(m[0].length));
    return reference && /^IS\b/i.test(reference.rest) ? { reference } : null;
  }
  if ((m = /^(?:GRANT|REVOKE)\s[^]*?\sON\s+FUNCTION\s+/i.exec(statement))) {
    const reference = functionReference(statement.slice(m[0].length));
    return reference && /^(?:TO|FROM)\s/i.test(reference.rest) ? { reference, revokeAll: /^REVOKE\s+ALL(?:\s+PRIVILEGES)?\s+ON\s+FUNCTION\s/i.test(statement) } : null;
  }
  if ((m = /^ALTER\s+FUNCTION\s+/i.exec(statement))) {
    const reference = functionReference(statement.slice(m[0].length));
    return reference && ALTER_ACTIONS.test(reference.rest) ? { reference } : null;
  }
  return null;
}

// What a definition file holds: { problems, identity }. problems are the statements that are not allowed (see above); identity is the
// function of the file's REVOKE ALL ON FUNCTION line as 'schema.name(argument types)' (null without one), and a statement that names another
// function is a problem too.
function analyse(sql) {
  const bare = bareSql(sql);
  if (bare === null) return { problems: ['an unterminated quote, comment or dollar-quoted body'], identity: null };
  if (bare.includes('\\')) return { problems: ['a backslash outside a quoted text (a psql command)'], identity: null };
  const problems = [];
  const classified = [];
  for (const statement of bare.split(';').map(text => text.trim()).filter(Boolean)) {
    const found = classify(statement);
    if (found) classified.push({ ...found, statement }); else problems.push(statement.replace(/\s+/g, ' ').slice(0, 60));
  }
  const anchor = classified.find(item => item.revokeAll);
  const identity = anchor ? `${anchor.reference.name}(${anchor.reference.args})` : null;
  // Without a REVOKE ALL line the file's function is the one it creates, so that a file of statements about two functions is refused.
  const expected = anchor?.reference ?? classified[0]?.reference;
  for (const item of classified) {
    const { name, args } = item.reference;
    if (expected && (name !== expected.name || (!item.create && args !== expected.args))) {
      problems.push(`names ${name}(${args}) and not ${expected.name}(${expected.args}): ${item.statement.replace(/\s+/g, ' ').slice(0, 40)}`);
    }
  }
  return { problems, identity };
}

export function definitionProblems(sql) {
  return analyse(sql).problems;
}

function definitionFiles(root) {
  const directory = resolve(root, 'migrations', 'definitions');
  if (!existsSync(directory)) return [];
  // Alphabetical order of the names: 00_authorize_rpc.sql comes first, because every other function calls authorize_rpc.
  return readdirSync(directory).sort().map(name => {
    if (!/^[a-z0-9_]+\.sql$/.test(name)) throw new Error(`Invalid definition filename: ${name}`);
    const sql = readFileSync(resolve(directory, name), 'utf8');
    const { problems, identity } = analyse(sql);
    if (problems.length) {
      throw new Error(`migrations/definitions/${name} holds more than function definitions, or a statement about another function (${problems.slice(0, 3).join('; ')}). A definition file may only hold CREATE OR REPLACE FUNCTION, COMMENT ON FUNCTION, GRANT/REVOKE ... ON FUNCTION and ALTER FUNCTION ... SET/RESET, all about the one function of its REVOKE ALL ON FUNCTION line; tables, data, owners, SECURITY changes and signature changes belong in a numbered migration.`);
    }
    if (!identity || !/^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*\([a-z0-9_ ,.[\]]*\)$/.test(identity)) {
      throw new Error(`migrations/definitions/${name} needs a line REVOKE ALL ON FUNCTION schema.name(argument types) FROM ..., written with unquoted lower-case names, so that the plan knows which function the file replaces.`);
    }
    return { name, sql, checksum: createHash('sha256').update(sql).digest('hex'), identity, functionName: identity.slice(0, identity.indexOf('(')) };
  });
}

// through: optional file name; the plan then stops after that file (the Baseline reload loads old data between
// the baseline and 111 onward). An unknown name is an error.
export function migrationPlan(root, { through } = {}) {
  const directory = resolve(root, 'migrations');
  const files = readdirSync(directory).filter(name => name.endsWith('.sql')).sort();
  if (!files.length) throw new Error('No migrations found');
  if (through !== undefined && !files.includes(through)) throw new Error(`Unknown migration for --through: ${through}`);
  const planned = through === undefined ? files : files.slice(0, files.indexOf(through) + 1);
  const migrations = planned.map(name => {
    if (!/^\d+_[a-z0-9_]+\.sql$/.test(name)) throw new Error('Invalid migration filename');
    const sql = readFileSync(resolve(directory, name), 'utf8');
    return { name, sql, checksum: createHash('sha256').update(sql).digest('hex') };
  });
  // Definition files come after the numbered files, so a run that stops at --through (the Baseline reload) has none.
  const definitions = through === undefined ? definitionFiles(root) : [];
  // The names of this directory as a SQL array; every name matched ^\d+_[a-z0-9_]+\.sql$ above, so no quote can occur.
  const namesLiteral = `ARRAY[${files.map(name => `'${name}'`).join(', ')}]::text[]`;
  // Each file runs in its own transaction with a lock_timeout of 10 s: a file that has to wait longer than that for a lock (a live session
  // holding the table) fails with 55P03 and rolls back whole, and scripts/migrate.sh runs the plan again, which skips the files the
  // ledger already holds. The API schema cache is told to reload right after each COMMIT, not only at the end, so that a run that stops
  // part way leaves the API on the schema the database really has.
  // 71041 serializes migration runs. Session level: released at the end, or when psql stops on an error.
  const result = [String.raw`\set ON_ERROR_STOP on
SELECT pg_advisory_lock(71041);
CREATE SCHEMA IF NOT EXISTS warehouse_migrations;
REVOKE ALL ON SCHEMA warehouse_migrations FROM PUBLIC,anon,authenticated;
CREATE TABLE IF NOT EXISTS warehouse_migrations.applied (
  name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
);
DO $$ BEGIN
  IF to_regclass('public.user_profiles') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM warehouse_migrations.applied) THEN
    RAISE EXCEPTION 'Refusing to initialize an existing, untracked warehouse database';
  END IF;
END $$;
-- A migration the ledger recorded but this release does not contain (a database built by the chain that the baseline
-- replaced, or a file that was deleted) is an error: nothing is changed, and the message says what to do.
DO $$
DECLARE unknown text;
BEGIN
  SELECT string_agg(name, ', ' ORDER BY name) INTO unknown FROM warehouse_migrations.applied
   WHERE name <> ALL (${namesLiteral});
  IF unknown IS NOT NULL THEN
    RAISE EXCEPTION 'This database recorded migrations that are not in this release (%). Either it was built by an earlier migration chain and cannot be migrated in place (reload it: docs/OPERATOR_INSTALL.md, "Baseline reload"), or it is newer than this checkout (check out the release that recorded those migrations).', left(unknown, 200);
  END IF;
END $$;`];
  // A migration may touch any function, and the definition files are the one source of every function they hold: a migration that carries
  // the facility forward therefore forgets the recorded checksums in its own transaction, and every definition is applied again after it
  // (also in a retry after a failure part way). The table exists once an earlier run created it; the first run applies every file anyway.
  const resetDefinitions = definitions.length ? `
  DO $$ BEGIN IF to_regclass('warehouse_migrations.definitions') IS NOT NULL THEN DELETE FROM warehouse_migrations.definitions; END IF; END $$;` : '';
  for (const { name, sql, checksum } of migrations) {
    result.push(String.raw`
SELECT EXISTS (SELECT 1 FROM warehouse_migrations.applied WHERE name='${name}') AS applied \gset
\if :applied
  SELECT checksum='${checksum}' AS unchanged FROM warehouse_migrations.applied WHERE name='${name}' \gset
  \if :unchanged
    \echo Already applied: ${name}
  \else
    DO $$ BEGIN RAISE EXCEPTION 'Applied migration changed: ${name}. Restore it; add a new migration instead.'; END $$;
  \endif
\else
  \echo Applying: ${name}
  BEGIN;
  SET LOCAL lock_timeout = '10s';
${sql}${resetDefinitions}
  INSERT INTO warehouse_migrations.applied(name,checksum) VALUES ('${name}','${checksum}');
  COMMIT;
  NOTIFY pgrst, 'reload schema';
\endif`);
  }
  if (definitions.length) {
    // Applied when the stored checksum differs (or there is none), each in its own transaction with the same lock_timeout; the row is
    // written in that transaction, and the API schema cache is told to reload after the COMMIT. A file that did not change is skipped.
    result.push(String.raw`
CREATE TABLE IF NOT EXISTS warehouse_migrations.definitions (
  name text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
);`);
    for (const { name, sql, checksum, identity, functionName } of definitions) {
      const [schema, proname] = functionName.split('.');
      // A definition only replaces a function that a numbered migration created, with the signature of its REVOKE line: when the function is
      // gone (dropped or given another signature by a migration) the file is stale and the plan stops here, naming it, instead of bringing the
      // function back with its grants; and a CREATE with another argument list would add a second overload, which rolls the file back.
      result.push(String.raw`
\echo Checking definition: ${name}
SELECT to_regprocedure('${identity}') IS NOT NULL AS defn_exists \gset
\if :defn_exists
\else
  DO $$ BEGIN RAISE EXCEPTION 'migrations/definitions/${name}: ${identity} does not exist (the REVOKE line must give argument types only, no argument names); a definition only replaces a function that a numbered migration created (remove the file, or change it to the new signature in the same commit as the migration)'; END $$;
\endif
SELECT count(*) AS defn_overloads FROM pg_proc WHERE pronamespace = '${schema}'::regnamespace AND proname = '${proname}' \gset
SELECT coalesce((SELECT checksum='${checksum}' FROM warehouse_migrations.definitions WHERE name='${name}'), false) AS unchanged \gset
\if :unchanged
  \echo Definition unchanged: ${name}
\else
  \echo Applying definition: ${name}
  BEGIN;
  SET LOCAL lock_timeout = '10s';
${sql}
  SELECT count(*) = :defn_overloads AS defn_same FROM pg_proc WHERE pronamespace = '${schema}'::regnamespace AND proname = '${proname}' \gset
  \if :defn_same
  \else
    DO $$ BEGIN RAISE EXCEPTION 'migrations/definitions/${name}: the file would add another ${functionName} with a different argument list; a definition only replaces the function of its REVOKE line (a new signature is a numbered migration)'; END $$;
  \endif
  INSERT INTO warehouse_migrations.definitions(name,checksum) VALUES ('${name}','${checksum}')
    ON CONFLICT (name) DO UPDATE SET checksum=EXCLUDED.checksum, applied_at=now();
  COMMIT;
  NOTIFY pgrst, 'reload schema';
\endif`);
    }
    // A row of a file that is no longer in the directory goes, so that the same file added again later is applied.
    result.push(String.raw`
DELETE FROM warehouse_migrations.definitions WHERE name <> ALL (ARRAY[${definitions.map(({ name }) => `'${name}'`).join(', ')}]::text[]);`);
  }
  result.push("NOTIFY pgrst, 'reload schema';\nSELECT pg_advisory_unlock(71041);\n");
  return result.join('\n');
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  let through;
  if (args.length) {
    if (args.length !== 2 || args[0] !== '--through' || !args[1]) {
      process.stderr.write('Usage: migration-plan.mjs [--through <migration file name>]\n');
      process.exit(2);
    }
    through = args[1];
  }
  try {
    process.stdout.write(migrationPlan(fileURLToPath(new URL('..', import.meta.url)), { through }));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}
