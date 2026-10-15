import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const script = name => readFileSync(new URL(`../scripts/${name}`, import.meta.url), 'utf8');
// The append-only records the owner asked for (discount: migration 41; zero charge and item
// prices: migration 48). A restore that loses them must not compare as identical.
const histories = ['invoice_discount_history', 'invoice_zero_charge_history', 'item_price_history'];

test('the data fingerprint covers the three histories beside the business tables', () => {
  const list = script('data-fingerprint.sh').match(/^tables=\(([^)]*)\)/m);
  assert.ok(list, 'data-fingerprint.sh has no tables=(...) list');
  const tables = list[1].split(/\s+/).filter(Boolean);
  for (const table of ['customers', 'users_customers_new', 'items', 'item_storage_prices', 'goodsreceived', 'goodsreceived_trl', 'grn_images',
    'dispatch', 'dispatch_trl', 'dispatch_images', 'invoice', 'invoice_trl', 'stock_movements', 'user_profiles', ...histories,
    'standard_rate_tiers', 'grn_rates']) {
    assert.ok(tables.includes(table), `${table} is not fingerprinted`);
  }
  assert.equal(new Set(tables).size, tables.length);
});

test('the backup integrity report counts the histories only for a backup that has migration 48', () => {
  // restore.sh and verify-restore.sh run this file on the restored database and diff the output
  // with the backup's integrity.txt, before any newer migration is applied. A backup taken before
  // migration 48 has no history lines (and two of the tables do not exist in it), so every added
  // line sits inside a block that is skipped unless migration 48 is in the ledger.
  const lines = script('backup-integrity.sql').split('\n');
  const open = lines.findIndex(line => /^\\if :histories_recorded$/.test(line));
  const close = lines.findIndex((line, index) => index > open && /^\\endif$/.test(line));
  assert.ok(open > 0 && close > open, 'no \\if :histories_recorded ... \\endif block');
  assert.match(lines.slice(0, open).join('\n'),
    /SELECT EXISTS \(SELECT 1 FROM warehouse_migrations\.applied WHERE name = '00000000000048_owner_decisions\.sql'\) AS histories_recorded \\gset/);
  const inside = lines.slice(open + 1, close).join('\n');
  for (const table of histories) assert.match(inside, new RegExp(`'${table}_count=' \\|\\| count\\(\\*\\) FROM public\\.${table};`), `${table} is not counted`);
  assert.match(inside, /acl_authenticated_invoice_internal_columns=/);
  const outside = [...lines.slice(0, open), ...lines.slice(close + 1)].filter(line => !line.startsWith('--')).join('\n');
  assert.doesNotMatch(outside, /_history|zero_charge|internal_columns/, 'a line outside the block would break the comparison for an earlier backup');
});
