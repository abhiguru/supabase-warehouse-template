#!/usr/bin/env node
// Watches the official base images this repository pins (FROM name:tag@sha256:... in docker/*/Dockerfile, image: lines in
// docker/docker-compose.yml) for the two ways a pin stops receiving patches without anything failing:
//
//   FAIL  the pinned variant has left the official-images library (docker-library/official-images, library/<name>): no tag
//         of the pin's line with the pin's variant is published any more (node dropped alpine3.23, nginx stopped 1.28,
//         python dropped slim-bookworm). Nothing breaks, the base simply gets no more updates.
//   WARN  Docker Hub shows the pinned tag last pushed more than 120 days ago, or no longer there: the variant is still
//         listed but is not being rebuilt, or the pin is a patch release that was never bumped.
//
//   node scripts/check-base-images.mjs     prints one OK/FAIL/WARN line per pin
//
//   Exit 0 nothing failed (a WARN line is still printed); 1 a pinned variant is gone; 2 something could not be read (the
//   library, or an answer of Docker Hub that is none of the cases below: another 4xx, a redirect, a 200 without a push
//   date), so a check did not run and nothing is known; 3 Docker Hub rate limits the age check (429), or answers 5xx or
//   times out twice in a row: the library check ran, the age check is incomplete, retry later. A variant that is gone (1)
//   is reported even when the age check could not run. The weekly workflow (base-images.yml) treats 3 as neutral and
//   2 as a failed run; only a 429 and a Docker Hub outage are neutral, so the age check cannot stop for good (Docker Hub
//   moving or retiring the endpoint) without the run turning red.
//
// "Line" is the part of the version that a release stream owns, because the library lists only the newest patch of each
// stream: node 24 (24.22.1 -> 24), postgres 18 (18.6 -> 18), python 3.15, nginx 1.30 (stable is even minors, mainline odd),
// ubuntu 22.04. A tag without a version (debian:bookworm-slim) must be listed exactly. Docker Hub is asked once per pinned
// tag (v2 API, about seven requests); the library files once per image name.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

export const OFFICIAL = ['node', 'nginx', 'python', 'postgres', 'debian', 'ubuntu', 'alpine'];
// How many leading numbers of a pinned version name its line; unlisted images use all of them.
export const LINE_PARTS = { node: 1, postgres: 1, debian: 1, python: 2, nginx: 2, ubuntu: 2, alpine: 2 };
export const MAX_AGE_DAYS = 120;
export const EXIT = { ok: 0, failed: 1, unreadable: 2, rateLimited: 3 };
const DAY = 86_400_000;
const LIBRARY_URL = name => `https://raw.githubusercontent.com/docker-library/official-images/master/library/${name}`;
const HUB_URL = (name, tag) => `https://hub.docker.com/v2/repositories/library/${name}/tags/${encodeURIComponent(tag)}`;

// "name:tag@sha256:..." -> { name, tag }, or undefined for a reference that holds a variable or names a stage.
function reference(text) {
  if (/[${}]/.test(text)) return undefined;
  const withoutDigest = text.replace(/@sha256:[0-9a-f]{64}$/, '');
  const colon = withoutDigest.lastIndexOf(':');
  const hasTag = colon > withoutDigest.lastIndexOf('/');
  // `library/node`, `docker.io/library/node` and `index.docker.io/library/node` all name the official image `node`.
  const name = (hasTag ? withoutDigest.slice(0, colon) : withoutDigest).replace(/^(?:(?:index\.)?docker\.io\/)?(?:library\/)?/, '');
  if (!/^[a-z0-9][a-z0-9._/-]*$/.test(name)) return undefined;
  return { name, tag: hasTag ? withoutDigest.slice(colon + 1) : '' };
}

// Every image a Dockerfile starts from (`FROM [--platform=...] ref [AS stage]`), the build stages excluded.
export function pinsFromDockerfile(text) {
  const stages = new Set();
  const pins = [];
  for (const line of text.split('\n')) {
    const match = /^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?\s*$/i.exec(line);
    if (!match) continue;
    const ref = stages.has(match[1]) ? undefined : reference(match[1]);
    if (match[2]) stages.add(match[2]);
    if (ref) pins.push(ref);
  }
  return pins;
}

// A service's `image:` (four spaces in); an `image` key deeper down (an environment variable, a label) is not a pin.
export function pinsFromCompose(text) {
  return [...text.matchAll(/^ {4}image:\s*["']?([^\s"']+)["']?\s*$/gm)].map(match => reference(match[1])).filter(Boolean);
}

// All pins of official-images library images below ROOT, each once, with the files that carry it.
export function collectPins(root) {
  const found = new Map();
  const add = (pins, file) => {
    for (const pin of pins.filter(item => OFFICIAL.includes(item.name))) {
      const key = `${pin.name}:${pin.tag}`;
      if (!found.has(key)) found.set(key, { ...pin, files: [] });
      found.get(key).files.push(file);
    }
  };
  const docker = join(root, 'docker');
  for (const dir of readdirSync(docker).sort()) {
    const file = join(docker, dir, 'Dockerfile');
    if (existsSync(file)) add(pinsFromDockerfile(readFileSync(file, 'utf8')), `docker/${dir}/Dockerfile`);
  }
  const compose = join(docker, 'docker-compose.yml');
  if (existsSync(compose)) add(pinsFromCompose(readFileSync(compose, 'utf8')), 'docker/docker-compose.yml');
  return [...found.values()];
}

// The tags (Tags: and SharedTags: lines) of a library file, as a Set. The file is RFC 2822 style: a line that starts with
// whitespace continues the field above it, and a tag list may be folded that way.
export function parseLibrary(text) {
  const tags = new Set();
  const add = value => { for (const tag of value.split(/[\s,]+/)) if (tag) tags.add(tag); };
  let inTags = false;
  for (const line of text.split('\n')) {
    const field = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line);
    if (field) { inTags = field[1] === 'Tags' || field[1] === 'SharedTags'; if (inTags) add(field[2]); }
    else if (inTags && /^\s+\S/.test(line)) add(line);
    else inTags = false;
  }
  return tags;
}

const escapeRegExp = text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Is the pin's line, with the pin's variant, still published? `found` is what matched.
export function listed(tags, name, tag) {
  const match = /^(\d+(?:\.\d+)*)(?:-(.+))?$/.exec(tag);
  if (!match) return { ok: tags.has(tag), what: `the tag ${tag}`, found: tags.has(tag) ? [tag] : [] };
  const numbers = match[1].split('.');
  const line = numbers.slice(0, Math.min(LINE_PARTS[name] ?? numbers.length, numbers.length)).join('.');
  const variant = match[2];
  const pattern = new RegExp(`^${escapeRegExp(line)}(?:\\.\\d+)*${variant ? `-${escapeRegExp(variant)}` : ''}$`);
  const found = [...tags].filter(candidate => pattern.test(candidate));
  return { ok: found.length > 0, what: `a tag of the ${line} line${variant ? ` with the variant ${variant}` : ''}`, found };
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function getText(url, { fetchImpl, delays }) {
  let last;
  for (let attempt = 0; attempt <= delays.length; attempt += 1) {
    try {
      const response = await fetchImpl(url, { signal: AbortSignal.timeout(30_000), redirect: 'error' });
      if (!response.ok) throw new Error(`${url}: HTTP ${response.status}`);
      return await response.text();
    } catch (error) {
      last = error;
      if (attempt < delays.length) await sleep(delays[attempt]);
    }
  }
  throw last;
}

// Docker Hub, one request (a 5xx or a timeout is asked once more after a pause):
//   { status: 'ok', pushed: ms } | { status: 'missing' }                         the tag is there, or Docker Hub says it is not
//   { status: 'rate-limited' } | { status: 'busy', why }                         neutral: 429; 5xx or timeout twice in a row
//   { status: 'unreadable', why, connect: true }                                 no connection, or the body not read, twice in a row
//   { status: 'unreadable', why }                                                anything else: another 4xx, a redirect (the
//                                                                                API moved), another fetch error, a 200 with no date
// Only the first two groups may end the age check quietly (exit 3); an answer this script does not understand must fail the run.
async function hubTag(name, tag, { fetchImpl, delays }) {
  for (let attempt = 0; ; attempt += 1) {
    const last = attempt >= 1;
    let response;
    try {
      response = await fetchImpl(HUB_URL(name, tag), { signal: AbortSignal.timeout(30_000), redirect: 'manual' });
    } catch (error) {
      if (error?.name !== 'TimeoutError' && error?.name !== 'AbortError') {
        // A connection error (refused, reset, DNS) is not a sign that the API moved: ask once more before giving up.
        if (last) return { status: 'unreadable', why: `could not connect (${error.message})`, connect: true };
        await sleep(delays[0] ?? 0);
        continue;
      }
      if (last) return { status: 'busy', why: 'timed out' };
      await sleep(delays[0] ?? 0);
      continue;
    }
    if (response.status === 429) return { status: 'rate-limited' };
    if (response.status >= 500) {
      if (last) return { status: 'busy', why: `HTTP ${response.status}` };
      await sleep(delays[0] ?? 0);
      continue;
    }
    if (response.status === 404) return { status: 'missing' };
    if (response.status >= 300 && response.status < 400) return { status: 'unreadable', why: `HTTP ${response.status}, redirected: the Docker Hub API address has moved` };
    if (!response.ok) return { status: 'unreadable', why: `HTTP ${response.status}` };
    try {
      const body = await response.json();
      const pushed = Date.parse(body.tag_last_pushed ?? body.last_updated);
      return Number.isNaN(pushed) ? { status: 'unreadable', why: 'HTTP 200 without a push date' } : { status: 'ok', pushed };
    } catch (error) {
      // The body did not arrive in time: the same as no connection (ask once more), not an answer that was not understood.
      if (error?.name === 'TimeoutError' || error?.name === 'AbortError') {
        if (last) return { status: 'unreadable', why: `could not connect (the answer was not read in time: ${error.message})`, connect: true };
        await sleep(delays[0] ?? 0);
        continue;
      }
      return { status: 'unreadable', why: error.message };
    }
  }
}

// `deps` is for the tests: the network, the clock, the repository root and the two output streams.
export async function main(argv = process.argv.slice(2), deps = {}) {
  const {
    fetchImpl = fetch, delays = [2000, 5000], now = Date.now(), out = console.log, err = console.error,
    root = fileURLToPath(new URL('../', import.meta.url)),
  } = deps;
  if (argv.length) { err('usage: check-base-images.mjs (no arguments)'); return EXIT.unreadable; }
  const pins = collectPins(root);
  if (!pins.length) { err('No official base image pin found in docker/*/Dockerfile or docker/docker-compose.yml: the check reads nothing.'); return EXIT.unreadable; }
  const libraries = new Map();
  try {
    for (const name of [...new Set(pins.map(pin => pin.name))]) libraries.set(name, parseLibrary(await getText(LIBRARY_URL(name), { fetchImpl, delays })));
  } catch (error) {
    err(`The official-images library could not be read: ${error.message}`);
    return EXIT.unreadable;
  }
  let failed = 0;
  let warned = 0;
  let skipped = 0;
  let hubTrouble = '';   // why the age check stopped; the remaining pins are not asked
  let hubBroken = false; // true when it is something other than a 429 or an outage
  for (const pin of pins) {
    const label = `${pin.name}:${pin.tag || '(no tag)'} (${pin.files.join(', ')})`;
    if (!pin.tag) { warned += 1; out(`WARN ${label}: pinned by digest alone; the check needs a tag to read the library.`); continue; }
    const library = listed(libraries.get(pin.name), pin.name, pin.tag);
    if (!library.ok) {
      failed += 1;
      out(`FAIL ${label}: ${library.what} is no longer in the official-images library (library/${pin.name}), so this pin gets no more updates. ` +
        'Move the pin to a published variant, then rebuild and rescan (docs/CONTAINER_SECURITY.md, "Image pins").');
      continue;
    }
    const skip = () => { skipped += 1; out(`OK   ${label}: ${library.what} is listed; age not checked (Docker Hub ${hubTrouble}).`); };
    if (hubTrouble) { skip(); continue; }
    const hub = await hubTag(pin.name, pin.tag, { fetchImpl, delays });
    if (hub.status === 'rate-limited') { hubTrouble = 'rate limited (HTTP 429), retry later'; skip(); continue; }
    if (hub.status === 'busy') { hubTrouble = `did not answer (${hub.why}), retry later`; skip(); continue; }
    if (hub.status === 'unreadable') {
      hubTrouble = `answer not understood (${hub.why})`; hubBroken = true;
      if (hub.connect) err(`Docker Hub could not be read for the age check: ${hub.why}, twice. This is not a rate limit; the age of the pins is not being checked. Check the network of the runner and run the check again.`);
      else err(`Docker Hub could not be read for the age check: ${hub.why}. This is not a rate limit: the endpoint (https://hub.docker.com/v2/repositories/library/<name>/tags/<tag>) may have moved, or Docker Hub may now refuse this client; the age of the pins is not being checked.`);
      skip(); continue;
    }
    if (hub.status === 'missing') { warned += 1; out(`WARN ${label}: ${library.what} is listed, but Docker Hub has no tag ${pin.tag}. The digest pin still builds; check whether the tag was withdrawn.`); continue; }
    const age = Math.max(0, Math.floor((now - hub.pushed) / DAY));
    if (age > MAX_AGE_DAYS) {
      warned += 1;
      out(`WARN ${label}: last pushed ${age} days ago (limit ${MAX_AGE_DAYS}). The variant is listed but is not being rebuilt, or this patch release has been superseded: check the newest tag of the line and bump the pin.`);
    } else out(`OK   ${label}: ${library.what} is listed; last pushed ${age} day(s) ago.`);
  }
  out(`${pins.length} pin(s) checked: ${failed} variant(s) gone, ${warned} warning(s)${skipped ? `, ${skipped} age check(s) skipped (Docker Hub ${hubTrouble})` : ''}.`);
  if (failed) return EXIT.failed;
  if (hubBroken) return EXIT.unreadable;
  return hubTrouble ? EXIT.rateLimited : EXIT.ok;
}

if (isMain(import.meta.url)) {
  main().then(code => { process.exitCode = code; }, error => { console.error(error.message); process.exitCode = EXIT.unreadable; });
}
