// Bound allocations before parsing untrusted document requests, including streams
// without Content-Length. Never echo their contents in errors.
export async function documentRequestBody(req: Request, limit = 4096): Promise<unknown> {
  if (Number(req.headers.get('Content-Length')) > limit) throw { status: 400, message: 'Request too large' };
  const reader = req.body?.getReader();
  if (!reader) throw { status: 400, message: 'Invalid JSON' };
  const chunks: Uint8Array[] = [];
  let size = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const read = async () => {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > limit) throw { status: 400, message: 'Request too large' };
        chunks.push(value);
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      try { return JSON.parse(new TextDecoder().decode(bytes)); }
      catch { throw { status: 400, message: 'Invalid JSON' }; }
    };
    return await Promise.race([read(), new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject({ status: 400, message: 'Request timed out' }), 15000);
    })]);
  } finally { clearTimeout(timer); void reader.cancel().catch(() => {}); }
}
