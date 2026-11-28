// WH-305, case B5 (static part): the money-marks and feed-format change of the contract
// ~/ws/fresh/product/tech/app-offline-dues-statement.md (section 7: "No change to get_customer_dues, get_customer_statement or
// their figures") must not redefine the three dues and statement functions. Migrations after the base of this card (231) are
// checked by content, not by number. The figures themselves are compared on the seed by tests/dues-figures-snapshot.mjs
// (snapshot before, snapshot after, compare), which Test runs.
// AGREE WITH DEVELOPMENT (WH-305): the new migrations of the topic "money marks for goods, rates and settings" are those numbered
// above 231 that mention warehouse_sync.log_change.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { repo } from './backup-test-helpers.mjs';

const BASE = 231;
const dir = join(repo, 'migrations');
const later = readdirSync(dir).filter(f => /^\d+_.*\.sql$/.test(f) && Number(f.split('_')[0]) > BASE);
const text = f => readFileSync(join(dir, f), 'utf8');
const DEFINES = /CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+(public\.)?(get_customer_dues|get_customer_dues_for|get_customer_statement)\s*\(/i;

test('no migration after the base redefines get_customer_dues, get_customer_dues_for or get_customer_statement', () => {
  assert.deepEqual(later.filter(f => DEFINES.test(text(f))), []);
});

test('the money-marks migration does not touch the dues or statement functions at all (no patch of their text)', () => {
  const marks = later.filter(f => /warehouse_sync\.log_change/.test(text(f)));
  assert.deepEqual(marks.filter(f => /get_customer_(dues|statement)/.test(text(f))), []);
});
