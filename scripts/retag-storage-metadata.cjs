// Sets the extended attributes the Storage service reads its per-file metadata from, for every object named on
// standard input: user.supabase.content-type and user.supabase.cache-control, from the catalog (storage.objects.metadata:
// mimetype and cacheControl). The file backend of storage-api v1.80.2 (dist/storage/backend/file.js) keeps both in these
// attributes and serves application/octet-stream and no-cache for a file that has none, which is what every file looks
// like after a restore from a v5 backup (its tarball never saved attributes) or after the earlier PostgreSQL moves, which
// were in-place restores. scripts/storage-retag.sh runs this inside the storage container (`node -e`), where the module
// fs-xattr that the Storage service itself uses is installed (docker/storage/package.json), and feeds it one JSON object per
// line, {"path":"<bucket>/<name>/<version>","mimetype":...,"cacheControl":...}. Run it again at any time: a file whose
// attributes already hold the catalog's values is left alone.
//
// Environment (the container's own): FILE_STORAGE_BACKEND_PATH (default /var/lib/storage), GLOBAL_S3_BUCKET and TENANT_ID
// (both "stub" in this stack): a file lives at <FILE_STORAGE_BACKEND_PATH>/<GLOBAL_S3_BUCKET>/<TENANT_ID>/<bucket>/<name>[/<version>].
//
// With the argument `probe` (node -e SCRIPT probe) it only looks: it reads the same lines, takes up to PROBE_FILES of the catalogued
// files that exist, spread over the whole list, and exits 10 when any of them has no content type attribute, else 0. Nothing is
// written. scripts/storage-retag.sh --if-missing (run by scripts/restore.sh after every restore) uses it to decide whether to
// set the attributes of every file.
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const root = path.resolve(process.env.FILE_STORAGE_BACKEND_PATH || '/var/lib/storage');
const base = path.join(root, process.env.GLOBAL_S3_BUCKET || 'stub', process.env.TENANT_ID || 'stub');
const ATTRIBUTES = [['mimetype', 'user.supabase.content-type'], ['cacheControl', 'user.supabase.cache-control']];
const xattr = require('fs-xattr');
const PROBE_FILES = 20;
const PROBE_MISSING = 10;
const probing = process.argv[1] === 'probe';

const counts = { updated: 0, unchanged: 0, missing: 0, withoutMetadata: 0, errors: 0 };
const problems = [];

function current(file, attribute) {
  try { return xattr.getAttributeSync(file, attribute).toString(); } catch (error) {
    if (error && (error.code === 'ENODATA' || error.code === 'ENOATTR')) return undefined;
    throw error;
  }
}

function retag(entry) {
  if (!entry || typeof entry.path !== 'string' || entry.path === '') throw new Error('line without a path');
  const wanted = ATTRIBUTES.filter(([key]) => typeof entry[key] === 'string' && entry[key] !== '');
  if (wanted.length === 0) { counts.withoutMetadata++; return; }
  const file = path.resolve(base, entry.path);
  if (!file.startsWith(base + path.sep)) throw new Error(`${entry.path}: outside the storage directory`);
  let stat;
  try { stat = fs.lstatSync(file); } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') { counts.missing++; return; }
    throw error;
  }
  if (!stat.isFile()) { counts.missing++; return; }
  let changed = false;
  for (const [key, attribute] of wanted) {
    if (current(file, attribute) === entry[key]) continue;
    xattr.setAttributeSync(file, attribute, entry[key]);
    changed = true;
  }
  if (changed) counts.updated++; else counts.unchanged++;
}

// The catalogued files that exist and have a content type in the catalog, in catalog order.
function probeCandidates(entries) {
  const found = [];
  for (const entry of entries) {
    if (!entry || typeof entry.path !== 'string' || entry.path === '' || typeof entry.mimetype !== 'string' || entry.mimetype === '') continue;
    const file = path.resolve(base, entry.path);
    if (!file.startsWith(base + path.sep)) continue;
    let stat;
    try { stat = fs.lstatSync(file); } catch { continue; }
    if (stat.isFile()) found.push(file);
  }
  return found;
}

async function probe() {
  const entries = [];
  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    if (line.trim() === '') continue;
    try { entries.push(JSON.parse(line)); } catch { /* not a catalog line */ }
  }
  const files = probeCandidates(entries);
  const count = Math.min(PROBE_FILES, files.length);
  const sample = [];
  for (let i = 0; i < count; i++) sample.push(files[Math.floor(i * files.length / count)]);
  const lacking = sample.filter(file => current(file, 'user.supabase.content-type') === undefined).length;
  console.log(`Storage metadata check: ${lacking} of ${sample.length} sampled files have no content type.`);
  if (lacking) process.exit(PROBE_MISSING);
}

async function main() {
  if (probing) return probe();
  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  let number = 0;
  for await (const line of lines) {
    number++;
    if (line.trim() === '') continue;
    try { retag(JSON.parse(line)); } catch (error) {
      counts.errors++;
      if (problems.length < 5) problems.push(`line ${number}: ${error.message}`);
    }
  }
  console.log(`Storage metadata set from the catalog: ${counts.updated} files updated, ${counts.unchanged} already correct, ` +
    `${counts.missing} catalogued but not on disk, ${counts.withoutMetadata} without catalog metadata, ${counts.errors} errors.`);
  for (const problem of problems) console.error(problem);
  if (counts.errors) process.exit(1);
}

main().catch(error => { console.error(`Storage metadata update failed: ${error.message}`); process.exit(1); });
