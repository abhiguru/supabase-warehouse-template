// WH-311: the before-and-after comparison of the three dues figures of every customer, to the paisa.
//   node tests/dues-figures-snapshot.mjs snapshot <out.json>      reads get_customer_dues from the database of the fictional
//                                                                 installation (WAREHOUSE_STATE_DIR, as tests/scale-check.mjs) and writes
//                                                                 each customer's invoices_amount, not_invoiced_left and not_invoiced_in_store,
//                                                                 sorted by customer id
//   node tests/dues-figures-snapshot.mjs compare <before.json> <after.json>   exits 1 on any difference, even one paisa
// Money is never turned into a JavaScript number: the figures are cut out of the RPC's text as strings and compared as exact decimals.
// Usage on the five-year seed: take a snapshot before the WH-311 migration, apply it, take a second, then compare.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { isMain } from '../scripts/is-main.mjs';

export const FIGURES = ['invoices_amount', 'not_invoiced_left', 'not_invoiced_in_store'];

// "10.50", "10.5" and "0010.500" are one value; "-0.00" is 0. Anything that is not a plain decimal is refused.
export function canonicalDecimal(text) {
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(String(text));
  if (!match) throw new RangeError(`not a plain decimal: ${JSON.stringify(text)}`);
  const whole = match[2].replace(/^0+(?=\d)/, '');
  const fraction = (match[3] ?? '').replace(/0+$/, '');
  const body = fraction ? `${whole}.${fraction}` : whole;
  return body === '0' ? '0' : `${match[1]}${body}`;
}

// responseText: the text of the answer of get_customer_dues (the three figures are quoted before parsing, so no float rounding).
// -> [{ customer_id, invoices_amount, not_invoiced_left, not_invoiced_in_store }] sorted by customer id, figures as canonical strings.
export function snapshotFromResponse(responseText) {
  const quoted = responseText.replace(new RegExp(`("(?:${FIGURES.join('|')})"\\s*:\\s*)(-?\\d+(?:\\.\\d+)?)(?![\\d.eE])`, 'g'), '$1"$2"');
  const answer = JSON.parse(quoted);
  assert.equal(answer.success, true, 'get_customer_dues succeeded');
  assert.ok(Array.isArray(answer.customers), 'get_customer_dues lists customers');
  const seen = new Set();
  const rows = answer.customers.map(customer => {
    assert.equal(typeof customer.customer_id, 'string', 'a customer row has an id');
    assert.ok(!seen.has(customer.customer_id), `customer ${customer.customer_id} is listed once`);
    seen.add(customer.customer_id);
    const row = { customer_id: customer.customer_id };
    for (const figure of FIGURES) {
      assert.equal(typeof customer[figure], 'string', `${customer.customer_id}: ${figure} is a plain decimal`);
      row[figure] = canonicalDecimal(customer[figure]);
    }
    return row;
  });
  return rows.sort((a, b) => (a.customer_id < b.customer_id ? -1 : a.customer_id > b.customer_id ? 1 : 0));
}

// -> list of differences (empty when the two snapshots agree on every customer and every figure).
export function compareSnapshots(before, after) {
  const index = rows => new Map(rows.map(row => [row.customer_id, row]));
  const left = index(before);
  const right = index(after);
  const differences = [];
  for (const [id, row] of left) {
    const other = right.get(id);
    if (!other) { differences.push(`${id}: missing after`); continue; }
    for (const figure of FIGURES) {
      if (canonicalDecimal(row[figure]) !== canonicalDecimal(other[figure])) differences.push(`${id}: ${figure} ${row[figure]} before, ${other[figure]} after`);
    }
  }
  for (const id of right.keys()) if (!left.has(id)) differences.push(`${id}: extra after`);
  return differences;
}

function readFromDatabase() {
  // Dynamic import: the unit tests of this file need no installation.
  return import('./operator-fixture.mjs').then(({ operatorFixture }) => {
    const { env } = operatorFixture();
    // The service role passes warehouse_security.authorize_rpc and the administrator check of get_customer_dues.
    const query = `SELECT public.get_customer_dues()::text FROM (SELECT set_config('request.jwt.claims', '{"role":"service_role"}', false)) AS claims;`;
    const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`, `${env.WAREHOUSE_PROJECT_NAME}-db-1`,
      'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], { input: query + '\n', encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
    assert.equal(result.status, 0, `get_customer_dues failed: ${result.stderr?.slice(-400)}`);
    return result.stdout.trim();
  });
}

// TODO(WH-311): when Development adds the per-customer form of these figures (item 3 of the card), add a mode that calls it for every
// customer of a snapshot and fails when any of its three figures differs from the list. Its name is not decided yet, so none is called here.

async function main(argv) {
  const [mode, first, second] = argv;
  if (mode === 'snapshot' && first) {
    const rows = snapshotFromResponse(await readFromDatabase());
    writeFileSync(first, JSON.stringify(rows, null, 2) + '\n');
    console.log(`Dues snapshot: ${rows.length} customers written to ${first}.`);
  } else if (mode === 'compare' && first && second) {
    const differences = compareSnapshots(JSON.parse(readFileSync(first, 'utf8')), JSON.parse(readFileSync(second, 'utf8')));
    if (differences.length) {
      console.error(`Dues figures differ (${differences.length}):\n${differences.slice(0, 50).join('\n')}`);
      process.exitCode = 1;
    } else console.log('Dues figures are identical.');
  } else {
    console.error('usage: dues-figures-snapshot.mjs snapshot <out.json> | compare <before.json> <after.json>');
    process.exitCode = 2;
  }
}

if (isMain(import.meta.url)) await main(process.argv.slice(2));
