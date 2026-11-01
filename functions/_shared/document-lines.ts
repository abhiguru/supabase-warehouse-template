import type { Builder, RestClient, RestResult } from './supabase-rest.ts';

/** Lines read per request. PostgREST may cap a read (PGRST_DB_MAX_ROWS, 2000 in the stack), so a page never asks for more than this. */
export const PDF_PAGE_ROWS = 1000;

/**
 * The most lines one GRN, dispatch, invoice or stock PDF prints. Above it the request is answered 400 before any further page is read.
 * The system supports invoices of 3,055 lines. 3,500 lines (about 120 pages) render in about 2 s through the real renderer; at 5,000
 * lines (about 160 pages) Chrome passes the renderer's 1,100 MB watchdog and the job fails with 503 (docs/PDF_GENERATION.md,
 * "Long documents"), so the limit is below that point.
 */
export const MAX_PDF_ROWS = 3500;

export const PDF_TOO_LONG = `Document exceeds the limit of ${MAX_PDF_ROWS.toLocaleString('en-US')} lines`;

/**
 * Reads every line of one document, `PDF_PAGE_ROWS` at a time, ordered by the line's `id` so that the pages join without a gap or a repeat
 * (the line tables have no sequence column; `id` is a stable, unique key, and a read without an order has none of that). The first page asks for the
 * exact count: a document over `MAX_PDF_ROWS` is refused (400) after that one read; the reading stops at the count or at a short page.
 * `filter` adds the table's own conditions. A failed page is a 503, as before. The answer has the shape of one read (`data`, `error`, `count`).
 */
export async function readDocumentLines(reader: RestClient, table: string, columns: string, filter: (query: Builder) => Builder): Promise<RestResult> {
  const lines: any[] = [];
  let total: number | null = null;
  for (let page = 0; ; page++) {
    const from = page * PDF_PAGE_ROWS;
    const result = await filter(reader.from(table).select(columns, page === 0 ? { count: 'exact' } : {}))
      .order('id').range(from, from + PDF_PAGE_ROWS - 1);
    if (result.error || !Array.isArray(result.data)) throw { status: 503, message: 'Document items unavailable' };
    if (page === 0) {
      total = result.count;
      if ((total ?? 0) > MAX_PDF_ROWS) throw { status: 400, message: PDF_TOO_LONG };
    }
    lines.push(...result.data);
    if (lines.length > MAX_PDF_ROWS) throw { status: 400, message: PDF_TOO_LONG };
    if (result.data.length < PDF_PAGE_ROWS || (total !== null && lines.length >= total)) return { data: lines, error: null, count: total };
  }
}
