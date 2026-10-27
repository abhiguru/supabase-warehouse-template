// Whether two instance.json files describe the same facility. An in-place restore (scripts/restore.sh) replaces the database and
// the files of the instance that produced the backup, so what must match is the identity: instanceId, canonicalOrigin and
// companyName (the three configure.mjs refuses to change on a rerun). Everything else in the manifest may have moved since the
// backup was taken: capabilities (scripts/set-capability.mjs), supportedApiVersions, displayName, and the minimumClientVersion that
// older releases kept there. A byte comparison refused those restores.
//
//   node scripts/instance-identity.mjs compare <backup instance.json> <state instance.json>
//
// Exit 0: same identity. Exit 1: a different one (the differing field names are printed). Exit 2: a file cannot be read or is not a manifest.
import { readFileSync } from 'node:fs';
import { isMain } from './is-main.mjs';

export const IDENTITY_FIELDS = ['instanceId', 'canonicalOrigin', 'companyName'];

function identityOf(path) {
  let manifest;
  try { manifest = JSON.parse(readFileSync(path, 'utf8')); } catch { throw new Error(`${path} cannot be read as JSON.`); }
  if (typeof manifest?.instanceId !== 'string' || !manifest.instanceId) throw new Error(`${path} has no instanceId.`);
  // A field one file lacks differs from the other's; both lacking it is no difference (doctor.mjs checks the live manifest is complete).
  return Object.fromEntries(IDENTITY_FIELDS.map(field => [field, manifest[field] ?? null]));
}

export function differingFields(left, right) {
  const a = identityOf(left);
  const b = identityOf(right);
  return IDENTITY_FIELDS.filter(field => a[field] !== b[field]);
}

if (isMain(import.meta.url)) {
  try {
    if (process.argv[2] !== 'compare' || process.argv.length !== 5) throw Object.assign(new Error('Usage: node scripts/instance-identity.mjs compare <instance.json> <instance.json>'), { code: 2 });
    const differing = differingFields(process.argv[3], process.argv[4]);
    if (differing.length) { console.log(differing.join(' ')); process.exit(1); }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(2);
  }
}
