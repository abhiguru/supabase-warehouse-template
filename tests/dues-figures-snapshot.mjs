// WH-311: the before-and-after comparison of the three dues figures of every customer, to the paisa.
//   node tests/dues-figures-snapshot.mjs snapshot <out.json>      reads get_customer_dues from the database of the fictional
//                                                                 installation (WAREHOUSE_STATE_DIR, as tests/scale-check.mjs) and writes
//                                                                 each customer's invoices_amount, not_invoiced_left and not_invoiced_in_store,
//                                                                 sorted by customer id
//   node tests/dues-figures-snapshot.mjs compare <before.json> <after.json>   exits 1 on any difference, even one paisa
//   node tests/dues-figures-snapshot.mjs per-customer <snapshot.json>   calls get_customer_dues_for for every customer of the snapshot and exits 1
//                                                                 when any of its three figures differs from the list's, or it says the customer is not listed
// Another installation than the fictional one (read-only calls only): DUES_DB_CONTAINER=<db container> DUES_DB_COMPOSE_ENV=<its compose.env>.
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

// responseText: the text of the answer of get_customer_dues_for -> one snapshot row (same shape as snapshotFromResponse's) and whether the
// list shows that customer. The answer's `customer` object carries the same three figures as a list entry.
export function rowFromCustomerResponse(responseText) {
  const quoted = responseText.replace(new RegExp(`("(?:${FIGURES.join('|')})"\\s*:\\s*)(-?\\d+(?:\\.\\d+)?)(?![\\d.eE])`, 'g'), '$1"$2"');
  const answer = JSON.parse(quoted);
  assert.equal(answer.success, true, `get_customer_dues_for succeeded: ${answer.error ?? ''}`);
  const customer = answer.customer;
  assert.equal(typeof customer?.customer_id, 'string', 'the answer names the customer');
  const row = { customer_id: customer.customer_id };
  for (const figure of FIGURES) {
    assert.equal(typeof customer[figure], 'string', `${customer.customer_id}: ${figure} is a plain decimal`);
    row[figure] = canonicalDecimal(customer[figure]);
  }
  return { row, listed: answer.listed };
}

// listRows: a snapshot of the list; answers: [{ row, listed }] from get_customer_dues_for, one per customer of the list.
// -> differences (empty when every customer's own answer equals its list entry, to the paisa, and the answer says it is listed).
export function comparePerCustomer(listRows, answers) {
  const differences = compareSnapshots(listRows, answers.map(answer => answer.row));
  for (const answer of answers) if (answer.listed !== true) differences.push(`${answer.row.customer_id}: in the list but get_customer_dues_for says it is not listed`);
  return differences;
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

// Runs read-only calls through docker exec psql as the service role. calls: SQL expressions returning jsonb. -> one answer text per call.
// The fictional installation by default; DUES_DB_CONTAINER and DUES_DB_COMPOSE_ENV point it at another installation's database.
async function readFromDatabase(calls) {
  // Dynamic imports: the unit tests of this file need no installation.
  let env;
  let container;
  if (process.env.DUES_DB_CONTAINER) {
    assert.ok(process.env.DUES_DB_COMPOSE_ENV, 'DUES_DB_COMPOSE_ENV (the compose.env holding POSTGRES_PASSWORD) is required with DUES_DB_CONTAINER');
    env = (await import('../scripts/doctor-common.mjs')).readEnv(process.env.DUES_DB_COMPOSE_ENV);
    container = process.env.DUES_DB_CONTAINER;
  } else {
    env = (await import('./operator-fixture.mjs')).operatorFixture().env;
    container = `${env.WAREHOUSE_PROJECT_NAME}-db-1`;
  }
  // The service role passes warehouse_security.authorize_rpc and the administrator check of the dues functions.
  const query = ["SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', false) \\g /dev/null",
    ...calls.map(call => `SELECT ${call}::text;`)].join('\n');
  const result = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${env.POSTGRES_PASSWORD}`, container,
    'psql', '-X', '-qAt', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], { input: query + '\n', encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  assert.equal(result.status, 0, `the dues call failed: ${result.stderr?.slice(-400)}`);
  const answers = result.stdout.split('\n').filter(line => line.length > 0);
  assert.equal(answers.length, calls.length, 'one answer per call');
  return answers;
}

async function main(argv) {
  const [mode, first, second] = argv;
  if (mode === 'snapshot' && first) {
    const rows = snapshotFromResponse((await readFromDatabase(['public.get_customer_dues()']))[0]);
    writeFileSync(first, JSON.stringify(rows, null, 2) + '\n');
    console.log(`Dues snapshot: ${rows.length} customers written to ${first}.`);
  } else if (mode === 'per-customer' && first) {
    const rows = JSON.parse(readFileSync(first, 'utf8'));
    const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
    for (const row of rows) assert.match(row.customer_id, uuid, 'a customer id in the snapshot is a uuid');
    const texts = await readFromDatabase(rows.map(row => `public.get_customer_dues_for('${row.customer_id}'::uuid)`));
    const differences = comparePerCustomer(rows, texts.map(rowFromCustomerResponse));
    if (differences.length) {
      console.error(`get_customer_dues_for differs from the list (${differences.length}):\n${differences.slice(0, 50).join('\n')}`);
      process.exitCode = 1;
    } else console.log(`get_customer_dues_for equals the list for all ${rows.length} customers.`);
  } else if (mode === 'compare' && first && second) {
    const differences = compareSnapshots(JSON.parse(readFileSync(first, 'utf8')), JSON.parse(readFileSync(second, 'utf8')));
    if (differences.length) {
      console.error(`Dues figures differ (${differences.length}):\n${differences.slice(0, 50).join('\n')}`);
      process.exitCode = 1;
    } else console.log('Dues figures are identical.');
  } else {
    console.error('usage: dues-figures-snapshot.mjs snapshot <out.json> | compare <before.json> <after.json> | per-customer <snapshot.json>');
    process.exitCode = 2;
  }
}

if (isMain(import.meta.url)) await main(process.argv.slice(2));
