import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EXIT, MAX_AGE_DAYS, OFFICIAL, collectPins, listed, main, parseLibrary, pinsFromCompose, pinsFromDockerfile } from '../scripts/check-base-images.mjs';

const repo = new URL('..', import.meta.url).pathname;
const read = path => readFileSync(join(repo, path), 'utf8');
const DAY = 86_400_000;
const now = Date.UTC(2026, 9, 26);
const digest = `@sha256:${'a'.repeat(64)}`;

// Library files as docker-library/official-images prints them (stanzas of Tags: ... Directory:), cut down.
const NGINX = `# this file is generated

Maintainers: NGINX Docker Maintainers <docker-maint@nginx.com> (@nginx)
GitRepo: https://github.com/nginx/docker-nginx.git

Tags: 1.31.8-alpine-slim, mainline-alpine-slim, 1-alpine-slim, 1.31-alpine-slim, alpine-slim, 1.31.8-alpine3.24-slim, alpine3.24-slim
Architectures: amd64
Directory: mainline/alpine-slim

Tags: 1.30.6, stable, 1.30, 1.30.6-trixie, stable-trixie, 1.30-trixie
Architectures: amd64
Directory: stable/debian

Tags: 1.30.6-alpine-slim, stable-alpine-slim, 1.30-alpine-slim, 1.30.6-alpine3.24-slim, stable-alpine3.24-slim, 1.30-alpine3.24-slim
Architectures: amd64
Directory: stable/alpine-slim
`;
const NODE = `Maintainers: The Node.js Docker Team <https://github.com/nodejs/docker-node> (@nodejs)
GitRepo: https://github.com/nodejs/docker-node.git

Tags: 24.22.1-trixie-slim, 24.22-trixie-slim, 24-trixie-slim, krypton-trixie-slim
SharedTags: 24.22.1-slim, 24-slim
Architectures: amd64

Tags: 24.22.1-alpine3.24, 24.22-alpine3.24, 24-alpine3.24, krypton-alpine3.24, 24.22.1-alpine, 24-alpine, alpine
Architectures: amd64

Tags: 25.1.0-alpine3.23, 25-alpine3.23
Architectures: amd64
`;
const DEBIAN = 'Tags: bookworm-20260901-slim, bookworm-slim\nArchitectures: amd64\n\nTags: trixie-20260901-slim, trixie-slim, stable-slim\n';

test('a library file lists tags on Tags: and SharedTags: lines', () => {
  const tags = parseLibrary(NODE);
  assert.ok(tags.has('24-alpine3.24') && tags.has('24.22.1-slim') && tags.has('alpine'), 'Tags and SharedTags');
  assert.ok(!tags.has('Maintainers') && !tags.has(''));
  assert.deepEqual([...parseLibrary('Tags: a,b ,  c\nNotTags: d\n')], ['a', 'b', 'c']);
  assert.equal(parseLibrary('').size, 0);
});

test('a library file folds long fields onto continuation lines: a folded Tags: or SharedTags: value keeps every tag, and a folded Maintainers: adds none', () => {
  const folded = `Maintainers: A Maintainer <a@example.test> (@a),
             Another Maintainer <b@example.test> (@b)
GitRepo: https://example.test/library.git

Tags: 3.15.0-slim-trixie, 3.15-slim-trixie,
  3.15.0-slim-bookworm, 3.15-slim-bookworm
 , 3-slim-bookworm
SharedTags: 3.15.0-slim,
\t3.15-slim
Architectures: amd64,
              arm64v8
Directory: 3.15/slim-bookworm

# a comment line
Tags: late-tag
  continued-late-tag
`;
  const tags = parseLibrary(folded);
  assert.deepEqual([...tags].sort(), ['3-slim-bookworm', '3.15-slim', '3.15-slim-bookworm', '3.15-slim-trixie', '3.15.0-slim', '3.15.0-slim-bookworm', '3.15.0-slim-trixie', 'continued-late-tag', 'late-tag']);
  assert.ok(!tags.has('arm64v8') && ![...tags].some(tag => /@|Maintainer|amd64/.test(tag)), 'folded fields other than Tags are not tags');
  // The pin the fold used to hide: before the fix 3.15-slim-bookworm sat on the second line and was a false FAIL.
  assert.equal(listed(tags, 'python', '3.15-slim-bookworm').ok, true);
});

test('a pin is current while its line is published in its variant: 1.28-alpine-slim is gone, 1.30 is not', () => {
  const nginx = parseLibrary(NGINX);
  assert.equal(listed(nginx, 'nginx', '1.30.6-alpine-slim').ok, true);
  assert.equal(listed(nginx, 'nginx', '1.30.5-alpine-slim').ok, true, 'an older patch of a published line: Dependabot bumps it, the variant is alive');
  assert.equal(listed(nginx, 'nginx', '1.28-alpine-slim').ok, false, 'the stable branch before 1.30 is not published any more');
  assert.equal(listed(nginx, 'nginx', '1.28.3-alpine-slim').ok, false);
  assert.equal(listed(nginx, 'nginx', '1.31.8-alpine-slim').ok, true, 'a mainline line is a line too (the gateway test is what keeps it off the mainline)');
  assert.equal(listed(nginx, 'nginx', '1.30.6-alpine-perl').ok, false, 'another variant of the same line');
  assert.equal(listed(nginx, 'nginx', '1.3.6-alpine-slim').ok, false, '1.3 is not 1.30');
  assert.equal(listed(nginx, 'nginx', '1.30.6').ok, true, 'no variant: the plain Debian tag');
  assert.match(listed(nginx, 'nginx', '1.28-alpine-slim').what, /a tag of the 1\.28 line with the variant alpine-slim/);
});

test('the line is the major for node and postgres, major.minor for python, nginx, ubuntu, and a tag with no version must be listed exactly', () => {
  const node = parseLibrary(NODE);
  assert.equal(listed(node, 'node', '24.22.1-alpine3.24').ok, true);
  assert.equal(listed(node, 'node', '24.21.0-alpine3.24').ok, true, 'node 24 moves its minor every few weeks: the line is the major');
  assert.equal(listed(node, 'node', '24.22.1-alpine3.23').ok, false, 'Alpine 3.23 is dropped by node 24: the stall this check exists for');
  assert.equal(listed(node, 'node', '24-trixie-slim').ok, true);
  assert.equal(listed(node, 'node', '23.1.0-alpine3.24').ok, false, 'another major');
  assert.equal(listed(parseLibrary('Tags: 18.6-trixie, 18-trixie, trixie\n'), 'postgres', '18.7-trixie').ok, true);
  assert.equal(listed(parseLibrary('Tags: 18.6-trixie, 18-trixie, trixie\n'), 'postgres', '17.9-trixie').ok, false);
  const python = parseLibrary('Tags: 3.15.0-slim-trixie, 3.15-slim-trixie, 3.15.0-slim-bookworm, 3.15-slim-bookworm, 3.150-slim-bookworm\n');
  assert.equal(listed(python, 'python', '3.15-slim-bookworm').ok, true);
  assert.equal(listed(parseLibrary('Tags: 3.16-slim-trixie, 3.150-slim-bookworm\n'), 'python', '3.15-slim-bookworm').ok, false, 'python 3.15 is not 3.150, and its Debian release is gone');
  assert.equal(listed(parseLibrary('Tags: 22.04, jammy-20260101, jammy\n'), 'ubuntu', '22.04').ok, true);
  assert.equal(listed(parseLibrary('Tags: 24.04, noble\n'), 'ubuntu', '22.04').ok, false);
  assert.equal(listed(parseLibrary(DEBIAN), 'debian', 'bookworm-slim').ok, true);
  assert.equal(listed(parseLibrary('Tags: trixie-slim\n'), 'debian', 'bookworm-slim').ok, false, 'bookworm-slim leaves the library when Debian 12 is archived');
  assert.equal(listed(new Set(), 'debian', 'bookworm-slim').ok, false);
});

test('a numeric Debian pin follows its major: 12.12-slim is current while 12.13-slim or 12-slim is listed, and gone when Debian 12 leaves', () => {
  const debian = parseLibrary('Tags: 12.13-slim, 12-slim, bookworm-20260901-slim, bookworm-slim\n\nTags: 13.3-slim, 13-slim, trixie-slim\n');
  assert.equal(listed(debian, 'debian', '12.12-slim').ok, true, 'the library lists only the newest point release; 12.12 is an older one of the live line');
  assert.equal(listed(debian, 'debian', '12.13-slim').ok, true);
  assert.equal(listed(debian, 'debian', '12.12').ok, false, 'another variant: no plain 12.x tag listed here');
  assert.equal(listed(debian, 'debian', '11.11-slim').ok, false);
  assert.equal(listed(parseLibrary('Tags: 13.3-slim, 13-slim, trixie-slim\n'), 'debian', '12.12-slim').ok, false, 'Debian 12 is gone from the library');
  assert.match(listed(parseLibrary('Tags: 13.3-slim\n'), 'debian', '12.12-slim').what, /a tag of the 12 line with the variant slim/);
});

test('pins are read from FROM lines (stages and variables left out) and from image: lines of Compose', () => {
  const dockerfile = `# FROM nginx:1.0 in a comment
FROM node:24-trixie-slim${digest} AS base
FROM --platform=linux/amd64 postgres:18.6-trixie${digest}
FROM base AS runtime
FROM \${BASE_IMAGE}
FROM supabase/edge-runtime:v1.77.8${digest} AS upstream
from DEBIAN:bookworm-slim
FROM library/alpine:3.23
FROM python${digest}
`;
  assert.deepEqual(pinsFromDockerfile(dockerfile).map(pin => `${pin.name}:${pin.tag}`),
    ['node:24-trixie-slim', 'postgres:18.6-trixie', 'supabase/edge-runtime:v1.77.8', 'alpine:3.23', 'python:']);
  // The Docker Hub registry written out is still the official image: it must be watched, not silently dropped.
  const qualified = `FROM docker.io/library/node:24-trixie-slim${digest} AS build
FROM index.docker.io/library/nginx:1.30.6-alpine-slim${digest}
FROM docker.io/postgres:18.6-trixie
FROM docker.io/postgrest/postgrest:v16.5${digest}
FROM docker.io/library/python${digest}
`;
  assert.deepEqual(pinsFromDockerfile(qualified).map(pin => `${pin.name}:${pin.tag}`),
    ['node:24-trixie-slim', 'nginx:1.30.6-alpine-slim', 'postgres:18.6-trixie', 'postgrest/postgrest:v16.5', 'python:']);
  assert.deepEqual(pinsFromCompose(`services:\n  a:\n    image: docker.io/library/nginx:1.30.6-alpine-slim${digest}\n`).map(pin => `${pin.name}:${pin.tag}`), ['nginx:1.30.6-alpine-slim']);
  const compose = `services:
  rest:
    image: postgrest/postgrest:v16.5${digest}
  gateway:
    image: \${WAREHOUSE_PROJECT_NAME:?Run setup.sh}-gateway
  cache:
    image: "nginx:1.30.6-alpine-slim"
    environment:
      image: not-a-service
  other:
    image: nginx:1.30.6-alpine-slim${digest}
`;
  assert.deepEqual(pinsFromCompose(compose).map(pin => `${pin.name}:${pin.tag}`), ['postgrest/postgrest:v16.5', 'nginx:1.30.6-alpine-slim', 'nginx:1.30.6-alpine-slim']);
});

test('every official base image this repository pins is found, each with a tag the check can read', () => {
  const pins = collectPins(repo);
  assert.ok(pins.length >= 5, 'the pins were read');
  for (const pin of pins) {
    assert.ok(OFFICIAL.includes(pin.name), pin.name);
    assert.match(pin.tag, /^[\w.-]+$/, `${pin.name}: pinned by tag and digest`);
    assert.ok(pin.files.length >= 1);
  }
  // Every FROM of an official image in a recipe is one of them: a recipe added tomorrow is watched without an edit here.
  for (const dir of ['nginx', 'postgres', 'storage', 'sensor-bridge', 'pdf-renderer', 'edge-runtime']) {
    for (const pin of pinsFromDockerfile(read(`docker/${dir}/Dockerfile`)).filter(item => OFFICIAL.includes(item.name))) {
      assert.ok(pins.some(found => found.name === pin.name && found.tag === pin.tag && found.files.includes(`docker/${dir}/Dockerfile`)), `${dir}: ${pin.name}:${pin.tag}`);
    }
  }
  assert.ok(pins.some(pin => pin.name === 'nginx'));
});

// ---- the whole check, with a repository and a network of its own --------------------------------------------------------------

function repository(pins) {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-base-images-'));
  for (const [dir, from] of Object.entries(pins)) {
    mkdirSync(join(root, 'docker', dir), { recursive: true });
    writeFileSync(join(root, 'docker', dir, 'Dockerfile'), `FROM ${from}${digest}\nRUN true\n`);
  }
  return root;
}

// `library`: name -> file text (a missing name answers 404); `hub`: "name:tag" -> days since the last push, 'missing',
// { status }, 'timeout' (the request is aborted), 'refused' (a network error), 'nodate' (HTTP 200 without a push date), or a list
// of these answered in turn (the last one repeats).
function network({ library, hub = {}, requests = [] }) {
  const turns = new Map();
  return async (url, init = {}) => {
    requests.push(url);
    const lib = /^https:\/\/raw\.githubusercontent\.com\/docker-library\/official-images\/master\/library\/([a-z]+)$/.exec(url);
    if (lib) return library[lib[1]] === undefined ? { ok: false, status: 404 } : { ok: true, status: 200, text: async () => library[lib[1]] };
    const tag = /^https:\/\/hub\.docker\.com\/v2\/repositories\/library\/([a-z]+)\/tags\/([^/]+)$/.exec(url);
    assert.ok(tag, `unexpected request ${url}`);
    assert.equal(init.redirect, 'manual', 'a redirect is read as an answer, not thrown as a fetch error');
    const key = `${tag[1]}:${decodeURIComponent(tag[2])}`;
    const answers = [hub[key] ?? 1].flat();
    const turn = turns.get(key) ?? 0;
    turns.set(key, turn + 1);
    const answer = answers[Math.min(turn, answers.length - 1)];
    if (answer === 'missing') return { ok: false, status: 404 };
    if (answer === 'timeout') throw new DOMException('The operation was aborted due to timeout', 'TimeoutError');
    if (answer === 'refused') throw new TypeError('fetch failed');
    if (answer === 'bodytimeout') return { ok: true, status: 200, json: async () => { throw new DOMException('The operation was aborted due to timeout', 'TimeoutError'); } };
    if (answer === 'nodate') return { ok: true, status: 200, json: async () => ({ name: tag[2] }) };
    if (typeof answer === 'object') return { ok: false, status: answer.status };
    return { ok: true, status: 200, json: async () => ({ name: tag[2], tag_last_pushed: new Date(now - answer * DAY).toISOString() }) };
  };
}

async function check(root, options) {
  const out = [];
  const err = [];
  const requests = options.requests ?? [];
  const code = await main([], { root, fetchImpl: network({ ...options, requests }), delays: [1], now, out: line => out.push(line), err: line => err.push(line) });
  return { code, out: out.join('\n'), err: err.join('\n'), requests };
}

test('a pin whose variant is gone from the library fails (exit 1) and is not asked about at Docker Hub; a current pin passes with its age', async () => {
  const root = repository({ nginx: 'nginx:1.28-alpine-slim' });
  try {
    const gone = await check(root, { library: { nginx: NGINX } });
    assert.equal(gone.code, EXIT.failed);
    assert.match(gone.out, /^FAIL nginx:1\.28-alpine-slim \(docker\/nginx\/Dockerfile\): a tag of the 1\.28 line with the variant alpine-slim is no longer in the official-images library \(library\/nginx\), so this pin gets no more updates\. Move the pin/m);
    assert.match(gone.out, /1 pin\(s\) checked: 1 variant\(s\) gone, 0 warning\(s\)/);
    assert.equal(gone.requests.filter(url => url.includes('hub.docker.com')).length, 0, 'no Docker Hub request for a failed pin');
    writeFileSync(join(root, 'docker/nginx/Dockerfile'), `FROM nginx:1.30.6-alpine-slim${digest}\n`);
    const fine = await check(root, { library: { nginx: NGINX }, hub: { 'nginx:1.30.6-alpine-slim': 3 } });
    assert.equal(fine.code, EXIT.ok);
    assert.match(fine.out, /^OK   nginx:1\.30\.6-alpine-slim \(docker\/nginx\/Dockerfile\): a tag of the 1\.30 line with the variant alpine-slim is listed; last pushed 3 day\(s\) ago\./m);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('node dropping Alpine 3.23, python dropping slim-bookworm and debian archiving bookworm each fail their pin', async () => {
  const root = repository({ storage: 'node:24.22.1-alpine3.23', 'sensor-bridge': 'python:3.15-slim-bookworm', 'edge-runtime': 'debian:bookworm-slim', cups: 'ubuntu:22.04' });
  try {
    const library = { node: NODE, python: 'Tags: 3.15.0-slim-trixie, 3.15-slim-trixie\n', debian: 'Tags: trixie-slim\n', ubuntu: 'Tags: 22.04, jammy\n' };
    const result = await check(root, { library });
    assert.equal(result.code, EXIT.failed);
    assert.deepEqual(result.out.split('\n').filter(line => line.startsWith('FAIL')).map(line => line.split(' ')[1]).sort(),
      ['debian:bookworm-slim', 'node:24.22.1-alpine3.23', 'python:3.15-slim-bookworm']);
    assert.match(result.out, /^OK   ubuntu:22\.04 /m);
    assert.match(result.out, /4 pin\(s\) checked: 3 variant\(s\) gone/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('Docker Hub: a tag pushed more than 120 days ago, or withdrawn, is a warning (exit 0)', async () => {
  const root = repository({ nginx: 'nginx:1.30.6-alpine-slim', storage: 'node:24.22.1-alpine3.24', postgres: 'postgres:18.6-trixie' });
  try {
    const library = { nginx: NGINX, node: NODE, postgres: 'Tags: 18.6-trixie, 18-trixie\n' };
    const result = await check(root, { library, hub: { 'nginx:1.30.6-alpine-slim': MAX_AGE_DAYS + 1, 'node:24.22.1-alpine3.24': MAX_AGE_DAYS, 'postgres:18.6-trixie': 'missing' } });
    assert.equal(result.code, EXIT.ok, 'a warning does not fail');
    assert.match(result.out, /^WARN nginx:1\.30\.6-alpine-slim \(docker\/nginx\/Dockerfile\): last pushed 121 days ago \(limit 120\)/m);
    assert.match(result.out, /^OK   node:24\.22\.1-alpine3\.24 .*last pushed 120 day\(s\) ago/m, 'exactly 120 days is allowed');
    assert.match(result.out, /^WARN postgres:18\.6-trixie .*Docker Hub has no tag 18\.6-trixie/m);
    assert.match(result.out, /3 pin\(s\) checked: 0 variant\(s\) gone, 2 warning\(s\)/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('Docker Hub rate limiting (429): the library check still runs, the age check stops after the first answer, and the exit code is the neutral 3; a failure still wins', async () => {
  const root = repository({ nginx: 'nginx:1.30.6-alpine-slim', storage: 'node:24.22.1-alpine3.24', postgres: 'postgres:18.6-trixie' });
  try {
    const library = { nginx: NGINX, node: NODE, postgres: 'Tags: 18.6-trixie, 18-trixie\n' };
    const requests = [];
    const limited = await check(root, { library, requests, hub: { 'nginx:1.30.6-alpine-slim': { status: 429 } } });
    assert.equal(limited.code, EXIT.rateLimited);
    assert.equal(EXIT.rateLimited, 3);
    assert.equal(requests.filter(url => url.includes('hub.docker.com')).length, 1, 'no further Docker Hub request after a 429');
    assert.match(limited.out, /age not checked \(Docker Hub rate limited \(HTTP 429\), retry later\)/);
    assert.match(limited.out, /3 pin\(s\) checked: 0 variant\(s\) gone, 0 warning\(s\), 3 age check\(s\) skipped \(Docker Hub rate limited/);
    // The library check does not depend on Docker Hub: a gone variant is reported as the failure it is.
    const both = await check(root, { library: { ...library, postgres: 'Tags: 17.9-trixie\n' }, hub: { 'nginx:1.30.6-alpine-slim': { status: 429 } } });
    assert.equal(both.code, EXIT.failed);
    assert.match(both.out, /^FAIL postgres:18\.6-trixie/m);
    // Docker Hub that is down (5xx on both tries) is the same neutral result, after one more try.
    const downRequests = [];
    const down = await check(root, { library, requests: downRequests, hub: { 'nginx:1.30.6-alpine-slim': { status: 500 } } });
    assert.equal(down.code, EXIT.rateLimited);
    assert.match(down.out, /did not answer \(HTTP 500\)/);
    assert.equal(downRequests.filter(url => url.includes('hub.docker.com')).length, 2, 'one retry of the 5xx, then the age check stops');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// Only a 429 and a Docker Hub outage (5xx or a timeout on both tries) are neutral (exit 3). Every other answer the age check cannot
// use is exit 2: the run fails and the issue is left alone, so the WARN half cannot stop for good without a red run.
test('Docker Hub: a 5xx or a timeout once is retried and read; twice in a row it is neutral (3); every other failure is exit 2', async () => {
  const root = repository({ nginx: 'nginx:1.30.6-alpine-slim', storage: 'node:24.22.1-alpine3.24' });
  try {
    const library = { nginx: NGINX, node: NODE };
    const pin = 'nginx:1.30.6-alpine-slim';
    const hubRequests = requests => requests.filter(url => url.includes('hub.docker.com')).length;
    for (const [what, first] of [['a 503', { status: 503 }], ['a timeout', 'timeout']]) {
      const requests = [];
      const retried = await check(root, { library, requests, hub: { [pin]: [first, 2] } });
      assert.equal(retried.code, EXIT.ok, `${what} once, then an answer`);
      assert.match(retried.out, /^OK   nginx:1\.30\.6-alpine-slim .*last pushed 2 day\(s\) ago/m);
      assert.equal(hubRequests(requests), 3, `two for the retried pin, one for the next`);
      const twice = await check(root, { library, hub: { [pin]: first } });
      assert.equal(twice.code, EXIT.rateLimited, `${what} twice`);
      assert.match(twice.out, /age not checked \(Docker Hub did not answer \((?:HTTP 503|timed out)\), retry later\)/);
    }
    // Not neutral: each of these is a Docker Hub that moved, refuses this client or changed its answer.
    for (const [what, answer, why] of [
      ['a 403', { status: 403 }, /HTTP 403/], ['a 401', { status: 401 }, /HTTP 401/], ['a 410', { status: 410 }, /HTTP 410/],
      ['a redirect', { status: 301 }, /HTTP 301, redirected/], ['a 200 without a push date', 'nodate', /HTTP 200 without a push date/],
    ]) {
      const requests = [];
      const result = await check(root, { library, requests, hub: { [pin]: answer } });
      assert.equal(result.code, EXIT.unreadable, what);
      assert.equal(result.code, 2);
      assert.match(result.err, new RegExp(`Docker Hub could not be read for the age check: ${why.source}`), what);
      assert.match(result.err, /not a rate limit/, what);
      assert.match(result.out, /age not checked \(Docker Hub answer not understood \(/, what);
      assert.equal(hubRequests(requests), 1, `${what}: not retried, and the next pin is not asked`);
    }
    // No connection, or a body that is not read in time: asked once more; one failure then an answer reads normally, two in a row is
    // exit 2 that says "could not connect" and does not blame the endpoint.
    for (const [what, bad] of [['a network error', 'refused'], ['a body read timeout', 'bodytimeout']]) {
      const retried = await check(root, { library, hub: { [pin]: [bad, 2] } });
      assert.equal(retried.code, EXIT.ok, `${what} once, then an answer`);
      const requests = [];
      const twice = await check(root, { library, requests, hub: { [pin]: bad } });
      assert.equal(twice.code, EXIT.unreadable, `${what} twice`);
      assert.match(twice.err, /Docker Hub could not be read for the age check: could not connect \(/, what);
      assert.doesNotMatch(twice.err, /may have moved/, what);
      assert.equal(hubRequests(requests), 2, `${what}: one retry, and the next pin is not asked`);
    }
    // A pin that is gone from the library is still reported as the failure it is, and the unreadable Docker Hub is still printed.
    const both = await check(root, { library: { ...library, node: 'Tags: 25.1.0-alpine3.23\n' }, hub: { [pin]: { status: 403 } } });
    assert.equal(both.code, EXIT.failed, 'a variant that is gone wins over an age check that could not run');
    assert.match(both.out, /^FAIL node:24\.22\.1-alpine3\.24/m);
    assert.match(both.err, /Docker Hub could not be read for the age check: HTTP 403/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('a pin written with the Docker Hub registry (docker.io/library/nginx) is watched: its gone variant fails, and "every official pin is found" sees it', async () => {
  const root = repository({ nginx: 'docker.io/library/nginx:1.28-alpine-slim', web: 'index.docker.io/library/nginx:1.30.6-alpine-slim' });
  try {
    const result = await check(root, { library: { nginx: NGINX }, hub: { 'nginx:1.30.6-alpine-slim': 4 } });
    assert.equal(result.code, EXIT.failed);
    assert.match(result.out, /^FAIL nginx:1\.28-alpine-slim \(docker\/nginx\/Dockerfile\)/m);
    assert.match(result.out, /^OK   nginx:1\.30\.6-alpine-slim \(docker\/web\/Dockerfile\).*last pushed 4 day/m);
    assert.deepEqual(collectPins(root).map(pin => `${pin.name}:${pin.tag}`).sort(), ['nginx:1.28-alpine-slim', 'nginx:1.30.6-alpine-slim']);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('a library that cannot be read is exit 2 (never a pass), and so is a repository with nothing to read', async () => {
  const root = repository({ nginx: 'nginx:1.30.6-alpine-slim' });
  try {
    const missing = await check(root, { library: {} });
    assert.equal(missing.code, EXIT.unreadable);
    assert.match(missing.err, /The official-images library could not be read: .*library\/nginx: HTTP 404/);
    assert.equal(missing.out, '');
    const empty = repository({});
    try {
      mkdirSync(join(empty, 'docker/other'), { recursive: true });
      writeFileSync(join(empty, 'docker/other/Dockerfile'), `FROM supabase/supavisor:2.9.13${digest}\n`);
      const none = await check(empty, { library: {} });
      assert.equal(none.code, EXIT.unreadable);
      assert.match(none.err, /No official base image pin found/);
    } finally { rmSync(empty, { recursive: true, force: true }); }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('the library is read once per image name, Docker Hub once per pinned tag', async () => {
  const root = repository({ pdf: 'node:24-trixie-slim', storage: 'node:24.22.1-alpine3.24', nginx: 'nginx:1.30.6-alpine-slim', again: 'nginx:1.30.6-alpine-slim' });
  try {
    const requests = [];
    const result = await check(root, { library: { nginx: NGINX, node: NODE }, requests });
    assert.equal(result.code, EXIT.ok);
    assert.equal(requests.filter(url => url.includes('raw.githubusercontent.com')).length, 2, 'node and nginx once each');
    assert.equal(requests.filter(url => url.includes('hub.docker.com')).length, 3, 'three distinct pinned tags');
    assert.match(result.out, /nginx:1\.30\.6-alpine-slim \(docker\/again\/Dockerfile, docker\/nginx\/Dockerfile\)/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// ---- where it runs ------------------------------------------------------------------------------------------------------------

test('base-images.yml: weekly, one issue (a comment only for new lines), Docker Hub trouble (3) neutral, an unreadable library or Docker Hub (2) fails the run, a crash never closes it', () => {
  const workflow = read('.github/workflows/base-images.yml');
  assert.match(workflow, /\n  schedule:\n    - cron: '[0-9]+ [0-9]+ \* \* [0-7]'\n/);
  assert.match(workflow, /permissions:\n  contents: read\n  issues: write\n/);
  assert.match(workflow, /node scripts\/check-base-images\.mjs > "\$RUNNER_TEMP\/base-images\.out"/);
  assert.match(workflow, /\[\[ "\$status" != 2 \]\] \|\| exit 2\n\s+exit 0\n/);
  assert.match(workflow, /if \[\[ "\$status" == 3 \]\]; then\n\s+echo "::warning title=Base image check incomplete::/);
  assert.match(workflow, /name: Open or update the issue[^\n]*\n(?:\s+#[^\n]*\n)*\s+if: steps\.check\.outputs\.status != '3'\n/);
  assert.match(workflow, /grep -E '\^\(FAIL\|WARN\) '/);
  assert.match(workflow, /gh issue edit "\$number" [^\n]*--body-file/);
  assert.match(workflow, /gh issue close "\$number"/);
  // An edit sends no notification, so a FAIL or WARN that is new in an open issue gets ONE comment that lists only the new lines
  // (a deliberate change to the earlier "no comment at all" rule); a week with nothing new edits silently. The step is run for real in
  // tests/workflows.test.mjs.
  assert.equal(workflow.match(/gh issue comment/g).length, 1, 'one comment, and only for new lines');
  assert.match(workflow, /if \[\[ -n "\$new" \]\]; then\n[^\n]*\n\s+gh issue comment "\$number"[^\n]*\n\s+fi\n\s+gh issue edit "\$number"/, 'the comment sits under the "new findings" condition, before the edit');
  // A crash (status 1 with no FAIL line, a signal) is not "clean": the issue is closed only for status 0 with no findings.
  assert.match(workflow, /if \[\[ "\$STATUS" != 0 \]\] && \{ \[\[ "\$STATUS" != 1 \]\] \|\| ! grep -q '\^FAIL ' "\$RUNNER_TEMP\/findings\.txt"; \}; then\n[^\n]*::error title=Base image check crashed::[^\n]*\n\s+exit 1\n\s+fi\n\s+if \[\[ -s "\$RUNNER_TEMP\/findings\.txt" \]\]/);
});

test('the functions image runs the edge-runtime binary once at build, after it is copied and before the entrypoint', () => {
  const lines = read('docker/edge-runtime/Dockerfile').split('\n').filter(line => !line.trim().startsWith('#') && line.trim());
  const copy = lines.findIndex(line => /^COPY --from=upstream \/usr\/local\/bin\/edge-runtime /.test(line));
  const run = lines.indexOf('RUN ["edge-runtime", "--version"]');
  const entrypoint = lines.findIndex(line => line.startsWith('ENTRYPOINT'));
  assert.ok(copy >= 0 && run > copy && entrypoint > run, 'COPY, then the version check, then ENTRYPOINT');
});
