export async function readBoundedJson(req: Request, maxBytes = 2048): Promise<Record<string, unknown>> {
  const declaredLength = Number(req.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) throw new RangeError('Request too large');
  const reader = req.body?.getReader();
  if (!reader) throw new SyntaxError('JSON body required');
  const chunks: Uint8Array[] = [];
  let received = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > maxBytes) {
        await reader.cancel();
        throw new RangeError('Request too large');
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new SyntaxError('JSON object required');
  return body;
}
