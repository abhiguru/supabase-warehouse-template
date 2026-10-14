import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { groupInvoiceLines, paginateInvoiceRows } from '../functions/_shared/invoice-print-layout.ts';

// PRINT1 (review 2026-10-13): the invoice print sliced 20 invoice LINES per page,
// but a page prints a group header row before the first line of each GRN item
// group, so 20 lines of 20 groups filled 40 rows of a 20-row form and pushed the
// totals and the next invoice out of the pre-printed fields. Pages are now built
// from the rows they print.
const source = readFileSync(new URL('../functions/print-invoice-preprinted/index.ts', import.meta.url), 'utf8');
const ROWS = 20;
const lines = groups => groups.flatMap(([group, count]) =>
  Array.from({ length: count }, (_, i) => ({ id: `${group}-${i + 1}`, grn_items_id: group })));

// Every rule a page must keep, checked on any pagination.
function checkPages(pages, input, rowsPerPage) {
  let previousGroup;
  const printed = [];
  pages.forEach((page, p) => {
    assert.ok(page.rows.length > 0, `page ${p + 1} is empty`);
    assert.ok(page.rows.length <= rowsPerPage, `page ${p + 1} has ${page.rows.length} rows (at most ${rowsPerPage})`);
    assert.notEqual(page.rows.at(-1).kind, 'group', `page ${p + 1} ends with a lone group header`);
    assert.deepEqual(page.lines, page.rows.filter(row => row.kind === 'line').map(row => row.line), `page ${p + 1}: lines are its line rows`);
    page.rows.forEach((row, r) => {
      if (row.kind === 'group') {
        assert.equal(page.rows[r + 1]?.kind, 'line', `page ${p + 1} row ${r + 1}: a header is followed by a line`);
        assert.equal(page.rows[r + 1].line.grn_items_id, row.line.grn_items_id, 'the header names the group of the line below it');
        assert.equal(row.continued, row.line.grn_items_id === previousGroup, `page ${p + 1} row ${r + 1}: continued only when the group went on from the page before`);
        if (row.continued) assert.equal(r, 0, 'a continued header is the first row of its page');
      } else {
        const header = page.rows.slice(0, r).findLast(candidate => candidate.kind === 'group');
        assert.equal(header?.line.grn_items_id, row.line.grn_items_id, `page ${p + 1} row ${r + 1}: the line sits under its group's header`);
        printed.push(row.line);
      }
    });
    previousGroup = page.rows.at(-1).line.grn_items_id;
  });
  assert.deepEqual(printed, input, 'every line is printed once, in order');
}

test('twenty lines in twenty groups take two pages of 20 rows, not one of 40', () => {
  const input = lines(Array.from({ length: 20 }, (_, i) => [`G${i + 1}`, 1]));
  const pages = paginateInvoiceRows(input, ROWS);
  checkPages(pages, input, ROWS);
  assert.deepEqual(pages.map(page => page.rows.length), [20, 20]);
  assert.deepEqual(pages.map(page => page.lines.length), [10, 10]);
  // The old paginator: 20 lines on one page, which printed 40 rows.
  assert.equal(input.slice(0, ROWS).length + new Set(input.slice(0, ROWS).map(line => line.grn_items_id)).size, 40);
});

test('one group of 45 lines repeats its header, marked continued, at the top of each further page', () => {
  const input = lines([['BIG', 45]]);
  const pages = paginateInvoiceRows(input, ROWS);
  checkPages(pages, input, ROWS);
  assert.deepEqual(pages.map(page => page.lines.length), [19, 19, 7]);
  assert.deepEqual(pages.map(page => [page.rows[0].kind, page.rows[0].continued]), [['group', false], ['group', true], ['group', true]]);
});

test('a group header is never left alone at the bottom of a page', () => {
  // 18 lines of A fill 19 rows; B's header and first line need two rows, so both move.
  const input = lines([['A', 18], ['B', 3]]);
  const pages = paginateInvoiceRows(input, ROWS);
  checkPages(pages, input, ROWS);
  assert.deepEqual(pages.map(page => page.rows.length), [19, 4]);
  assert.deepEqual(pages[1].rows.map(row => row.kind), ['group', 'line', 'line', 'line']);
  assert.equal(pages[1].rows[0].continued, false);
  // Exactly full: 19 lines of A and nothing of B on page one.
  const full = lines([['A', 19], ['B', 1]]);
  const fullPages = paginateInvoiceRows(full, ROWS);
  checkPages(fullPages, full, ROWS);
  assert.deepEqual(fullPages.map(page => page.rows.length), [20, 2]);
});

test('mixed groups at several page sizes keep every rule', () => {
  const input = lines([['A', 1], ['B', 7], ['C', 2], ['D', 30], ['E', 1], ['F', 1], ['G', 12], ['H', 3]]);
  for (const rowsPerPage of [2, 3, 5, 20, 47]) checkPages(paginateInvoiceRows(input, rowsPerPage), input, rowsPerPage);
  assert.deepEqual(paginateInvoiceRows([], ROWS), []);
  for (const bad of [1, 0, -3, 2.5, NaN, '20']) assert.throws(() => paginateInvoiceRows(input, bad), /rows per page/, String(bad));
});

test('lines are grouped by GRN item, the groups in the order first seen', () => {
  const a1 = { id: 'a1', grn_items_id: 'A' }, b1 = { id: 'b1', grn_items_id: 'B' }, a2 = { id: 'a2', grn_items_id: 'A' }, c1 = { id: 'c1', grn_items_id: 'C' };
  assert.deepEqual(groupInvoiceLines([a1, b1, a2, c1]), [a1, a2, b1, c1]);
  assert.deepEqual(groupInvoiceLines([]), []);
});

test('the invoice print renders the paginated rows', () => {
  assert.ok(!source.includes('items.slice(startIdx'), 'the line-count slicing is gone');
  assert.ok(!source.includes('groupedItemsMap'), 'the grouping lives in the shared module');
  assert.match(source, /import \{[^}]*\bgroupInvoiceLines\b[^}]*\bpaginateInvoiceRows\b[^}]*\} from '\.\.\/_shared\/invoice-print-layout\.ts'/);
  assert.match(source, /paginateInvoiceRows\(items, LAYOUT\.ITEMS_PER_PAGE\)/);
  assert.match(source, /LAYOUT\.ITEMS_PER_PAGE - page\.rows\.length/, 'the padding fills the rows the page did not print');
  assert.match(source, /page\.rows\.forEach/);
  assert.match(source, /' contd\.'/);
});
