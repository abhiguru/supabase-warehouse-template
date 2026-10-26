// Which locally built images are out of date with their recipes.
//
//   docker compose ... config --format json | node image-recipes.mjs plan RECORD [--all]
//     prints one line per image to build: "<service>\t<fingerprint>\t<image>\t<reason>"
//   node image-recipes.mjs record RECORD <service>=<fingerprint>=<image> ...
//     stores the fingerprint and the image ID of each image that was just built
//   docker compose ... config --format json | node image-recipes.mjs optional
//     prints the optional services (those behind a profile) that are running
//   node image-recipes.mjs adopt RECORD SAVED_RECORD
//     for each line of SAVED_RECORD (the copy build-images.sh keeps next to its saved image tarballs) whose image ID
//     exists on this host, writes that line into RECORD; restore-host.sh runs it after `docker load`, so the loaded
//     images count as built by this project and are not built again
//
// A recipe is a service's build context (every file below it), its Dockerfile
// path, build target and build arguments. RECORD is a private file in the
// operator state: "<fingerprint>  <service>  <image id>" per line. An image is
// current when its recipe has the recorded fingerprint and its tag still names
// the recorded image; a tag moved by anything else (a manual build, a build
// that failed half way) is built again. No built service names its image, so
// Compose tags each `<project>-<service>` and installations never share a tag. One service runs another's image: gateway-lan names
// `<project>-gateway` and has no `build` of its own, so it has no recipe here, is never built or recorded twice, and follows the gateway.
// scripts/build-images.sh is the only caller: `plan` before a build, and again
// in --replace-optional to leave alone a running optional service whose image
// does not match this checkout.
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, readlinkSync, lstatSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

const SERVICE = '[a-zA-Z0-9][a-zA-Z0-9._-]*';
const LAN_SERVICE = 'gateway-lan';
const [mode, ...rest] = process.argv.slice(2);
const recordPath = mode === 'optional' ? '' : rest.shift();
const savedPath = mode === 'adopt' ? rest.shift() : '';
if (!['plan', 'record', 'optional', 'adopt'].includes(mode) || (mode !== 'optional' && !recordPath) || (mode === 'adopt' && !savedPath)) {
  console.error('Usage: image-recipes.mjs plan RECORD [--all] | record RECORD service=fingerprint=image ... | optional | adopt RECORD SAVED_RECORD');
  process.exit(2);
}
const fail = message => { console.error(message); process.exit(1); };

function readRecord(path = recordPath) {
  const record = new Map();
  if (!existsSync(path)) return record;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = new RegExp(`^([0-9a-f]{64}) {2}(${SERVICE})(?: {2}(sha256:[0-9a-f]{64}))?$`).exec(line);
    if (match) record.set(match[2], { fingerprint: match[1], id: match[3] ?? '' });
  }
  return record;
}

function writeRecord(record) {
  const body = [...record].sort(([a], [b]) => a.localeCompare(b))
    .map(([service, { fingerprint, id }]) => `${fingerprint}  ${service}${id ? `  ${id}` : ''}\n`).join('');
  const temporary = `${recordPath}.tmp-${process.pid}`;
  writeFileSync(temporary, body, { mode: 0o600 });
  renameSync(temporary, recordPath);
}

// Every file below the context, by path, type, executable bit and content.
function fingerprint(service, build) {
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
  try {
    walk(build.context, '');
  } catch (error) {
    fail(`Cannot read the build recipe of the ${service} image: ${error.message}`);
  }
  hash.update(`dockerfile\0${build.dockerfile ?? 'Dockerfile'}\n`);
  hash.update(`target\0${build.target ?? ''}\n`);
  hash.update(`args\0${JSON.stringify(Object.entries(build.args ?? {}).sort())}\n`);
  return hash.digest('hex');
}

function imageId(image) {
  const result = spawnSync('docker', ['image', 'inspect', '--format', '{{.Id}}', image], { encoding: 'utf8' });
  return result.status === 0 ? result.stdout.trim() : '';
}

// The services of this Compose project that have a container; `running` leaves out stopped ones.
function containerServices(project, { running }) {
  const result = spawnSync('docker', ['ps', ...(running ? [] : ['-a']), '--filter', `label=com.docker.compose.project=${project}`,
    '--format', '{{.Label "com.docker.compose.service"}}'], { encoding: 'utf8' });
  if (result.status !== 0) fail(`Cannot list the containers of ${project}: ${result.stderr.trim()}`);
  return new Set(result.stdout.split('\n').filter(Boolean));
}

function readConfig() {
  try {
    const config = JSON.parse(readFileSync(0, 'utf8'));
    if (typeof config.name !== 'string' || typeof config.services !== 'object') throw new Error('no project name or services');
    return config;
  } catch (error) {
    return fail(`Cannot read the Compose configuration: ${error.message}`);
  }
}
const sorted = services => Object.entries(services).sort(([a], [b]) => a.localeCompare(b));
const optional = definition => (definition.profiles ?? []).length > 0;

if (mode === 'record') {
  const record = readRecord();
  for (const item of rest) {
    const match = new RegExp(`^(${SERVICE})=([0-9a-f]{64})=(.+)$`).exec(item);
    if (!match) fail(`Not a service=fingerprint=image item: ${item}`);
    const id = imageId(match[3]);
    if (!id) fail(`The ${match[1]} image (${match[3]}) does not exist after its build.`);
    record.set(match[1], { fingerprint: match[2], id });
  }
  writeRecord(record);
} else if (mode === 'adopt') {
  // Only a line that names an image ID this host has: a tarball that failed to load, or an older one than the record,
  // leaves its service to be built.
  const record = readRecord();
  for (const [service, saved] of readRecord(savedPath)) {
    if (!saved.id || imageId(saved.id) !== saved.id) continue;
    record.set(service, saved);
    console.log(`adopted ${service}`);
  }
  writeRecord(record);
} else if (mode === 'optional') {
  const config = readConfig();
  const running = containerServices(config.name, { running: true });
  for (const [service, definition] of sorted(config.services)) {
    // gateway-lan (the LAN fallback) runs the gateway's image and is started, and replaced when its definition changed, by scripts/lan.sh
    // start: it is not part of the replace-optional step, whose failure would then be the fallback's failure counted twice.
    if (service === LAN_SERVICE) continue;
    if (optional(definition) && running.has(service)) process.stdout.write(`${service}\n`);
  }
} else {
  const all = rest.includes('--all');
  const config = readConfig();
  const record = readRecord();
  const used = containerServices(config.name, { running: false });
  for (const [service, definition] of sorted(config.services)) {
    if (!definition.build?.context) continue;
    // An optional service (one behind a profile) is rebuilt only where this
    // installation has a container of it. An image alone does not show use:
    // the checks and the image scan build images that are never started.
    if (optional(definition) && !used.has(service)) continue;
    const image = definition.image ?? `${config.name}-${service}`;
    const id = imageId(image);
    const current = fingerprint(service, definition.build);
    const known = record.get(service);
    const reason = !id ? 'image missing'
      : all ? 'requested'
        : !known ? 'no build record'
          : known.fingerprint !== current ? 'recipe changed'
            : known.id && known.id !== id ? 'image was replaced by something else' : '';
    if (reason) process.stdout.write(`${service}\t${current}\t${image}\t${reason}\n`);
  }
}
