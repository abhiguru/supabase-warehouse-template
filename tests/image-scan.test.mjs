import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, rmSync, readdirSync, statSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { validateLedger, MAX_EXCEPTION_DAYS } from '../scripts/validate-image-report.mjs';

const validator = new URL('../scripts/validate-image-report.mjs', import.meta.url).pathname;
const repo = new URL('..', import.meta.url).pathname;
const DAY = 24 * 60 * 60 * 1000;
const date = offset => new Date(Date.now() + offset * DAY).toISOString().slice(0, 10);
const composeConfig = services => JSON.stringify({ name: 'warehouse-scan-test', services });

test('image scan fails closed on missing inventory and isolates each report run', () => {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-scan-test-'));
  try {
    mkdirSync(join(root, 'scripts'));
    mkdirSync(join(root, 'bin'));
    mkdirSync(join(root, 'docker'));
    copyFileSync(new URL('../scripts/scan-images.sh', import.meta.url), join(root, 'scripts/scan-images.sh'));
    copyFileSync(new URL('../scripts/validate-image-report.mjs', import.meta.url), join(root, 'scripts/validate-image-report.mjs'));
    copyFileSync(new URL('../scripts/is-main.mjs', import.meta.url), join(root, 'scripts/is-main.mjs'));
    writeFileSync(join(root, 'docker/image-exceptions.json'), JSON.stringify({ schemaVersion: 1, exceptions: [] }));
    const scanner = body => writeFileSync(join(root, 'bin/trivy'), `#!/bin/sh\n${body}\n`, { mode: 0o700 });
    scanner('exit 0');
    const reportDir = join(root, 'reports');
    const one = `echo '${composeConfig({ app: { image: 'example.test/image:1' } })}'`;
    const run = inventory => {
      writeFileSync(join(root, 'scripts/compose.sh'), `#!/bin/sh\ncase "$*" in\n  *" ps "*) exit 0;;\n  *build*) exit 0;;\n  *) ${inventory};;\nesac\n`);
      return spawnSync('bash', [join(root, 'scripts/scan-images.sh')], {
        encoding: 'utf8', env: { ...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, WAREHOUSE_SCAN_REPORT_DIR: reportDir },
      });
    };
    assert.notEqual(run('exit 1').status, 0, 'enumeration failure must not pass');
    assert.notEqual(run(`echo '${composeConfig({})}'`).status, 0, 'empty inventory must not pass');
    assert.notEqual(run(one).status, 0, 'missing scan report must not pass');
    const report = { SchemaVersion: 2, ArtifactName: 'example.test/image:1', ArtifactType: 'container_image', Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [{ Name: 'example-package', Version: '1.0.0' }] }] };
    const emit = value => scanner(`while [ "$1" != "--output" ]; do shift; done\nshift\nprintf '%s' '${JSON.stringify(value)}' > "$1"`);
    emit({});
    assert.notEqual(run(one).status, 0, 'empty JSON must not pass');
    emit({ ...report, ArtifactName: 'wrong:image' });
    assert.notEqual(run(one).status, 0, 'wrong image must not pass');
    emit({ ...report, Results: [{ Target: 'test OS', Class: 'os-pkgs' }] });
    assert.notEqual(run(one).status, 0, 'result without package inventory must not pass');
    emit({ ...report, Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [] }] });
    assert.notEqual(run(one).status, 0, 'empty package inventory must not pass');
    emit({ ...report, Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [{ Name: 'unversioned' }] }] });
    assert.notEqual(run(one).status, 0, 'unversioned package inventory must not pass');
    emit({ ...report, Results: [...report.Results, { Target: 'unassessed binary', Class: 'lang-pkgs' }] });
    assert.notEqual(run(one).status, 0, 'an unassessed result must not hide behind a valid one');
    emit({ ...report, Results: [{ ...report.Results[0], Vulnerabilities: [{ Severity: 'HIGH' }] }] });
    assert.notEqual(run(one).status, 0, 'findings must fail even when scanner exits zero');
    emit(report);
    assert.equal(run(one).status, 0);
    assert.equal(run(one).status, 0);
    const runs = readdirSync(reportDir);
    assert.equal(runs.length, 12, 'each invocation needs a new directory');
    for (const directory of runs) assert.equal(statSync(join(reportDir, directory)).mode & 0o777, 0o700);
    rmSync(join(root, 'docker/image-exceptions.json'));
    assert.notEqual(run(one).status, 0, 'a missing exception ledger must not pass');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('the scan builds without cache, scans each image once, in full, and names each recipe', () => {
  const root = mkdtempSync(join(tmpdir(), 'warehouse-scan-passes-'));
  try {
    mkdirSync(join(root, 'scripts'));
    mkdirSync(join(root, 'bin'));
    mkdirSync(join(root, 'docker/app'), { recursive: true });
    copyFileSync(new URL('../scripts/scan-images.sh', import.meta.url), join(root, 'scripts/scan-images.sh'));
    copyFileSync(new URL('../scripts/validate-image-report.mjs', import.meta.url), join(root, 'scripts/validate-image-report.mjs'));
    copyFileSync(new URL('../scripts/is-main.mjs', import.meta.url), join(root, 'scripts/is-main.mjs'));
    const log = join(root, 'calls.log');
    // A built service (no image name) and a pulled one; the built image has one
    // HIGH row without a fix, covered only by its recipe's no-fix exception.
    const config = composeConfig({ app: { build: { context: join(root, 'docker/app'), dockerfile: 'Dockerfile' } }, rest: { image: 'example.test/rest:1@sha256:' + 'a'.repeat(64) } });
    const containers = join(root, 'containers.txt');
    writeFileSync(containers, '');
    writeFileSync(join(root, 'scripts/compose.sh'), `#!/bin/sh\necho "compose $*" >> '${log}'\ncase "$*" in\n  *" ps "*) cat '${containers}';;\n  *build*) exit 0;;\n  *) echo '${config}';;\nesac\n`);
    const reportFor = (image, rows) => ({ SchemaVersion: 2, ArtifactName: image, ArtifactType: 'container_image', Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [{ Name: 'libexample', Version: '1.0' }], Vulnerabilities: rows }] });
    const unfixed = { VulnerabilityID: 'CVE-2026-0001', PkgName: 'libexample', InstalledVersion: '1.0', Severity: 'HIGH', Status: 'affected' };
    const reports = {
      'warehouse-scan-test-app': reportFor('warehouse-scan-test-app', [unfixed]),
      ['example.test/rest:1@sha256:' + 'a'.repeat(64)]: reportFor('example.test/rest:1@sha256:' + 'a'.repeat(64), []),
    };
    const fileOf = image => image.replace(/[/:@]/g, '_');
    for (const [image, value] of Object.entries(reports)) {
      writeFileSync(join(root, `${fileOf(image)}.json`), JSON.stringify(value));
      // What a fixed-only (--ignore-unfixed) pass would return: no unfixed rows. A slip back to such a pass then also fails the report check.
      const fixedOnly = { ...value, Results: value.Results.map(result => ({ ...result, Vulnerabilities: result.Vulnerabilities.filter(r => r.FixedVersion) })) };
      writeFileSync(join(root, `${fileOf(image)}.fixedonly.json`), JSON.stringify(fixedOnly));
    }
    writeFileSync(join(root, 'bin/trivy'), `#!/bin/sh\necho "trivy $*" >> '${log}'\nfor arg in "$@"; do image="$arg"; done\nsuffix=\nfor arg in \"$@\"; do [ \"$arg\" = --ignore-unfixed ] && suffix=.fixedonly; done\nout=\nwhile [ "$1" != "--output" ]; do shift; done\nout="$2"\ncp "${root}/$(printf '%s' "$image" | tr '/:@' '___')$suffix.json" "$out"\n`, { mode: 0o700 });
    const ledger = entries => writeFileSync(join(root, 'docker/image-exceptions.json'), JSON.stringify({ schemaVersion: 1, exceptions: entries }));
    const run = () => spawnSync('bash', [join(root, 'scripts/scan-images.sh')], {
      encoding: 'utf8', env: { ...process.env, PATH: `${join(root, 'bin')}:${process.env.PATH}`, WAREHOUSE_SCAN_REPORT_DIR: join(root, 'reports') },
    });
    const entry = { id: 'app-os-no-fix', recipe: 'docker/app/Dockerfile', class: 'no-fix', statuses: ['affected'], severities: ['HIGH'], owner: 'abhiguru', reason: 'Publisher base has no fixed package yet.', reviewed: date(0), expires: date(30) };
    ledger([]);
    const refused = run();
    assert.notEqual(refused.status, 0, 'the unfixed row needs an exception');
    assert.match(refused.stderr, /warehouse-scan-test-app: HIGH\/CRITICAL vulnerabilities remain: 1 row/);
    ledger([{ ...entry, recipe: 'docker/other/Dockerfile' }]);
    assert.notEqual(run().status, 0, 'an exception for another recipe does not cover the row');
    writeFileSync(log, '');
    const stale = { ...entry, id: 'gone-os-no-fix', recipe: 'docker/gone/Dockerfile' };
    ledger([entry, stale]);
    const passed = run();
    assert.equal(passed.status, 0, passed.stderr);
    assert.match(passed.stdout, /accepted for warehouse-scan-test-app: 1 HIGH\/CRITICAL row\(s\) covered by exceptions app-os-no-fix/);
    assert.match(passed.stderr, /Warning: exception gone-os-no-fix .* covered no row in this scan/, 'an unused entry is reported');
    assert.doesNotMatch(passed.stderr, /exception app-os-no-fix .*covered no row/, 'a used entry is not');
    const calls = readFileSync(log, 'utf8').trim().split('\n');
    assert.ok(calls.some(line => /^compose .*build --no-cache$/.test(line)), 'images are built without the build cache');
    const scans = calls.filter(line => line.startsWith('trivy '));
    assert.equal(scans.length, 2, 'one pass per image');
    assert.equal(scans.filter(line => line.includes('--ignore-unfixed')).length, 0, 'no pass uses --ignore-unfixed');
    for (const line of scans) assert.match(line, /--severity HIGH,CRITICAL .*--list-all-pkgs --exit-code 0 --format json --output /);

    // A state whose project has containers is an installation: its images are
    // not rebuilt and re-tagged under it.
    writeFileSync(log, '');
    writeFileSync(containers, '3f2a9c1d8e7b\n');
    const live = run();
    assert.notEqual(live.status, 0, 'a project with containers is refused');
    assert.match(live.stderr, /Refusing: this state's project has containers/);
    assert.ok(!readFileSync(log, 'utf8').includes('build'), 'nothing is built for a live project');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

// TW-BE-009 / TW-BE-010: the validator against the exception ledger.
function check(report, image, { entries, recipe = 'docker/app/Dockerfile', raw } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'warehouse-validate-'));
  try {
    writeFileSync(join(dir, 'report.json'), JSON.stringify(report));
    const args = [validator, join(dir, 'report.json'), image];
    if (entries || raw) {
      writeFileSync(join(dir, 'ledger.json'), raw ?? JSON.stringify({ schemaVersion: 1, exceptions: entries }));
      args.push('--exceptions', join(dir, 'ledger.json'), '--recipe', recipe);
    }
    return spawnSync(process.execPath, args, { encoding: 'utf8' });
  } finally { rmSync(dir, { recursive: true, force: true }); }
}
const image = 'warehouse-test-app';
const row = { VulnerabilityID: 'CVE-2026-0001', PkgName: 'libexample', InstalledVersion: '1.0', Severity: 'HIGH', Status: 'affected' };
// A row whose status says no fix yet but which lists one: only the validator's hasFix() refuses it for a no-fix entry.
const fixedRow = { ...row, VulnerabilityID: 'CVE-2026-0002', Status: 'fixed', FixedVersion: '1.1' };
const report = rows => ({ SchemaVersion: 2, ArtifactName: image, ArtifactType: 'container_image', Results: [{ Target: 'test OS', Class: 'os-pkgs', Packages: [{ Name: 'libexample', Version: '1.0' }], Vulnerabilities: rows }] });
const noFix = { id: 'app-os-no-fix', recipe: 'docker/app/Dockerfile', class: 'no-fix', statuses: ['affected'], severities: ['HIGH'], owner: 'abhiguru', reason: 'Debian has no fixed package for these rows yet.', reviewed: date(0), expires: date(MAX_EXCEPTION_DAYS) };
const advisory = { id: 'app-pending-fix', recipe: 'docker/app/Dockerfile', class: 'advisory', advisories: ['CVE-2026-0002'], packages: ['libexample'], severities: ['HIGH'], owner: 'abhiguru', reason: 'The publisher has not released an image with the fix.', reviewed: date(0), expires: date(30) };

test('TW-BE-009: a HIGH row passes only with a valid exception for its recipe', () => {
  assert.notEqual(check(report([row]), image).status, 0, 'strict mode keeps failing every HIGH row');
  const accepted = check(report([row]), image, { entries: [noFix] });
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.match(accepted.stdout, /1 HIGH\/CRITICAL row\(s\) covered by exceptions app-os-no-fix/);
  assert.equal(check(report([fixedRow]), image, { entries: [advisory] }).status, 0, 'an advisory entry covers a listed fix the publisher has not shipped');
  assert.equal(check(report([]), image, { entries: [] }).status, 0, 'no rows, empty ledger');

  const refused = (rows, entries, why, recipe) => {
    const result = check(report(rows), image, { entries, recipe });
    assert.notEqual(result.status, 0, why);
    return result.stderr;
  };
  assert.match(refused([row], [], 'a row with no exception'), /1 row\(s\) without a valid exception, e\.g\. CVE-2026-0001 libexample 1\.0 \(affected\)/);
  refused([row], [noFix], 'an exception of another recipe', 'docker/other/Dockerfile');
  const fixListedAffected = { ...row, VulnerabilityID: 'CVE-2026-0002', FixedVersion: '1.1' };
  const fixListedNoStatus = { VulnerabilityID: 'CVE-2026-0004', PkgName: 'libexample', InstalledVersion: '1.0', Severity: 'HIGH', FixedVersion: '1.1' };
  refused([fixListedAffected], [noFix], 'a no-fix entry never covers a row with a listed fix, whatever its status');
  refused([fixListedNoStatus], [{ ...noFix, statuses: ['affected', 'unknown'] }], 'a row with no status and a listed fix');
  refused([{ ...row, Severity: 'CRITICAL' }], [noFix], 'a severity the entry does not list');
  refused([{ ...row, Status: 'will_not_fix' }], [noFix], 'a status the entry does not list');
  refused([{ ...fixedRow, VulnerabilityID: 'CVE-2026-0003' }], [advisory], 'an advisory the entry does not name');
  refused([fixedRow, row], [advisory], 'every row needs its own cover');
  refused([row], [{ ...noFix, pkgClass: 'lang-pkgs' }], 'an os-pkgs row is not covered by a lang-pkgs entry');
  refused([fixedRow], [{ ...advisory, packages: ['libother'] }], 'an advisory entry covers its IDs only in the packages it names');
  refused([row], [{ ...noFix, packages: ['linux-libc-dev'] }], 'a no-fix entry with packages covers only those packages');
  assert.equal(check(report([{ ...row, PkgName: 'linux-libc-dev' }]), image, { entries: [{ ...noFix, packages: ['linux-libc-dev'] }] }).status, 0, 'its own package is covered');
  refused([fixedRow], [{ ...advisory, targets: ['usr/share/app/plugins/'] }], 'an entry with targets covers only rows under them');
  const inPlugin = { SchemaVersion: 2, ArtifactName: image, ArtifactType: 'container_image', Results: [{ Target: 'usr/share/app/plugins/x/bin', Class: 'lang-pkgs', Packages: [{ Name: 'libexample', Version: '1.0' }], Vulnerabilities: [fixedRow] }] };
  assert.equal(check(inPlugin, image, { entries: [{ ...advisory, targets: ['usr/share/app/plugins/'] }] }).status, 0, 'a row under a named target is covered');
  refused([row], [{ ...noFix, packages: [] }], 'an empty packages list');
  refused([row], [{ ...noFix, targets: [''] }], 'an empty target');

  const expired = { ...noFix, reviewed: date(-30), expires: date(-1) };
  assert.match(refused([row], [expired], 'an expired entry'), /expired on/);
  assert.match(refused([], [expired], 'an expired entry fails the ledger even when unused'), /expired on/);
  const { owner, ...ownerless } = noFix;
  assert.ok(owner);
  assert.match(refused([row], [ownerless], 'an ownerless entry'), /no named owner/);
  refused([row], [{ ...noFix, owner: ' ' }], 'a blank owner');
  assert.match(refused([row], [{ ...noFix, expires: date(MAX_EXCEPTION_DAYS + 1) }], 'more than 90 days'), /more than 90 days/);
  refused([row], [{ ...noFix, reviewed: date(1), expires: date(30) }], 'a review in the future');
  refused([row], [{ ...noFix, reason: '' }], 'no reason');
  refused([row], [{ ...noFix, recipe: '' }], 'no recipe');
  refused([row], [{ ...noFix, class: 'everything' }], 'an unknown class');
  refused([row], [{ ...noFix, expirse: date(10) }], 'an unknown field');
  refused([row], [noFix, noFix], 'a duplicate id');
  refused([row], [{ ...noFix, expires: '2026-02-30' }], 'an impossible date');
  assert.notEqual(check(report([row]), image, { raw: '{"schemaVersion":1}' }).status, 0, 'a ledger without its list');
  assert.notEqual(check(report([row]), image, { raw: 'not json' }).status, 0, 'an unreadable ledger');
});

test('one full report with a fixable HIGH row fails even when a no-fix entry names the image', () => {
  // The rule the --ignore-unfixed pass used to enforce, now by the full report alone.
  const result = check(report([row, fixedRow]), image, { entries: [noFix] });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /1 row\(s\) without a valid exception, e\.g\. CVE-2026-0002 libexample 1\.0 \(fixed in 1\.1\)/);
  assert.notEqual(check(report([{ ...row, VulnerabilityID: 'CVE-2026-0002', FixedVersion: '1.1' }]), image, { entries: [noFix] }).status, 0, 'a no-fix entry never covers a fixable row with a no-fix status');
  const noStatus = { VulnerabilityID: 'CVE-2026-0004', PkgName: 'libexample', InstalledVersion: '1.0', Severity: 'HIGH', FixedVersion: '1.1' };
  assert.notEqual(check(report([noStatus]), image, { entries: [{ ...noFix, statuses: ['affected', 'unknown'] }] }).status, 0, 'a fixable row with no status is not covered either');
});

test('TW-BE-010: a report with no package results fails unless its exact digest has a no-package-inventory exception', () => {
  const digest = `sha256:${'d'.repeat(64)}`;
  const other = `sha256:${'e'.repeat(64)}`;
  const rest = `example.test/rest:v1@${digest}`;
  const empty = (name, digests = [`example.test/rest@${digest}`]) => ({ SchemaVersion: 2, ArtifactName: name, ArtifactType: 'container_image', Metadata: { RepoDigests: digests } });
  const entry = { id: 'rest-no-package-inventory', recipe: rest, class: 'no-package-inventory', digest, compensatingControls: ['Reachable only through the gateway'], owner: 'abhiguru', reason: 'Static binary; the publisher ships no SBOM for it.', reviewed: date(0), expires: date(30) };
  const opts = (entries, recipe = rest) => ({ entries, recipe });

  assert.notEqual(check(empty(rest), rest).status, 0, 'strict mode rejects an empty report');
  assert.notEqual(check(empty(rest), rest, opts([])).status, 0, 'no exception');
  const accepted = check(empty(rest), rest, opts([entry]));
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.match(accepted.stdout, /no package inventory, accepted by exception rest-no-package-inventory/);
  assert.equal(check({ ...empty(rest), Results: [] }, rest, opts([entry])).status, 0, 'an empty Results list is the same case');

  const moved = `example.test/rest:v1@${other}`;
  assert.notEqual(check(empty(moved, [`example.test/rest@${other}`]), moved, opts([entry], moved)).status, 0, 'another digest under the same name');
  assert.notEqual(check(empty(moved, [`example.test/rest@${other}`]), moved, opts([{ ...entry, recipe: moved }], moved)).status, 0, 'the recipe must carry the entry digest');
  assert.notEqual(check(empty(rest, [`example.test/rest@${other}`]), rest, opts([entry])).status, 0, 'the scanned image must have the digest');
  assert.notEqual(check(empty(rest, []), rest, opts([entry])).status, 0, 'no repository digest recorded');
  assert.notEqual(check(empty(rest), rest, opts([{ ...entry, reviewed: date(-30), expires: date(-1) }])).status, 0, 'an expired exception');
  assert.notEqual(check(empty(rest), rest, opts([{ ...entry, compensatingControls: [] }])).status, 0, 'compensating controls are required');
  const { owner, ...ownerless } = entry;
  assert.ok(owner);
  assert.notEqual(check(empty(rest), rest, opts([ownerless])).status, 0, 'an ownerless exception');
  assert.notEqual(check(empty(rest), rest, opts([{ ...entry, class: 'no-fix', statuses: ['affected'], severities: ['HIGH'], digest: undefined, compensatingControls: undefined }])).status, 0, 'only the no-package-inventory class accepts an empty report');
  const partial = { ...empty(rest), Results: [{ Target: 'bin', Class: 'lang-pkgs' }] };
  assert.notEqual(check(partial, rest, opts([entry])).status, 0, 'a result without inventory is not the no-inventory case');
});

test('the shipped exception ledger is well formed and names recipes that exist', () => {
  const ledger = JSON.parse(readFileSync(join(repo, 'docker/image-exceptions.json'), 'utf8'));
  // Shape and the 90-day rule as of the newest review; the scan applies today's date.
  const newest = Math.max(...ledger.exceptions.map(entry => Date.parse(`${entry.reviewed}T00:00:00Z`)));
  const entries = validateLedger(ledger, newest);
  assert.ok(entries.length > 0);
  const compose = readFileSync(join(repo, 'docker/docker-compose.yml'), 'utf8');
  const pulled = [...compose.matchAll(/^\s+image: (\S+)$/gm)].map(match => match[1]);
  for (const entry of entries) {
    assert.equal(entry.owner, 'abhiguru', `${entry.id}: owner (decision D3)`);
    if (entry.recipe.startsWith('docker/')) assert.ok(existsSync(join(repo, entry.recipe)), `${entry.id}: ${entry.recipe} exists`);
    else assert.ok(pulled.includes(entry.recipe), `${entry.id}: ${entry.recipe} is a Compose image`);
  }
  const rest = entries.find(entry => entry.class === 'no-package-inventory');
  const pin = /^\s+image: (postgrest\/postgrest:v[0-9.]+@sha256:[0-9a-f]{64})$/m.exec(compose)?.[1];
  assert.ok(pin, 'PostgREST is pinned by digest');
  assert.equal(rest?.recipe, pin, 'the PostgREST no-package-inventory exception is bound to the Compose pin');
  assert.ok(rest.compensatingControls.length >= 2);
});
