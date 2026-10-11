import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = name => readFileSync(new URL(`../migrations/${name}`, import.meta.url), 'utf8');
const escaped = text => text.replace(/[^\x00-\x7F]/g, character => `\\u${character.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`);

test('migration 48 holds no invisible or non-ASCII character', () => {
  // Its comment on warehouse_security.trimmed_reason says the trim class is written with
  // escapes. A literal no-break space or zero-width space would look like nothing in an
  // editor and in a diff, and could be changed or lost without anyone seeing it.
  const lines = migration('00000000000048_owner_decisions.sql').split('\n');
  const found = lines.flatMap((line, index) => /[^\x20-\x7E]/.test(line) ? [`line ${index + 1}: ${escaped(line.replace(/[\x00-\x1F\x7F]/g, '?'))}`] : []);
  assert.deepEqual(found, []);
});

test('the zero-charge reason is trimmed of the characters migration 41 trims from the discount reason', () => {
  // Migration 41 (applied, checksum-locked) holds the class as literal characters. Migration 48
  // must name the same code points, as \uXXXX escapes of the regular expression, at both ends
  // of the reason. tests/zero_charge_reason.sql compares the two rules in the database.
  const literal = migration('00000000000041_invoice_line_rules.sql').match(/blank constant text := '(\[[^']+\]\+)';/);
  assert.ok(literal, 'the discount trim class was not found in migration 41');
  assert.match(literal[1], /[^\x00-\x7F]/, 'migration 41 is expected to hold the characters themselves');
  const written = escaped(literal[1]);
  assert.equal(written, '[\\s\\u0085\\u00A0\\u00AD\\u1680\\u180E\\u2000-\\u200F\\u2028-\\u202F\\u205F-\\u2064\\u3000\\uFEFF]+');
  assert.ok(migration('00000000000048_owner_decisions.sql').includes(`'^${written}|${written}$'`),
    `migration 48 does not trim with ${written} at both ends`);
});
