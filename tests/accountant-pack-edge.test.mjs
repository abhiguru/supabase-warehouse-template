// WH-158 criterion 9 (contract section 4): the edge function generate-accountant-pack is wired like the other signed-in functions.
// Written BEFORE the build: fails today because the function, its router entry and its worker-env list do not exist.
// tests/worker-env.test.mjs already compares every list with the Deno.env.get() calls of the function and its imports; this file pins the new entry.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { workerEnvNames } from '../functions/main/worker-env.ts';

const functions = new URL('../functions/', import.meta.url).pathname;

test('[crit 9] generate-accountant-pack: the worker gets the signed-in names and the anon key, nothing else (no server-key call is needed beyond the signed-in set)', () => {
  assert.deepEqual([...workerEnvNames['generate-accountant-pack']].sort(),
    ['JWT_SECRET', 'SUPABASE_ANON_KEY', 'SUPABASE_REST_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_URL']);
});

test('[crit 9] generate-accountant-pack: the router allows it, and index.ts serves accountantPack from _shared/accountant-pack.ts', () => {
  const router = readFileSync(`${functions}main/index.ts`, 'utf8');
  assert.match(router, /'generate-accountant-pack'/);
  assert.ok(existsSync(`${functions}generate-accountant-pack/index.ts`));
  const index = readFileSync(`${functions}generate-accountant-pack/index.ts`, 'utf8');
  assert.match(index, /from\s+['"]\.\.\/_shared\/accountant-pack\.ts['"]/);
  assert.match(index, /Deno\.serve\(\s*accountantPack\s*\)/);
});

test('[crit 9] accountantPack refuses a GET with 405 (POST required) before it reads anything', async () => {
  const { accountantPack } = await import('../functions/_shared/accountant-pack.ts');
  const response = await accountantPack(new Request('http://localhost/generate-accountant-pack', { method: 'GET' }));
  assert.equal(response.status, 405);
  const body = await response.json();
  assert.equal(body.success, false);
});
