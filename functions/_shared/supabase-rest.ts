// Minimal PostgREST and Storage client over plain fetch, replacing the vendored
// supabase-js. It covers only what the functions use: table reads (select with
// embedded resources, eq / is / gt filters, order, limit, single, maybeSingle,
// exact count), insert and update on a table, RPC calls, Storage upload and Storage
// signed URLs. Same style as operator-otp and central-exchange: plain fetch,
// `apikey` and `Authorization` headers, redirects refused.
//
// Like supabase-js, calls do not throw on a failed request: they resolve to
// { data, error, count } with `error` set ({ message, code, details, hint }).
// A timeout (default 60 s) is added; supabase-js had none.

export interface RestError { message: string; code: string; details: string; hint: string }
export interface RestResult<T = any> { data: T | null; error: RestError | null; count: number | null }
export interface RestOptions {
  /** Replaces `Authorization: Bearer <key>`, e.g. the caller's own token. */
  authorization?: string;
  timeoutMs?: number;
}

const DEFAULT_TIMEOUT_MS = 60000;

const failure = (message: string, code = '', details = '', hint = ''): RestError => ({ message, code, details, hint });

async function readError(response: Response): Promise<RestError> {
  const text = await response.text().catch(() => '');
  try {
    const body = JSON.parse(text);
    if (body && typeof body === 'object') {
      return failure(String(body.message ?? body.error ?? text), String(body.code ?? ''), String(body.details ?? ''), String(body.hint ?? ''));
    }
  } catch { /* not JSON */ }
  return failure(text || `HTTP ${response.status}`);
}

function parseBody(text: string): { data: any; error: RestError | null } {
  if (!text) return { data: null, error: null };
  try { return { data: JSON.parse(text), error: null }; } catch { return { data: null, error: failure('The answer was not JSON', '', text.slice(0, 200)) }; }
}

const networkError = (error: unknown): RestError =>
  failure(error instanceof Error ? `${error.name}: ${error.message}` : 'fetch failed');

export class Builder implements PromiseLike<RestResult> {
  private method = 'GET';
  private params: [string, string][] = [];
  private headers: Record<string, string> = {};
  private body: string | undefined;
  private mode: 'many' | 'single' | 'maybeSingle' = 'many';
  private prefer: string[] = [];

  private readonly client: RestClient;
  private readonly table: string;
  constructor(client: RestClient, table: string) { this.client = client; this.table = table; }

  select(columns = '*', options: { count?: 'exact' } = {}): this {
    this.params.push(['select', columns.replace(/\s+/g, '')]);
    if (this.method !== 'GET') this.prefer.push('return=representation');
    if (options.count) this.prefer.push(`count=${options.count}`);
    return this;
  }
  insert(values: unknown): this { this.method = 'POST'; this.body = JSON.stringify(values); return this; }
  update(values: unknown): this { this.method = 'PATCH'; this.body = JSON.stringify(values); return this; }
  eq(column: string, value: unknown): this { this.params.push([column, `eq.${value}`]); return this; }
  gt(column: string, value: unknown): this { this.params.push([column, `gt.${value}`]); return this; }
  is(column: string, value: null | boolean): this { this.params.push([column, `is.${value}`]); return this; }
  /** Like postgrest-js: `order=col.asc|desc[.nullsfirst|.nullslast]`; several calls are joined by commas. */
  order(column: string, options: { ascending?: boolean; nullsFirst?: boolean } = {}): this {
    let term = `${column}.${options.ascending === false ? 'desc' : 'asc'}`;
    if (options.nullsFirst !== undefined) term += options.nullsFirst ? '.nullsfirst' : '.nullslast';
    const existing = this.params.find(([name]) => name === 'order');
    if (existing) existing[1] += `,${term}`;
    else this.params.push(['order', term]);
    return this;
  }
  limit(count: number): this { this.params.push(['limit', String(count)]); return this; }
  single(): this { this.mode = 'single'; return this; }
  maybeSingle(): this { this.mode = 'maybeSingle'; return this; }

  async run(): Promise<RestResult> {
    try { return await this.execute(); } catch (error) { return { data: null, error: networkError(error), count: null }; }
  }

  private async execute(): Promise<RestResult> {
    const headers: Record<string, string> = { ...this.client.baseHeaders(), ...this.headers };
    if (this.method !== 'GET') headers['Content-Type'] = 'application/json';
    if (this.prefer.length) headers.Prefer = this.prefer.join(',');
    headers.Accept = this.mode === 'single' ? 'application/vnd.pgrst.object+json' : 'application/json';
    const query = new URLSearchParams(this.params).toString();
    const response = await fetch(`${this.client.url}/rest/v1/${this.table}${query ? `?${query}` : ''}`, {
      method: this.method, headers, body: this.body, redirect: 'error', signal: AbortSignal.timeout(this.client.timeoutMs),
    });
    if (!response.ok) return { data: null, error: await readError(response), count: null };
    let count: number | null = null;
    const range = response.headers.get('content-range');
    if (range && this.prefer.includes('count=exact')) {
      const total = Number(range.split('/')[1]);
      if (Number.isFinite(total)) count = total;
    }
    const parsed = parseBody(await response.text());
    if (parsed.error) return { data: null, error: parsed.error, count };
    let data = parsed.data;
    if (this.mode === 'maybeSingle' && Array.isArray(data)) {
      if (data.length > 1) {
        return { data: null, error: failure('JSON object requested, multiple (or no) rows returned', 'PGRST116', `Results contain ${data.length} rows`), count: null };
      }
      data = data[0] ?? null;
    }
    return { data, error: null, count };
  }

  then<A = RestResult, B = never>(
    onfulfilled?: ((value: RestResult) => A | PromiseLike<A>) | null,
    onrejected?: ((reason: unknown) => B | PromiseLike<B>) | null,
  ): PromiseLike<A | B> { return this.run().then(onfulfilled, onrejected); }
}

export class StorageBucket {
  private readonly client: RestClient;
  private readonly bucket: string;
  constructor(client: RestClient, bucket: string) { this.client = client; this.bucket = bucket; }

  private objectPath(path: string): string {
    return [this.bucket, ...path.split('/')].map(encodeURIComponent).join('/');
  }

  async upload(path: string, body: Uint8Array | ArrayBuffer | Blob | string, options: { contentType?: string; upsert?: boolean } = {}): Promise<RestResult<{ path: string }>> {
    try {
      const response = await fetch(`${this.client.url}/storage/v1/object/${this.objectPath(path)}`, {
        method: 'POST',
        headers: {
          ...this.client.baseHeaders(),
          'Content-Type': options.contentType ?? 'application/octet-stream',
          'Cache-Control': 'max-age=3600',
          'x-upsert': String(options.upsert ?? false),
        },
        body: body as BodyInit, redirect: 'error', signal: AbortSignal.timeout(this.client.timeoutMs),
      });
      if (!response.ok) return { data: null, error: await readError(response), count: null };
      return { data: { path }, error: null, count: null };
    } catch (error) { return { data: null, error: networkError(error), count: null }; }
  }

  async createSignedUrl(path: string, expiresIn: number): Promise<RestResult<{ signedUrl: string }>> {
    try {
      const response = await fetch(`${this.client.url}/storage/v1/object/sign/${this.objectPath(path)}`, {
        method: 'POST',
        headers: { ...this.client.baseHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn }), redirect: 'error', signal: AbortSignal.timeout(this.client.timeoutMs),
      });
      if (!response.ok) return { data: null, error: await readError(response), count: null };
      const answer = await response.json().catch(() => null);
      if (!answer || typeof answer.signedURL !== 'string') return { data: null, error: failure('Signed URL missing from the answer'), count: null };
      return { data: { signedUrl: `${this.client.url}/storage/v1${answer.signedURL}` }, error: null, count: null };
    } catch (error) { return { data: null, error: networkError(error), count: null }; }
  }
}

export class RestClient {
  readonly url: string;
  readonly timeoutMs: number;
  private readonly key: string;
  private readonly options: RestOptions;
  constructor(url: string, key: string, options: RestOptions = {}) {
    this.key = key;
    this.options = options;
    this.url = url.replace(/\/+$/, '');
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }
  baseHeaders(): Record<string, string> {
    return { apikey: this.key, Authorization: this.options.authorization ?? `Bearer ${this.key}` };
  }
  from(table: string): Builder { return new Builder(this, table); }
  async rpc(name: string, args: Record<string, unknown> = {}): Promise<RestResult> {
    try {
      const response = await fetch(`${this.url}/rest/v1/rpc/${encodeURIComponent(name)}`, {
        method: 'POST', headers: { ...this.baseHeaders(), 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(args), redirect: 'error', signal: AbortSignal.timeout(this.timeoutMs),
      });
      if (!response.ok) return { data: null, error: await readError(response), count: null };
      const parsed = parseBody(await response.text());
      return { data: parsed.data, error: parsed.error, count: null };
    } catch (error) { return { data: null, error: networkError(error), count: null }; }
  }
  readonly storage = { from: (bucket: string) => new StorageBucket(this, bucket) };
}

/** `url` is the internal API address (SUPABASE_URL); `key` the anon or service-role key. */
export const restClient = (url: string, key: string, options: RestOptions = {}): RestClient => new RestClient(url, key, options);
