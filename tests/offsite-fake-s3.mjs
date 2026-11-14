// A small stand-in for an S3-compatible bucket server, for tests/offsite.test.mjs (WH-145). It speaks the few calls rclone makes for
// scripts/offsite.sh: put, get, head and delete of one object, the multi-object delete, and the version 2 listing with a prefix and a
// delimiter. It checks the access key id (the "Credential=<id>/" part of the Authorization header) and, when given secretKey, the SigV4 signature, so a
// test can see a wrong key or a wrong secret refused with 403. It keeps every object in memory and records every request
// (method, path, authorization header) so that a test can look for secrets on the wire. Loopback only; no real storage is involved.
import { createServer } from 'node:http';
import { createHash, createHmac } from 'node:crypto';
const hmac = (key, data) => createHmac('sha256', key).update(data).digest();
// SigV4 as the AWS SDK and rclone compute it for a path-style request (single encoding of the path, query sorted by name).
function signatureMatches(req, secret) {
  const m = /Credential=([^/]+)\/(\d{8})\/([^/]+)\/s3\/aws4_request, SignedHeaders=([^,]+), Signature=([0-9a-f]{64})/.exec(String(req.headers.authorization ?? ''));
  if (!m) return false;
  const [, , date, region, signed, signature] = m;
  const [path, query = ''] = req.url.split('?');
  const canonicalQuery = query ? query.split('&').map(p => (p.includes('=') ? p : `${p}=`)).sort().join('&') : '';
  const headers = signed.split(';').map(h => `${h}:${String(req.headers[h] ?? '').trim().replace(/\s+/g, ' ')}\n`).join('');
  const canonical = [req.method, path, canonicalQuery, headers, signed, req.headers['x-amz-content-sha256'] ?? 'UNSIGNED-PAYLOAD'].join('\n');
  const scope = `${date}/${region}/s3/aws4_request`;
  const toSign = ['AWS4-HMAC-SHA256', req.headers['x-amz-date'], scope, createHash('sha256').update(canonical).digest('hex')].join('\n');
  const key = hmac(hmac(hmac(hmac(`AWS4${secret}`, date), region), 's3'), 'aws4_request');
  return hmac(key, toSign).toString('hex') === signature;
}
const md5 = body => createHash('md5').update(body).digest('hex');
const etagOf = o => `"${md5(o.body)}"`;

export async function startFakeS3({ accessKey = 'FAKEACCESSKEY01', secretKey = null, bucket = 'warehouse-offsite-test' } = {}) {
  const objects = new Map();      // key -> { body: Buffer, modified: Date }
  const requests = [];
  const behaviour = { refuse: null, quotaFull: false };   // refuse: a status to answer every request with; quotaFull: refuse puts with 403 QuotaExceeded
  const xml = body => `<?xml version="1.0" encoding="UTF-8"?>\n${body}`;
  const esc = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const reply = (res, status, body = '', headers = {}) => { res.writeHead(status, { 'content-length': Buffer.byteLength(body), ...headers }); res.end(body); };
  const error = (res, status, code, message) => reply(res, status, xml(`<Error><Code>${code}</Code><Message>${message}</Message></Error>`), { 'content-type': 'application/xml' });
  // The body of a put: plain, or in aws-chunked framing ("<hex>;chunk-signature=...\r\n<data>\r\n ... 0;...\r\n<trailers>").
  const decodeChunked = raw => {
    const parts = [];
    let at = 0;
    for (;;) {
      const end = raw.indexOf('\r\n', at);
      if (end < 0) break;
      const size = parseInt(raw.subarray(at, end).toString('latin1').split(';')[0], 16);
      if (!Number.isFinite(size) || size === 0) break;
      parts.push(raw.subarray(end + 2, end + 2 + size));
      at = end + 2 + size + 2;
    }
    return Buffer.concat(parts);
  };
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks);
      const url = new URL(req.url, 'http://127.0.0.1');
      const path = decodeURIComponent(url.pathname).replace(/^\/+/, '');
      const authorization = String(req.headers.authorization ?? '');
      requests.push({ method: req.method, path, query: url.search, authorization, headers: req.headers });
      if (behaviour.refuse) return error(res, behaviour.refuse, 'Refused', 'refused by the test');
      const id = /Credential=([^/]+)\//.exec(authorization)?.[1];
      if (id !== accessKey) return error(res, 403, 'InvalidAccessKeyId', 'The access key id you provided does not exist');
      if (secretKey && !signatureMatches(req, secretKey)) return error(res, 403, 'SignatureDoesNotMatch', 'The request signature we calculated does not match');
      const [, key = ''] = /^[^/]+\/?(.*)$/.exec(path) ?? [];
      if (path.split('/')[0] !== bucket) return error(res, 404, 'NoSuchBucket', 'The specified bucket does not exist');
      if (req.method === 'POST' && url.searchParams.has('delete')) {
        const keys = [...raw.toString('utf8').matchAll(/<Key>([^<]*)<\/Key>/g)].map(m => m[1].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'));
        for (const k of keys) objects.delete(k);
        return reply(res, 200, xml(`<DeleteResult>${keys.map(k => `<Deleted><Key>${esc(k)}</Key></Deleted>`).join('')}</DeleteResult>`), { 'content-type': 'application/xml' });
      }
      if (req.method === 'GET' && !key) {
        const prefix = url.searchParams.get('prefix') ?? '';
        const delimiter = url.searchParams.get('delimiter') ?? '';
        const contents = [];
        const prefixes = new Set();
        for (const [k, o] of [...objects].sort(([a], [b]) => (a < b ? -1 : 1))) {
          if (!k.startsWith(prefix)) continue;
          const rest = k.slice(prefix.length);
          if (delimiter && rest.includes(delimiter)) { prefixes.add(prefix + rest.slice(0, rest.indexOf(delimiter) + 1)); continue; }
          contents.push(`<Contents><Key>${esc(k)}</Key><LastModified>${o.modified.toISOString()}</LastModified><ETag>"${md5(o.body)}"</ETag><Size>${o.body.length}</Size><StorageClass>STANDARD</StorageClass></Contents>`);
        }
        return reply(res, 200, xml(`<ListBucketResult><Name>${bucket}</Name><Prefix>${esc(prefix)}</Prefix><KeyCount>${contents.length + prefixes.size}</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated>${contents.join('')}${[...prefixes].map(p => `<CommonPrefixes><Prefix>${esc(p)}</Prefix></CommonPrefixes>`).join('')}</ListBucketResult>`), { 'content-type': 'application/xml' });
      }
      if (req.method === 'PUT') {
        if (behaviour.quotaFull) return error(res, 403, 'QuotaExceeded', 'The bucket refused the upload');
        const body = /aws-chunked/.test(String(req.headers['content-encoding'] ?? '')) || /STREAMING/.test(String(req.headers['x-amz-content-sha256'] ?? '')) ? decodeChunked(raw) : raw;
        objects.set(key, { body, modified: new Date() });
        return reply(res, 200, '', { etag: etagOf({ body }) });
      }
      const object = objects.get(key);
      if (req.method === 'HEAD') {
        if (!object) { res.writeHead(404); return res.end(); }
        res.writeHead(200, { 'content-length': object.body.length, 'last-modified': object.modified.toUTCString(), etag: etagOf(object) });
        return res.end();
      }
      if (req.method === 'GET') {
        if (!object) return error(res, 404, 'NoSuchKey', 'The specified key does not exist.');
        res.writeHead(200, { 'content-length': object.body.length, 'last-modified': object.modified.toUTCString(), etag: etagOf(object), 'content-type': 'application/octet-stream' });
        return res.end(object.body);
      }
      if (req.method === 'DELETE') { objects.delete(key); res.writeHead(204); return res.end(); }
      return error(res, 405, 'MethodNotAllowed', 'not supported by the stand-in');
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    endpoint: `http://127.0.0.1:${server.address().port}`,
    bucket, accessKey, objects, requests, behaviour,
    close: () => new Promise(resolve => { server.closeAllConnections?.(); server.close(resolve); }),
  };
}
