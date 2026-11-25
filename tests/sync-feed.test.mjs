// WH-297, the parts of the server change log and feed that need no database (contract ~/ws/fresh/product/tech/server-change-log-feed.md):
//   - criterion 14 / section 11: the `sync` capability is off by default, off for an instance.json written before it, and served by
//     get-public-config as the manifest says; scripts/set-capability.mjs turns it on and off, adding the key to an older manifest.
//   - case 1g / section 9: nothing switches the user triggers of a table off or on wholesale (ENABLE TRIGGER USER turns the feed's
//     ALWAYS trigger back into an ordinary one), and "Edit GRN" no longer calls the dead trigger switch.
// The SQL behaviour is proved by tests/sync_feed_*.sql and tests/sync_feed_concurrency.sh in tests/migrations.sh.
//
// AGREE WITH DEVELOPMENT (WH-297): the capability name and the call this file looks for.
const CAPABILITY = 'sync';
const DEAD_SWITCH = 'safe_disable_grn_trl_triggers';

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CAPABILITIES, setCapability } from '../scripts/set-capability.mjs';

const root = new URL('..', import.meta.url).pathname;
const read = path => readFileSync(join(root, path), 'utf8');
const MANIFEST = { schemaVersion: 1, instanceId: '99999999-aaaa-bbbb-cccc-dddddddddddd', displayName: 'Acme', companyName: 'Acme Cold',
  canonicalOrigin: 'https://api.example.test', capabilities: { sensors: false, printing: false, payments: false }, supportedApiVersions: ['1'] };
const BASE_ENV = { SUPABASE_URL: 'http://gateway:8000', SUPABASE_ANON_KEY: 'unit-anon', SUPABASE_PUBLIC_URL: 'https://api.example.test', APP_ENV: 'production',
  AUTH_MODE: 'operator', APP_COMPAT_JSON: JSON.stringify({ minimumClientVersion: '1.4.0' }) };
let handler;
let env = {};
const realDeno = globalThis.Deno;
const realFetch = globalThis.fetch;
const quiet = console.error;

before(async () => {
  globalThis.Deno = { serve: h => { handler = h; }, env: { get: name => env[name] } };
  globalThis.fetch = async url => {
    const path = new URL(url).pathname;
    if (path.endsWith('/rpc/get_public_config')) return new Response(JSON.stringify({ app_version: '0.2.0', maintenance_mode: false, feature_flags: {} }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    return new Response(JSON.stringify({ message: `unexpected ${path}` }), { status: 404 });
  };
  await import('../functions/get-public-config/index.ts');
});
after(() => { globalThis.Deno = realDeno; globalThis.fetch = realFetch; console.error = quiet; });

async function publicCapabilities(manifest) {
  env = { ...BASE_ENV, INSTANCE_MANIFEST_JSON: JSON.stringify(manifest) };
  console.error = () => {};
  try {
    const response = await handler(new Request('http://example.test/get-public-config'));
    const body = await response.json();
    assert.equal(response.status, 200, JSON.stringify(body));
    return body.data.capabilities;
  } finally { console.error = quiet; }
}

test('criterion 14: get-public-config answers sync false for a manifest without the key, and what the manifest says otherwise', async () => {
  const old = await publicCapabilities(MANIFEST);
  assert.equal(old[CAPABILITY], false, 'an instance.json written before the sync capability serves it off');
  const off = await publicCapabilities({ ...MANIFEST, capabilities: { ...MANIFEST.capabilities, [CAPABILITY]: false } });
  assert.equal(off[CAPABILITY], false);
  const on = await publicCapabilities({ ...MANIFEST, capabilities: { ...MANIFEST.capabilities, [CAPABILITY]: true } });
  assert.equal(on[CAPABILITY], true);
});

test('criterion 14: set-capability knows sync and adds it to a manifest written before it, changing nothing else', () => {
  assert.ok(CAPABILITIES.includes(CAPABILITY), `CAPABILITIES lists ${CAPABILITY}: ${CAPABILITIES.join(', ')}`);
  const stateDir = mkdtempSync(join(tmpdir(), 'warehouse-sync-capability-'));
  try {
    chmodSync(stateDir, 0o700);
    mkdirSync(join(stateDir, 'public'), { mode: 0o700 });
    const path = join(stateDir, 'public', 'instance.json');
    writeFileSync(path, JSON.stringify(MANIFEST, null, 2) + '\n', { mode: 0o600 });
    setCapability(stateDir, CAPABILITY, 'on');
    const turnedOn = JSON.parse(readFileSync(path, 'utf8'));
    assert.deepEqual(turnedOn.capabilities, { ...MANIFEST.capabilities, [CAPABILITY]: true });
    assert.deepEqual({ ...turnedOn, capabilities: MANIFEST.capabilities }, MANIFEST, 'only the capability changed');
    setCapability(stateDir, CAPABILITY, 'off');
    assert.deepEqual(JSON.parse(readFileSync(path, 'utf8')).capabilities, { ...MANIFEST.capabilities, [CAPABILITY]: false });
  } finally { rmSync(stateDir, { recursive: true, force: true }); }
});

// Every SQL and shell file that ships: the migrations, the definitions and the scripts.
function shippedFiles() {
  const files = [];
  const walk = dir => {
    for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
      const path = `${dir}/${entry.name}`;
      if (entry.isDirectory()) { if (entry.name !== 'node_modules') walk(path); } else if (/\.(sql|sh|mjs)$/.test(entry.name)) files.push(path);
    }
  };
  for (const dir of ['migrations', 'scripts']) walk(dir);
  return files;
}

test('case 1g: no migration, definition or script switches a table\'s user triggers off or on wholesale', () => {
  const files = shippedFiles();
  assert.ok(files.includes('migrations/definitions/update_grn.sql') && files.includes('scripts/restore.sh'), 'the walk reaches the definitions and the scripts');
  const wholesale = /\b(?:DISABLE|ENABLE)\s+TRIGGER\s+(?:USER|ALL)\b/i;
  const offenders = files.filter(path => wholesale.test(read(path)));
  assert.deepEqual(offenders, [], `DISABLE/ENABLE TRIGGER USER|ALL found in: ${offenders.join(', ')}`);
});

test('case 1g: "Edit GRN" (update_grn) no longer calls the trigger switch whose trigger is gone', () => {
  const body = read('migrations/definitions/update_grn.sql');
  assert.match(body, /CREATE OR REPLACE FUNCTION public\.update_grn\(/, 'the definition file is the one read');
  assert.equal(body.includes(DEAD_SWITCH), false, `update_grn still calls ${DEAD_SWITCH}()`);
});
