/**
 * How many printed pages a document's rows will fill, estimated from the text of the cells. The renderer's memory grows with the pages
 * of one document (jobs of about 130 pages and more start to fail on its memory watchdog: docs/PDF_GENERATION.md, "Long documents"), and a row
 * whose cell wraps onto a second line takes about half as much room again, so the number of lines alone is no limit.
 *
 * Measured with the document layout at 12 px: a one-line row is about 31 to a page, a row of two lines about 1.47 one-line rows; the
 * item column holds about 55 characters on a line, the other columns about 24; Gujarati text sets a little taller. The estimate
 * is meant to be about right or a little high (3,055 invoice lines with 80-character names: estimated 145, measured 146).
 */
export const MAX_PDF_PAGES = 120;
/** A document of more than this many estimated pages is rendered alone (X-Render-Solo): two such jobs together fail. */
export const SOLO_PDF_PAGES = 50;

const ROWS_PER_PAGE = 31;
const EXTRA_LINE = 0.47;
const ITEM_CHARS = 55;
const OTHER_CHARS = 24;
const GUJARATI_FACTOR = 1.05;
const gujarati = /[઀-૿]/;

export function estimatePages(rows: unknown[][]): number {
  let weight = 0;
  for (const row of rows) {
    let lines = 1;
    let tall = false;
    row.forEach((cell, index) => {
      const text = String(cell ?? '');
      lines = Math.max(lines, Math.ceil(text.length / (index === 0 ? ITEM_CHARS : OTHER_CHARS)));
      if (gujarati.test(text)) tall = true;
    });
    weight += (1 + EXTRA_LINE * (lines - 1)) * (tall ? GUJARATI_FACTOR : 1);
  }
  return Math.ceil(weight / ROWS_PER_PAGE);
}
