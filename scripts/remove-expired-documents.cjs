// Deletes the objects named on standard input (one per line) from the private
// documents bucket through the Storage API, which removes the stored file and
// its catalog row together. Deleting the storage.objects row in SQL would leave
// the file on disk. scripts/retention.sh runs this inside the storage container
// (`node -e`), where SERVICE_KEY is already set, so the key never leaves it.
const http = require('node:http');

const base = new URL(process.env.STORAGE_API_URL || 'http://storage:5000');
const key = process.env.SERVICE_KEY || '';
const bucket = 'documents';
const batchSize = 100;

function remove(names) {
  const body = JSON.stringify({ prefixes: names });
  return new Promise((resolve, reject) => {
    const request = http.request({
      hostname: base.hostname, port: base.port || 80, method: 'DELETE', path: `/object/${bucket}`,
      headers: { Authorization: `Bearer ${key}`, apikey: key, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 60000,
    }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        if (response.statusCode !== 200) return reject(new Error(`Storage API answered HTTP ${response.statusCode}`));
        try {
          const removed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
          if (!Array.isArray(removed)) throw new Error('not a list');
          resolve(removed.length);
        } catch { reject(new Error('Storage API answer was not a list of removed objects')); }
      });
    });
    request.on('timeout', () => request.destroy(new Error('Storage API did not answer in 60 seconds')));
    request.on('error', reject);
    request.end(body);
  });
}

async function main() {
  if (!key) throw new Error('SERVICE_KEY is not set in this container');
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const names = Buffer.concat(chunks).toString('utf8').split('\n').map(name => name.trim()).filter(Boolean);
  let removed = 0;
  for (let start = 0; start < names.length; start += batchSize) {
    removed += await remove(names.slice(start, start + batchSize));
  }
  console.log(`Generated documents removed from storage: ${removed} of ${names.length}`);
}

main().catch(error => { console.error(`Document removal failed: ${error.message}`); process.exit(1); });
