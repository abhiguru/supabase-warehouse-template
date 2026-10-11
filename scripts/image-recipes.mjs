// Which locally built images are out of date with their recipes.
//
//   docker compose ... config --format json | node image-recipes.mjs plan RECORD [--all]
//     prints one line per image to build: "<service>\t<fingerprint>\t<reason>"
//   node image-recipes.mjs record RECORD <service>=<fingerprint> ...
//     stores the fingerprints of the images that were just built
//
// A recipe is a service's build context (every file below it), its Dockerfile
// path, build target and build arguments. RECORD is a private file in the
// operator state: "<fingerprint>  <service>" per line, like sha256sum output.
// scripts/build-images.sh is the only caller.
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, readlinkSync, lstatSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const [mode, recordPath, ...rest] = process.argv.slice(2);
if (!recordPath || !['plan', 'record'].includes(mode)) {
  console.error('Usage: image-recipes.mjs plan RECORD [--all] < compose-config.json | image-recipes.mjs record RECORD service=fingerprint ...');
  process.exit(2);
}

function readRecord() {
  const record = new Map();
  if (!existsSync(recordPath)) return record;
  for (const line of readFileSync(recordPath, 'utf8').split('\n')) {
    const match = /^([0-9a-f]{64}) {2}([a-z0-9][a-z0-9_-]*)$/.exec(line);
    if (match) record.set(match[2], match[1]);
  }
  return record;
}

function writeRecord(record) {
  const body = [...record].sort(([a], [b]) => a.localeCompare(b)).map(([service, hash]) => `${hash}  ${service}\n`).join('');
  const temporary = `${recordPath}.tmp-${process.pid}`;
  writeFileSync(temporary, body, { mode: 0o600 });
  renameSync(temporary, recordPath);
}

// Every file below the context, by path, type, executable bit and content.
function fingerprint(build) {
  const hash = createHash('sha256');
  const walk = (dir, prefix) => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name);
      const relative = prefix ? `${prefix}/${name}` : name;
      const stat = lstatSync(path);
      if (stat.isSymbolicLink()) hash.update(`l\0${relative}\0${readlinkSync(path)}\n`);
      else if (stat.isDirectory()) { hash.update(`d\0${relative}\n`); walk(path, relative); }
      else if (stat.isFile()) {
        const content = createHash('sha256').update(readFileSync(path)).digest('hex');
        hash.update(`f\0${relative}\0${stat.mode & 0o111 ? 'x' : '-'}\0${content}\n`);
      }
    }
  };
  walk(build.context, '');
  hash.update(`dockerfile\0${build.dockerfile ?? 'Dockerfile'}\n`);
  hash.update(`target\0${build.target ?? ''}\n`);
  hash.update(`args\0${JSON.stringify(Object.entries(build.args ?? {}).sort())}\n`);
  return hash.digest('hex');
}

const imageExists = image => spawnSync('docker', ['image', 'inspect', '--format', '{{.Id}}', image], { stdio: 'ignore' }).status === 0;

if (mode === 'record') {
  const record = readRecord();
  for (const pair of rest) {
    const match = /^([a-z0-9][a-z0-9_-]*)=([0-9a-f]{64})$/.exec(pair);
    if (!match) { console.error(`Not a service=fingerprint pair: ${pair}`); process.exit(2); }
    record.set(match[1], match[2]);
  }
  writeRecord(record);
} else {
  const all = rest.includes('--all');
  const config = JSON.parse(readFileSync(0, 'utf8'));
  const record = readRecord();
  for (const [service, definition] of Object.entries(config.services ?? {}).sort(([a], [b]) => a.localeCompare(b))) {
    if (!definition.build?.context) continue;
    const exists = imageExists(definition.image ?? `${config.name}-${service}`);
    // An optional service (one behind a profile) is rebuilt only where it is in
    // use, which shows as an existing image. The others are built on first use.
    if ((definition.profiles ?? []).length > 0 && !exists) continue;
    const current = fingerprint(definition.build);
    const reason = !exists ? 'image missing'
      : all ? 'requested'
        : !record.has(service) ? 'no build record'
          : record.get(service) !== current ? 'recipe changed' : '';
    if (reason) process.stdout.write(`${service}\t${current}\t${reason}\n`);
  }
}
