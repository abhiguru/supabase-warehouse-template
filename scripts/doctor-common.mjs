import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, lstatSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, isAbsolute } from 'node:path';
import { KEY_SET_MAX_BYTES, usableKeys } from './central-key-set.mjs';
import { LETTERHEAD_MAX_BYTES, LETTERHEAD_NAME_PATTERN, letterheadKind } from './letterhead.mjs';

export function probe(command, args = [], timeoutMs = 15000) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'pipe'] });
  return { ok: result.status === 0, output: result.status === 0 ? result.stdout : '', error: result.status === 0 ? '' : String(result.stderr || '') };
}
// The postgres database's recorded collation version (pg_database.datcollversion) against what the database image's C library
// reports now (pg_database_collation_actual_version). They differ after the base image's glibc moved (docker/postgres/Dockerfile,
// the collation guard): every text index may then be in the wrong order until a REINDEX. A database without a recorded version (the C
// locale) has nothing to compare. Returns the message of a mismatch, or null when equal; throws when the answer cannot be read after
// three tries, 2 s apart (a database that was answering a moment ago can still miss one), and then stays closed: no answer is not a pass.
// `run` is probe, replaceable for a test; it gets the psql arguments after `compose.sh exec -T db`. `pause` is the wait between tries.
export const COLLATION_SQL = "SELECT coalesce(datcollversion, ''), coalesce(pg_database_collation_actual_version(oid), '') FROM pg_database WHERE datname = 'postgres'";
export const COLLATION_TRIES = 3;
const sleepMs = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
export function collationProblem(run, pause = sleepMs) {
  let match = null;
  for (let attempt = 1; attempt <= COLLATION_TRIES && !match; attempt++) {
    if (attempt > 1) pause(2000);
    const answer = run(['psql', '-X', '-qAt', '-F', '|', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', COLLATION_SQL]);
    match = /^([^|]*)\|([^|]*)$/.exec(answer.ok ? answer.output.trim().split('\n').pop() : '');
  }
  if (!match) throw new Error("Could not read the collation version of the postgres database. Run node scripts/doctor.mjs --local again; if it fails again, run the query of docs/OPERATOR_INSTALL.md, 'Collation changes', by hand.");
  const [, recorded, actual] = match;
  if (recorded === '' || recorded === actual) return null;
  return `collation version changed; REINDEX required before use — see docs/OPERATOR_INSTALL.md 'Collation changes' (recorded ${recorded}, now ${actual || 'unknown'}).`;
}
// The Docker daemon is not answering for a moment after a cold start of the host or of a WSL distro (and on Linux right after a
// reboot), so `docker info` is retried, 2 s apart, until a 60 s wall-clock deadline before the daemon counts as missing. The
// deadline is a clock, not a count of tries, because one probe can itself take its whole timeout (each is capped at the time left).
// Returns null when the daemon answered, else the refusal message. A "permission denied" answer is the user missing from the docker
// group, which waiting does not cure: it is refused at once. Only the daemon probe waits: a missing docker CLI is refused at once
// by the caller. `run` is probe, `pause` and `now` the sleep and the clock, `say` prints the one line shown while waiting; all
// replaceable for a test.
export const DOCKER_WAIT_MS = 60000;
export const DOCKER_WAIT_STEP_MS = 2000;
const DOCKER_HINT = 'check `systemctl status docker`, and that `docker ps` works without sudo (docker group, see docs/OPERATOR_INSTALL.md)';
export function waitForDocker(run = probe, pause = sleepMs, say = line => console.error(line), now = Date.now) {
  const args = ['info', '--format', '{{.ServerVersion}}'];
  const deadline = now() + DOCKER_WAIT_MS;
  let announced = false;
  for (;;) {
    const answer = run('docker', args, Math.max(1, Math.min(15000, deadline - now())));
    if (answer.ok) return null;
    if (/permission denied/i.test(answer.error || '')) return `Missing or unavailable prerequisite: docker. This user is not allowed to use the Docker daemon (permission denied); ${DOCKER_HINT}.`;
    if (now() >= deadline) return `Missing or unavailable prerequisite: docker. Docker did not answer within ${DOCKER_WAIT_MS / 1000} s; ${DOCKER_HINT}.`;
    if (!announced) { say(`Waiting for the Docker daemon to answer (up to ${DOCKER_WAIT_MS / 1000} s)...`); announced = true; }
    pause(Math.max(0, Math.min(DOCKER_WAIT_STEP_MS, deadline - now())));
  }
}
// What backups and restores need besides Docker: rsync built with extended-attribute support (scripts/backup.sh and
// scripts/restore.sh copy the stored files with `rsync -X`, which carries each file's content type and cache control) and GNU
// tar with --xattrs (db:restore-host unpacks a backup archive with it). One message per missing tool, each with the command
// that installs it. `run` is probe, replaceable for a test.
export function backupToolProblems(run = probe) {
  const problems = [];
  const rsync = run('rsync', ['--version']);
  if (!rsync.ok) {
    problems.push('rsync (the package rsync) is missing; backups and restores copy the stored files with it. Install it: sudo apt-get install rsync');
  } else {
    // The "Capabilities:" part of the version text lists "xattrs", or "no xattrs" for a build without them. No such part
    // (a very old rsync) tells nothing, and a backup would then say what is wrong.
    const capabilities = /Capabilities:([\s\S]*?)(?:Optimizations:|Checksum list:|$)/.exec(rsync.output)?.[1];
    if (capabilities !== undefined && !/(?<!no )\bxattrs\b/.test(capabilities)) {
      problems.push('this rsync was built without extended-attribute support (its version text lists no "xattrs"), so backups would lose the content type of every stored file. Install the distribution\'s rsync: sudo apt-get install rsync');
    }
  }
  if (!/GNU tar/.test(run('tar', ['--xattrs', '--version']).output)) {
    problems.push('GNU tar with --xattrs support is missing; db:restore-host unpacks a backup archive with it. Install it: sudo apt-get install tar');
  }
  return problems;
}
export function readEnv(path) {
  if (!existsSync(path)) throw new Error('Configuration is missing; run the documented setup first.');
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('Configuration must be a regular file, not a symlink.');
  const values = {};
  for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match) values[match[1]] = match[2].replace(/\s+#.*$/, '').replace(/^['"]|['"]$/g, '');
  }
  return values;
}
// The loopback port of the gateway in a compose.env: GATEWAY_HTTP_PORT, or KONG_HTTP_PORT, its name while the gateway was Kong, in
// a file that configure.mjs has not rewritten yet (docker/docker-compose.yml reads both in the same order). An empty line counts as
// unset, as in Compose's `${GATEWAY_HTTP_PORT:-...}`: `||`, not `??`.
// Compatibility shim: the KONG_HTTP_PORT fallback may be dropped once from_floor (scripts/upgrade-floor.txt) is at or after the release
// whose setup renames the line on every run (renameKongPort in scripts/configure.mjs).
export const gatewayPortText = env => env.GATEWAY_HTTP_PORT || env.KONG_HTTP_PORT;
// Whether a running container of this installation's own Compose project publishes the loopback gateway port (a line of `docker ps`
// such as `127.0.0.1:18000->8000/tcp`). The port is then the installation's own, not a stranger's. Which service it is does not
// matter, and must not: an installation made before the nginx gateway has a `kong` container on the port and no `gateway`
// container, and setup.sh and start.sh run this preflight from the new checkout before `up --remove-orphans` can replace it, so
// asking for `gateway` alone stopped every such upgrade (and `compose ps -q kong` is no answer: Compose refuses a service the
// file no longer has). A container of another project, or a process that is not a container, does not count.
export function projectPublishesPort(project, port, run = probe) {
  const listed = run('docker', ['ps', '--filter', `label=com.docker.compose.project=${project}`, '--format', '{{.Ports}}']);
  if (!listed.ok) return false;
  return listed.output.split(/[\r\n]+/).flatMap(line => line.split(',')).some(published => {
    const range = /(?:^|:)(\d+)(?:-(\d+))?->/.exec(published.trim());
    return range !== null && Number(range[1]) <= port && port <= Number(range[2] ?? range[1]);
  });
}
export function operatorEnvPath() {
  const state = process.env.WAREHOUSE_STATE_DIR;
  if (!state || !isAbsolute(state)) throw new Error('Set WAREHOUSE_STATE_DIR to the installed operator state.');
  return resolve(state, 'config/compose.env');
}
export const root = fileURLToPath(new URL('..', import.meta.url));
export const supportedNode = (version = process.versions.node) => {
  const [major, minor] = version.split('.').map(Number);
  return major > 22 || (major === 22 && minor >= 18);
};

// The one rule for the central sign-in key file (CENTRAL_JWKS_FILE, read by the router from <state>/public/<name>): it must be a
// plain file name, an existing regular file of at most 64 KB, holding a usable JSON key set. Returns null when the file is fine or
// none is configured, else { code, path, detail } with code name | missing | not-file | too-large | not-json | unusable. Each caller
// (doctor.mjs, watch.mjs) words the fault for its reader.
export function centralKeyFault(name, stateDir) {
  if (!name) return null;
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/.test(name)) return { code: 'name', path: name, detail: '' };
  const path = resolve(stateDir, 'public', name);
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return { code: 'missing', path, detail: '' };
  if (!stat.isFile()) return { code: 'not-file', path, detail: '' };
  if (stat.size > KEY_SET_MAX_BYTES) return { code: 'too-large', path, detail: '' };
  let document;
  try { document = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(path))); } catch (error) { return { code: 'not-json', path, detail: error.message }; }
  try { usableKeys(document); } catch (error) { return { code: 'unusable', path, detail: error.message }; }
  return null;
}

// The one rule for the optional letterhead image (LETTERHEAD_FILE, read by the router from <state>/public/<name>): the name is
// letterhead.jpg or letterhead.png, an existing regular file of at most 2 MiB that starts with the signature of its kind.
// Returns null when the file is fine or none is configured, else { code, path } with code name | missing | not-file |
// too-large | not-image. PDFs are made without a faulty letterhead, so callers word this as a warning.
export function letterheadFault(name, stateDir) {
  if (!name) return null;
  if (!LETTERHEAD_NAME_PATTERN.test(name)) return { code: 'name', path: name };
  const path = resolve(stateDir, 'public', name);
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return { code: 'missing', path };
  if (!stat.isFile()) return { code: 'not-file', path };
  if (stat.size > LETTERHEAD_MAX_BYTES) return { code: 'too-large', path };
  const kind = letterheadKind(readFileSync(path));
  if (!kind || name !== `letterhead.${kind}`) return { code: 'not-image', path };
  return null;
}
// The sentence both doctor.mjs and watch.mjs print; includes the command that puts the image back.
export function letterheadProblem(env, stateDir) {
  const fault = letterheadFault(env.LETTERHEAD_FILE, stateDir);
  if (!fault) return '';
  const rerun = 'Put it back by rerunning setup.sh --operator with your usual inputs plus --letterhead-file <the image> (or --letterhead-file off for plain PDFs); see docs/OPERATOR_INSTALL.md, "Letterhead".';
  return {
    name: `LETTERHEAD_FILE must be letterhead.jpg or letterhead.png, not ${fault.path}. ${rerun}`,
    missing: `The letterhead image ${fault.path} is missing: the GRN, dispatch, invoice and customer stock PDFs are made without it. ${rerun}`,
    'not-file': `${fault.path} must be a regular file; the PDFs are made without a letterhead. ${rerun}`,
    'too-large': `${fault.path} is larger than 2 MiB; the PDFs are made without a letterhead. ${rerun}`,
    'not-image': `${fault.path} is not a JPEG or PNG image; the PDFs are made without a letterhead. ${rerun}`,
  }[fault.code];
}
