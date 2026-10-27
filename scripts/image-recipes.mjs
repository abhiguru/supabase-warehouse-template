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
//   docker compose ... config --format json | node image-recipes.mjs fingerprints
//     prints "<service>\t<fingerprint>\t<image>" for every service that has a recipe, optional ones included
//     (scripts/publish-images.sh)
//   docker compose ... config --format json | node image-recipes.mjs manifest RELEASE COMMIT <service>=<reference> ...
//     prints release-images.json: the release, its commit and, for every recipe, the published image
//     (ghcr.io/abhiguru/supabase-warehouse-template/<service>@sha256:...) with the recipe's fingerprint (scripts/publish-images.sh)
//   node image-recipes.mjs release-select RELEASE_IMAGES_JSON TAG COMMIT <service>=<fingerprint> ...
//     checks a release-images.json that was downloaded for TAG against this checkout's COMMIT and, for each service named,
//     prints "pull\t<service>\t<reference>" when the release holds an image of the same recipe, or
//     "build\t<service>\t<why not>"; exits 1 with the reason when the file cannot be used at all (scripts/build-images.sh --from-release)
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
// The release workflow pushes here (scripts/publish-images.sh) and a facility pulls from here (scripts/build-images.sh --from-release).
// A reference to any other place is refused, whatever release-images.json says.
const REGISTRY = 'ghcr.io/abhiguru/supabase-warehouse-template';
const PUBLISHED_REFERENCE = new RegExp(`^${REGISTRY.replace(/[./]/g, '\\$&')}/([a-z0-9][a-z0-9-]*)@(sha256:[0-9a-f]{64})$`);
const [mode, ...rest] = process.argv.slice(2);
// These take no record file.
const WITHOUT_RECORD = ['optional', 'fingerprints', 'manifest', 'release-select'];
const recordPath = WITHOUT_RECORD.includes(mode) ? '' : rest.shift();
const savedPath = mode === 'adopt' ? rest.shift() : '';
if (!['plan', 'record', 'adopt', ...WITHOUT_RECORD].includes(mode) || (!WITHOUT_RECORD.includes(mode) && !recordPath) || (mode === 'adopt' && !savedPath)) {
  console.error('Usage: image-recipes.mjs plan RECORD [--all] | record RECORD service=fingerprint=image ... | optional | adopt RECORD SAVED_RECORD | fingerprints | manifest RELEASE COMMIT service=reference ... | release-select FILE TAG COMMIT service=fingerprint ...');
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
// The record format without the image ID: what release-images.json commits to. A consistency check only (a truncated or carelessly edited
// file is noticed): anyone can recompute it, so it is not integrity; the trust in the file is described in docs/CONTAINER_SECURITY.md.
const recipesHash = images => createHash('sha256')
  .update(Object.entries(images).sort(([a], [b]) => a.localeCompare(b)).map(([service, { fingerprint: value }]) => `${value}  ${service}\n`).join('')).digest('hex');

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
} else if (mode === 'fingerprints') {
  const config = readConfig();
  for (const [service, definition] of sorted(config.services)) {
    if (!definition.build?.context) continue;
    process.stdout.write(`${service}\t${fingerprint(service, definition.build)}\t${definition.image ?? `${config.name}-${service}`}\n`);
  }
} else if (mode === 'manifest') {
  const [release, commit, ...items] = rest;
  if (!release || !/^[0-9a-f]{40}$/.test(commit ?? '')) fail('Usage: image-recipes.mjs manifest RELEASE COMMIT service=reference ... (COMMIT is the 40-digit commit of the release)');
  const references = new Map();
  for (const item of items) {
    const match = new RegExp(`^(${SERVICE})=(.+)$`).exec(item);
    if (!match) fail(`Not a service=reference item: ${item}`);
    references.set(match[1], match[2]);
  }
  const images = {};
  for (const [service, definition] of sorted(readConfig().services)) {
    if (!definition.build?.context) continue;
    const reference = references.get(service);
    if (!reference) fail(`No published image was given for the ${service} recipe.`);
    if (PUBLISHED_REFERENCE.exec(reference)?.[1] !== service) fail(`Not a ${REGISTRY}/${service}@sha256:<digest> reference: ${reference}`);
    images[service] = { ref: reference, fingerprint: fingerprint(service, definition.build) };
    references.delete(service);
  }
  if (references.size) fail(`Published images were given for services without a recipe: ${[...references.keys()].join(', ')}`);
  if (!Object.keys(images).length) fail('The Compose configuration has no recipe to publish.');
  process.stdout.write(`${JSON.stringify({ release, commit, recipes: recipesHash(images), images }, null, 2)}\n`);
} else if (mode === 'release-select') {
  // The file came over the network: nothing in it is used before it has been checked against this checkout.
  const [file, tag, commit, ...wanted] = rest;
  if (!file || !tag || !/^[0-9a-f]{40}$/.test(commit ?? '')) fail('Usage: image-recipes.mjs release-select FILE TAG COMMIT service=fingerprint ...');
  let manifest;
  try { manifest = JSON.parse(readFileSync(file, 'utf8')); } catch (error) { fail(`release-images.json cannot be read: ${error.message}`); }
  const unusable = reason => fail(`release-images.json is not usable: ${reason}`);
  if (manifest?.release !== tag) unusable(`it is for release ${JSON.stringify(manifest?.release ?? null)}, not ${tag}`);
  if (manifest.commit !== commit) unusable(`it names commit ${JSON.stringify(manifest.commit ?? null)}, and this checkout is at ${commit}`);
  const entries = manifest.images && typeof manifest.images === 'object' && !Array.isArray(manifest.images) ? Object.entries(manifest.images) : [];
  if (!entries.length) unusable('it lists no image');
  const images = new Map();
  for (const [service, entry] of entries) {
    if (typeof entry?.ref !== 'string' || PUBLISHED_REFERENCE.exec(entry.ref)?.[1] !== service) unusable(`the reference of ${service} is not ${REGISTRY}/${service}@sha256:<digest>`);
    if (!/^[0-9a-f]{64}$/.test(entry?.fingerprint ?? '')) unusable(`the recipe fingerprint of ${service} is not a SHA-256`);
    images.set(service, entry);
  }
  if (manifest.recipes !== recipesHash(manifest.images)) unusable('its recipes hash does not match the images it lists');
  for (const item of wanted) {
    const match = new RegExp(`^(${SERVICE})=([0-9a-f]{64})$`).exec(item);
    if (!match) fail(`Not a service=fingerprint item: ${item}`);
    const entry = images.get(match[1]);
    if (!entry) process.stdout.write(`build\t${match[1]}\tthe release has no image of it\n`);
    else if (entry.fingerprint !== match[2]) process.stdout.write(`build\t${match[1]}\tits recipe differs from the release's (a file below its docker directory is not as released)\n`);
    else process.stdout.write(`pull\t${match[1]}\t${entry.ref}\n`);
  }
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
