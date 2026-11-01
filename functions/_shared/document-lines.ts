import type { Builder, RestClient, RestResult } from './supabase-rest.ts';

export type DocumentKind = 'grn' | 'dispatch' | 'invoice' | 'stock';

/** Lines read per request. PostgREST may cap a read (PGRST_DB_MAX_ROWS, 2000 in the stack), so a page never asks for more than this. */
export const PDF_PAGE_ROWS = 1000;

/**
 * The most lines one GRN, dispatch, invoice or stock PDF prints. Above it the request is answered 400 before any further page is read.
 * The system supports invoices of 3,055 lines. The renderer's memory, not time, is the real limit: see MAX_PDF_PAGES.
 */
export const MAX_PDF_ROWS = 3500;

export const PDF_TOO_LONG = `Document exceeds the limit of ${MAX_PDF_ROWS.toLocaleString('en-US')} lines`;
export const PDF_CHANGED = 'The document changed while printing. Try again.';

const uuidV1Epoch = 0x01B21DD213814000n; // 1582-10-15 in 100 ns, as a v1 timestamp counts

/**
 * What `uuid_extract_timestamp(id)` returns, in microseconds, or null for an id that carries none (it sorts last, as NULL does in
 * an ascending ORDER BY). The screens list dispatch and invoice lines by this key, then by id.
 */
export function uuidTimeKey(id: unknown): bigint | null {
  if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return null;
  const version = id[14];
  if (version === '1') return (BigInt(`0x${id.slice(15, 18)}${id.slice(9, 13)}${id.slice(0, 8)}`) - uuidV1Epoch) / 10n;
  if (version === '7') return BigInt(`0x${id.slice(0, 8)}${id.slice(9, 13)}`) * 1000n;
  return null;
}

const byId = (a: any, b: any): number => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const byTimeThenId = (a: any, b: any): number => {
  const x = uuidTimeKey(a.id); const y = uuidTimeKey(b.id);
  if (x !== y) { if (x === null) return 1; if (y === null) return -1; return x < y ? -1 : 1; }
  return byId(a, b);
};

/**
 * The order each document's lines have on the screen, so the PDF lists them the same way: a GRN by line id (get_grn_details), a dispatch
 * and an invoice by the time in the line's id, then the id (get_dispatch_details, get_invoice_data). The stock list has no screen of
 * its own and uses the id.
 */
export const documentLineOrder: Record<DocumentKind, (a: any, b: any) => number> = {
  grn: byId, dispatch: byTimeThenId, invoice: byTimeThenId, stock: byId,
};

/**
 * Reads every line of one document, `PDF_PAGE_ROWS` at a time, by keyset: each page is `id > <last id of the page before>`, ordered by `id`, so
 * pages join without a gap or a repeat even when lines are added or removed between two reads (a repeated id is dropped). The first page asks
 * for the exact count: a document over `MAX_PDF_ROWS` is refused (400) after that one read. When the count was given and the lines read are
 * not that many at the end (the document changed, or a page came back short), the answer is 503 `PDF_CHANGED`. Without a count (the
 * server did not send one) the reading stops at a short page and the limit is checked on the lines read. The lines are then put in
 * the on-screen order of the document kind. `filter` adds the table's own conditions; a failed page is a 503.
 * The answer has the shape of one read (`data`, `error`, `count`).
 */
export async function readDocumentLines(reader: RestClient, kind: DocumentKind, table: string, columns: string, filter: (query: Builder) => Builder): Promise<RestResult> {
  const lines: any[] = [];
  const seen = new Set<string>();
  let total: number | null = null;
  let last: string | null = null;
  for (let page = 0; ; page++) {
    let query = filter(reader.from(table).select(`id,${columns}`, page === 0 ? { count: 'exact' } : {}));
    if (last !== null) query = query.gt('id', last);
    const result = await query.order('id').limit(PDF_PAGE_ROWS);
    if (result.error || !Array.isArray(result.data)) throw { status: 503, message: 'Document items unavailable' };
    if (page === 0) {
      total = result.count;
      if ((total ?? 0) > MAX_PDF_ROWS) throw { status: 400, message: PDF_TOO_LONG };
    }
    let added = 0;
    for (const line of result.data) {
      if (typeof line?.id !== 'string') throw { status: 503, message: 'Document items unavailable' };
      if (!seen.has(line.id)) { seen.add(line.id); lines.push(line); added++; }
    }
    if (lines.length > MAX_PDF_ROWS) throw { status: 400, message: PDF_TOO_LONG };
    last = result.data.length ? result.data[result.data.length - 1].id : last;
    // A page that adds nothing new (a server that ignored the id filter) ends the reading instead of repeating it for ever.
    if (result.data.length < PDF_PAGE_ROWS || added === 0 || (total !== null && lines.length >= total)) break;
  }
  if (total !== null && lines.length !== total) throw { status: 503, message: PDF_CHANGED };
  lines.sort(documentLineOrder[kind]);
  return { data: lines, error: null, count: total };
}
