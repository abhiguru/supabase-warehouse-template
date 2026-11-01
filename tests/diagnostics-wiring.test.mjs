import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// The logs of a service are lost when its container is recreated, so each script that recreates containers saves them first
// (scripts/service-diagnostics.mjs, saveLogs). These checks only read the scripts: the behaviour of the save is in
// tests/service-diagnostics.test.mjs.
const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const SAVE = label => new RegExp(`^\\s*node "\\$ROOT/scripts/service-diagnostics\\.mjs" save ${label} \\|\\| true$`, 'm');
const at = (text, pattern) => { const found = text.search(pattern); assert.ok(found >= 0, `${pattern} is in the script`); return found; };

test('rotate-keys.sh saves the logs before the first change (the staging of the new keys), so before any recreate', () => {
  const text = read('rotate-keys.sh');
  assert.ok(at(text, SAVE('rotate-keys')) < at(text, /^node "\$ROOT\/scripts\/rotate-keys\.mjs"/m), 'before the first change');
  assert.ok(at(text, SAVE('rotate-keys')) < at(text, /compose --profile '\*' up -d --force-recreate/));
});

test('rotate-db-passwords.sh saves the logs before the first change (the staging of the new passwords), so before any recreate', () => {
  const text = read('scripts/rotate-db-passwords.sh');
  assert.ok(at(text, SAVE('rotate-db-passwords')) < at(text, /^node "\$ROOT\/scripts\/db-roles\.mjs" stage/m), 'before the first change');
  assert.ok(at(text, SAVE('rotate-db-passwords')) < at(text, /^if \(\(\$\{#recreate\[@\]\}\)\) && ! compose --profile '\*' up -d --force-recreate/m));
});

test('setup.sh saves the logs only when the state already has containers, before its first up', () => {
  const text = read('setup.sh');
  const save = at(text, SAVE('setup'));
  assert.match(text.slice(save - 200, save), /if \[\[ -n "\$\(bash "\$ROOT\/scripts\/compose\.sh" ps -a -q 2>\/dev\/null \|\| true\)" \]\]; then\n$/, 'guarded by the existing containers');
  assert.ok(save < at(text, /compose\.sh" up -d/));
});

test('upgrade.sh saves the logs before it closes the gateways (which recreates them) and its plan says so', () => {
  const text = read('upgrade.sh');
  assert.ok(at(text, SAVE('upgrade')) < at(text, /maintenance\.sh" on/));
  assert.match(text, /say .*pre-upgrade-\* and pre-setup-\*/);
});
