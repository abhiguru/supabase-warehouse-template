// scripts/contract-sql.mjs: the function and table names the migrations leave defined, which check-mobile-contract.mjs compares with
// the names the app calls. A DROP must remove a name (it used to be ignored, so a dropped function the app still calls passed).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { definedNames } from '../scripts/contract-sql.mjs';

const functions = (...texts) => definedNames(texts).functions;
const relations = (...texts) => definedNames(texts).relations;

test('a DROP FUNCTION in a later migration removes the name; a later CREATE defines it again', () => {
  const create = 'CREATE FUNCTION public.get_thing(p_id uuid) RETURNS jsonb LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(create), ['get_thing']);
  assert.deepEqual(functions(create, 'DROP FUNCTION public.get_thing(uuid);'), []);
  assert.deepEqual(functions(create, 'DROP FUNCTION IF EXISTS get_thing(uuid) CASCADE;'), []);
  assert.deepEqual(functions(create, 'DROP FUNCTION public.get_thing(uuid);', 'CREATE OR REPLACE FUNCTION public.get_thing() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;'), ['get_thing']);
  // Dropped and created again in one file, in that order and in the other.
  assert.deepEqual(functions(create + '\nDROP FUNCTION public.get_thing(uuid);\nCREATE FUNCTION public.get_thing(p_id uuid, p_x int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;'), ['get_thing']);
  assert.deepEqual(functions('CREATE FUNCTION public.get_thing(p_id uuid) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;\nDROP FUNCTION public.get_thing(uuid);'), []);
});

test('dropping one overload keeps the name while another overload stays, and a list of signatures drops each', () => {
  const two = 'CREATE FUNCTION public.f(a int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;\nCREATE FUNCTION public.f(a int, b numeric(10,2) DEFAULT 1) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(two, 'DROP FUNCTION public.f(integer);'), ['f']);
  assert.deepEqual(functions(two, 'DROP FUNCTION public.f(integer);', 'DROP FUNCTION public.f(integer, numeric);'), []);
  assert.deepEqual(functions(two, 'DROP FUNCTION IF EXISTS public.f(integer), public.f(integer, numeric);'), []);
  assert.deepEqual(functions(two, 'DROP FUNCTION public.f;'), [], 'no argument list: every overload');
  // A function built from pg_get_functiondef text has no CREATE; the ALTER and GRANT that name it show that it exists (migration 124).
  const rebuilt = 'DROP FUNCTION public.f(integer);\nALTER FUNCTION public.f(a integer, b boolean) OWNER TO supabase_admin;';
  assert.deepEqual(functions('CREATE FUNCTION public.f(a int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;', rebuilt), ['f']);
  assert.deepEqual(functions('CREATE FUNCTION public.f(a int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;', 'DROP FUNCTION public.f(integer);\nGRANT ALL ON FUNCTION public.f(integer, boolean) TO authenticated;'), ['f']);
});

test('other schemas and comments do not count', () => {
  const create = 'CREATE FUNCTION public.keep_me() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(create, 'DROP FUNCTION warehouse_security.keep_me();'), ['keep_me'], 'another schema\'s function of that name');
  assert.deepEqual(functions(create, '-- DROP FUNCTION public.keep_me();\n/* DROP FUNCTION public.keep_me(); */'), ['keep_me']);
  assert.deepEqual(functions('-- CREATE FUNCTION public.only_in_a_comment() RETURNS int'), []);
  assert.deepEqual(functions('CREATE FUNCTION warehouse_security.hidden() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;'), []);
});

test('DROP TABLE and DROP VIEW remove the name, with IF EXISTS, a list and CASCADE', () => {
  const create = 'CREATE TABLE public.a (id int);\nCREATE VIEW public.b AS SELECT 1;\nCREATE TABLE IF NOT EXISTS public.c (id int);';
  assert.deepEqual(relations(create), ['a', 'b', 'c']);
  assert.deepEqual(relations(create, 'DROP TABLE public.a;'), ['b', 'c']);
  assert.deepEqual(relations(create, 'DROP VIEW IF EXISTS public.b CASCADE;'), ['a', 'c']);
  assert.deepEqual(relations(create, 'DROP TABLE IF EXISTS public.a, public.c CASCADE;'), ['b']);
  assert.deepEqual(relations(create, 'DROP TABLE storage.a;'), ['a', 'b', 'c'], 'another schema');
  assert.deepEqual(relations(create, 'DROP TABLE public.a;', 'CREATE TABLE public.a (id int);'), ['a', 'b', 'c']);
});

test('commas inside brackets, parentheses and quoted defaults are not arguments (get_stock_aging_report of migration 119)', () => {
  const create = 'CREATE OR REPLACE FUNCTION public.get_stock_aging_report(p_customer_uuid uuid DEFAULT NULL::uuid, p_aging_buckets integer[] DEFAULT ARRAY[120, 240, 364]) RETURNS jsonb LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(create, 'DROP FUNCTION public.get_stock_aging_report(uuid, integer[]);'), [], 'two arguments');
  // The line as migration 119 has it.
  const migration = readdirSync(new URL('../migrations/', import.meta.url)).find(name => /^0*119_/.test(name));
  const line = readFileSync(new URL(`../migrations/${migration}`, import.meta.url), 'utf8').split('\n').find(text => text.includes('FUNCTION public.get_stock_aging_report('));
  assert.ok(line, 'the migration still defines it');
  assert.deepEqual(functions(`${line}\n$$ SELECT 1 $$;`, 'DROP FUNCTION public.get_stock_aging_report(uuid, integer[]);'), []);
  const quoted = 'CREATE FUNCTION public.q(a text DEFAULT \'x,y\', b text[] DEFAULT \'{a,b}\', c numeric(10,2) DEFAULT 1) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(quoted, 'DROP FUNCTION public.q(text, text[], numeric);'), [], 'three arguments');
  assert.deepEqual(functions(quoted, 'DROP FUNCTION public.q(text, text);'), ['q'], 'two arguments is another overload');
});

test('OUT parameters are not counted on CREATE, as the signature of DROP and ALTER leaves them out', () => {
  const create = 'CREATE FUNCTION public.o(a int, OUT b int, c int, out d text) RETURNS record LANGUAGE sql AS $$ SELECT 1, 2 $$;';
  assert.deepEqual(functions(create, 'DROP FUNCTION public.o(integer, integer);'), []);
  assert.deepEqual(functions(create, 'DROP FUNCTION public.o(integer, integer, text);'), ['o'], 'not three');
  assert.deepEqual(functions('CREATE FUNCTION public.p(out_value int, INOUT x int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;', 'DROP FUNCTION public.p(integer, integer);'), [], 'a name that starts with out is an input; INOUT is one too');
});

test('ALTER FUNCTION RENAME TO and SET SCHEMA take the old name away; other ALTER statements still show that it exists', () => {
  const create = 'CREATE FUNCTION public.old_name(a int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(create, 'ALTER FUNCTION public.old_name(integer) RENAME TO new_name;'), ['new_name']);
  assert.deepEqual(functions(create, 'ALTER FUNCTION old_name(integer)\n  RENAME  TO "new_name";'), ['new_name']);
  assert.deepEqual(functions(create, 'ALTER FUNCTION public.old_name(integer) SET SCHEMA archive;'), []);
  assert.deepEqual(functions(create, 'ALTER FUNCTION public.old_name(integer) OWNER TO supabase_admin;'), ['old_name']);
  const two = create + '\nCREATE FUNCTION public.old_name(a int, b int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(two, 'ALTER FUNCTION public.old_name(integer) RENAME TO other;'), ['old_name', 'other'], 'the other overload stays');
});

test('DROP ROUTINE removes a function like DROP FUNCTION', () => {
  const create = 'CREATE FUNCTION public.r(a int) RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;';
  assert.deepEqual(functions(create, 'DROP ROUTINE public.r(integer);'), []);
  assert.deepEqual(functions(create, 'DROP ROUTINE IF EXISTS r(integer), public.other(text) CASCADE;'), []);
  assert.deepEqual(functions(create, 'DROP ROUTINE public.r(integer, integer);'), ['r'], 'another signature');
});
