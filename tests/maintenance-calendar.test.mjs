// docs/MAINTENANCE_CALENDAR.md is reachable from where an operator or the owner looks, and its dates are the ones the checker uses.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { NODE_END_OF_LIFE } from '../scripts/watch.mjs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const calendar = read('docs/MAINTENANCE_CALENDAR.md');

test('the calendar is linked from the dependencies list, the operator guide and the README', () => {
  assert.match(read('docs/PRODUCTION_DEPENDENCIES.md'), /\]\(MAINTENANCE_CALENDAR\.md\)/);
  assert.match(read('docs/OPERATOR_INSTALL.md'), /\]\(MAINTENANCE_CALENDAR\.md\)/);
  assert.match(read('README.md'), /\]\(docs\/MAINTENANCE_CALENDAR\.md\)/);
  // The operator guide's link sits in the monthly runbook, not elsewhere.
  const monthly = read('docs/OPERATOR_INSTALL.md').split('### Monthly host maintenance')[1].split('\n## ')[0];
  assert.match(monthly, /\]\(MAINTENANCE_CALENDAR\.md\)/);
});

test('the calendar names the host Node.js end dates of the checker, the 2029 move and the exception renewal date', () => {
  for (const date of Object.values(NODE_END_OF_LIFE)) assert.ok(calendar.includes(`**${date}**`), `${date} is in the calendar`);
  assert.match(calendar, /PostgreSQL major move[^|]*\|\s*\*\*2029 H1\*\*/);
  const exceptions = JSON.parse(read('docker/image-exceptions.json')).exceptions;
  const expiries = new Set(exceptions.map(e => e.expires ?? e.expiresOn ?? e.expiry).filter(Boolean));
  assert.ok(expiries.size >= 1, 'the exception file has expiry dates');
  for (const date of expiries) assert.ok(calendar.includes(date), `the exception expiry ${date} is in the calendar`);
  assert.match(calendar, /forecast/i, 'forecasts are marked');
});

test('the calendar is sorted by its first date column, forecasts included', () => {
  // Only the rows that carry a year-month in the "When" column are ordered; recurring rows (weekly, monthly) come first.
  const rows = calendar.split('\n').filter(l => l.startsWith('| ') && !l.startsWith('| What') && !l.startsWith('| ---'));
  assert.ok(rows.length >= 25);
  const dated = rows.map(r => /(\d{4})-(\d{2})(?:-(\d{2}))?/.exec(r.split('|')[2])).filter(Boolean).map(m => `${m[1]}-${m[2]}`);
  assert.deepEqual([...dated].sort(), dated, dated.join(' '));
});
