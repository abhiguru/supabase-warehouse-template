// Rows of the pre-printed invoice form (print-invoice-preprinted).
//
// The form has a fixed number of item rows per page. Each GRN item group prints
// a header row (item, packaging, inward quantity, receipt date, GRN number)
// before its first dispatch line, so a page is filled by rows, not by lines
// (review 2026-10-13, PRINT1: 20 lines of 20 groups printed 40 rows). This
// module imports nothing so that the node tests can load it directly.

export interface InvoicePrintLine {
  grn_items_id?: unknown;
  [key: string]: unknown;
}

export interface InvoicePrintRow<L> {
  kind: 'group' | 'line';
  line: L;
  // A group header repeated at the top of a page because its group goes on from the page before.
  continued: boolean;
}

export interface InvoicePrintPage<L> {
  rows: InvoicePrintRow<L>[];
  // The invoice lines printed on this page, in order (the 'line' rows).
  lines: L[];
}

// Lines of the same GRN item together, the groups in the order first seen.
export function groupInvoiceLines<L extends InvoicePrintLine>(lines: L[]): L[] {
  const groups = new Map<unknown, L[]>();
  for (const line of lines) {
    const group = groups.get(line.grn_items_id);
    if (group) group.push(line);
    else groups.set(line.grn_items_id, [line]);
  }
  return [...groups.values()].flat();
}

// Pages of at most rowsPerPage rows. A group's header comes before its first
// line; when a group goes on to another page its header is repeated there,
// marked continued; a header is never the last row of a page (it moves to the
// next page with its first line). Lines are expected grouped (groupInvoiceLines).
export function paginateInvoiceRows<L extends InvoicePrintLine>(lines: L[], rowsPerPage: number): InvoicePrintPage<L>[] {
  if (!Number.isInteger(rowsPerPage) || rowsPerPage < 2) {
    throw new Error('rows per page must be an integer of at least 2 (a group header and one line)');
  }
  const pages: InvoicePrintPage<L>[] = [];
  let page: InvoicePrintPage<L> = { rows: [], lines: [] };
  let started = false;
  let previousGroup: unknown;
  for (const line of lines) {
    const firstOfGroup = !started || line.grn_items_id !== previousGroup;
    if (firstOfGroup) {
      if (page.rows.length + 2 > rowsPerPage) {
        pages.push(page);
        page = { rows: [], lines: [] };
      }
      page.rows.push({ kind: 'group', line, continued: false });
    } else if (page.rows.length + 1 > rowsPerPage) {
      pages.push(page);
      page = { rows: [{ kind: 'group', line, continued: true }], lines: [] };
    }
    page.rows.push({ kind: 'line', line, continued: false });
    page.lines.push(line);
    started = true;
    previousGroup = line.grn_items_id;
  }
  if (page.rows.length > 0) pages.push(page);
  return pages;
}
