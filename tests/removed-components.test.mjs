import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;
const read = path => readFileSync(root + path, 'utf8');
const SELF = 'tests/removed-components.test.mjs';
const BINARY = /\.(?:png|jpe?g|ico|woff2?|zip|gz|tgz|pdf)$/i;

// Every path git tracks, also those whose file is gone from the working tree (a forgotten `git rm`).
function indexed() {
  const files = spawnSync('git', ['ls-files', '-z', '--cached'], { cwd: root, encoding: 'utf8' }).stdout.split('\0').filter(Boolean);
  assert.ok(files.length > 100, 'the file list was read');
  return files;
}

function tracked() {
  const files = spawnSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: root, encoding: 'utf8' }).stdout.split('\0').filter(Boolean);
  assert.ok(files.length > 100, 'the file list was read');
  return files.filter(file => existsSync(root + file));
}

// One entry per component that was removed.
//   gone       paths that must not exist.
//   goneTree   tracked files must not match this pattern (nothing may be left under the removed directories).
//   scan       no tracked file may contain `pattern`, except the `allowed` files (each with the reason it may; each
//              must still match `pattern`, so a stale exemption fails) and the files under `skipPrefix`.
//              `lock` skips package-lock.json; `inNames` also tests the file name.
//   clean      named files that must not contain `pattern`.
//   checks     bespoke assertions that go beyond naming the component.
//   mustExist  files that are expected to stay (the replacement, or what the checks read) and have no scan entry.
// Every allowed and mustExist file must exist, so a table entry cannot outlive its file.
const components = [
  {
    name: 'Gotenberg (replaced by docker/pdf-renderer)',
    gone: ['docker/gotenberg', 'LICENSES/gotenberg', 'scripts/retire-gotenberg.sh', 'tests/retire-gotenberg.test.mjs'],
    scan: {
      pattern: /gotenberg/i, lock: true,
      // The renderer says in its own files which Gotenberg settings it keeps.
      skipPrefix: 'docker/pdf-renderer/',
      allowed: new Map([
        ['CHANGELOG.md', 'history'],
        ['tests/compose-networks.test.mjs', 'asserts the service is gone'],
        [SELF, 'this test'],
      ]),
    },
    clean: [{ files: ['docker/docker-compose.yml', 'docker/docker-compose.override.yml', 'functions/main/worker-env.ts', 'health-check.sh', 'scripts/backup.sh', '.github/workflows/ci.yml', 'docker/image-exceptions.json', '.github/dependabot.yml'], pattern: /gotenberg/i }],
  },
  {
    name: 'Grafana (no dashboards; alerts go to the facility Slack)',
    gone: ['docker/grafana', 'docker/volumes/grafana', 'LICENSES/grafana', 'scripts/grafana-check.sh'],
    scan: {
      pattern: /grafana/i, lock: true, inNames: true,
      allowed: new Map([
        ['CHANGELOG.md', 'history'],
        [SELF, 'this test'],
      ]),
    },
    clean: [{ files: ['docker/docker-compose.yml', 'docker/docker-compose.override.yml', 'package.json', '.github/workflows/ci.yml', '.github/dependabot.yml', '.env.example', 'scripts/configure.mjs', 'scripts/db-roles.mjs', 'scripts/image-recipes.mjs', 'docker/image-exceptions.json'], pattern: /grafana/i }],
  },
  {
    name: 'wal-g (backups are pg_dump, archive_mode is off)',
    gone: ['docker/postgres/walg.go.mod', 'docker/postgres/walg.go.sum', 'LICENSES/wal-g'],
    checks: [['the database Dockerfile has no walg stage and does not mention wal-g', () => {
      const dockerfile = read('docker/postgres/Dockerfile');
      assert.doesNotMatch(dockerfile, /\bAS walg\b/i, 'no walg build stage');
      assert.doesNotMatch(dockerfile, /wal-g|walg/i, 'the official image carries no wal-g, so the recipe does not mention it');
    }]],
  },
  {
    name: 'GoTrue (sessions come from SQL behind the Edge Functions operator-otp and central-exchange)',
    gone: ['docker/auth', 'LICENSES/auth'],
    goneTree: /^(?:docker\/auth|LICENSES\/auth)\//,
    scan: {
      // Whole word: DB_PASSWORD_AUTHENTICATOR is a different, live variable.
      pattern: /DB_PASSWORD_AUTH(?![A-Z_])/,
      allowed: new Map([
        ['CHANGELOG.md', 'history'],
        [SELF, 'this test'],
        ['tests/configure.test.mjs', 'checks the variable is gone'],
        ['tests/db-roles.test.mjs', 'checks the variable is harmless'],
        ['scripts/configure.mjs', 'removes the line from an older state on every setup run'],
      ]),
    },
    checks: [
      ['no Compose file has an auth service, and Kong has no route to one', () => {
        for (const file of ['docker/docker-compose.yml', 'docker/docker-compose.override.yml']) {
          assert.doesNotMatch(read(file), /^  auth:\s*$/m, file);
          assert.doesNotMatch(read(file), /GOTRUE_/, file);
        }
        assert.doesNotMatch(read('docker/kong.yml'), /auth:9999|\/auth\/v1/);
      }],
      ['the role supabase_auth_admin does not exist on the new image: setup touches nothing about it, and the baseline creates and grants nothing for it', () => {
        assert.doesNotMatch(read('scripts/configure-db-roles.sql'), /supabase_auth_admin/);
        // Only pg_dump's comment headers name it ("Owner: supabase_auth_admin"); no statement does.
        const statements = read('migrations/00000000000000_baseline.sql').split('\n').filter(line => !line.startsWith('--') && /supabase_auth_admin/.test(line));
        assert.deepEqual(statements, []);
      }],
      ['.env.example has no GoTrue mail, SMS or signup setting', () => {
        const text = read('.env.example');
        for (const key of [/^\s*#?\s*SMTP_/m, /^\s*#?\s*MAILER_/m, /^\s*#?\s*ADDITIONAL_REDIRECT_URLS/m, /^\s*#?\s*ENABLE_\w*SIGNUP/m]) assert.doesNotMatch(text, key);
      }],
    ],
  },
  {
    name: 'Studio and postgres-meta (they ran SQL without a login)',
    gone: ['docker/studio', 'docker/postgres-meta', 'LICENSES/postgres-meta', 'scripts/studio-check.sh'],
    clean: [{ files: ['package.json', '.github/workflows/ci.yml', '.github/dependabot.yml', '.env.example', 'docker/image-exceptions.json'], pattern: /studio|postgres-meta/i }],
  },
  {
    name: 'imgproxy (the app reads photos through signed URLs)',
    gone: ['docker/imgproxy', 'LICENSES/imgproxy'],
    goneTree: /^(?:docker\/imgproxy|LICENSES\/imgproxy)\//,
    scan: {
      pattern: /imgproxy/i,
      allowed: new Map([
        ['CHANGELOG.md', 'history'],
        [SELF, 'this test'],
      ]),
    },
    clean: [{ files: ['docker/docker-compose.yml', 'docker/docker-compose.override.yml'], pattern: /imgproxy/i }, { files: ['.env.example'], pattern: /IMGPROXY/ }],
    checks: [
      ['Storage has image transformation off', () => {
        const compose = read('docker/docker-compose.yml');
        assert.match(compose, /ENABLE_IMAGE_TRANSFORMATION: "false"/);
        assert.doesNotMatch(compose, /IMGPROXY_URL/);
      }],
      ['the bucket customer-images is no longer created, and configure removes an empty one', () => {
        const sql = read('scripts/configure-storage.sql');
        assert.doesNotMatch(sql, /INSERT INTO storage\.buckets[^;]*customer-images/);
        assert.match(sql, /DELETE FROM storage\.buckets WHERE id='customer-images'/);
        assert.match(sql, /RAISE EXCEPTION 'The bucket customer-images still holds files/);
      }],
    ],
  },
  {
    // Prometheus, Alertmanager and the Postgres, node and cAdvisor exporters were replaced by scripts/watch.mjs, run by a
    // systemd timer (docs/MONITORING.md). The `clean` lists name the files that must not mention them.
    name: 'monitoring stack (replaced by the checker scripts/watch.mjs)',
    gone: [
      'docker/prometheus', 'docker/alertmanager', 'docker/postgres-exporter', 'docker/node-exporter', 'docker/cadvisor',
      'docker/prometheus.yml', 'docker/alert-rules.yml', 'docker/alert-rules.test.yml', 'docker/alertmanager.yml', 'docker/alertmanager.slack.yml',
      'scripts/start-monitoring.sh', 'scripts/monitoring-check.sh', 'scripts/alert-rules-check.sh', 'scripts/monitoring-config.mjs', 'scripts/backup-metrics.sh',
      'tests/alert-rules.test.mjs', 'tests/alertmanager-delivery.test.mjs', 'tests/monitoring-config.test.mjs', 'tests/start-monitoring.test.mjs',
      'LICENSES/prometheus', 'LICENSES/alertmanager', 'LICENSES/postgres-exporter', 'LICENSES/node-exporter', 'LICENSES/cadvisor',
    ],
    mustExist: ['scripts/watch.mjs', 'scripts/watch-timer.sh', 'scripts/watch-daily.sh'],
    clean: [
      {
        files: ['package.json', '.github/workflows/ci.yml', '.github/dependabot.yml', '.env.example', 'scripts/compose.sh',
          'scripts/db-roles.mjs', 'scripts/configure-db-roles.sql', 'scripts/db-roles.sh', 'scripts/rotate-db-passwords.sh', 'scripts/build-images.sh',
          'scripts/image-recipes.mjs', 'scripts/scan-images.sh', 'docker/image-exceptions.json', 'docker/volumes/db/roles.sql', 'setup.sh', 'start.sh', 'stop.sh'],
        pattern: /prometheus|alertmanager|cadvisor|node-exporter|postgres-exporter|start-monitoring|monitoring-check|alert-rules|test:monitoring/i,
      },
      // scripts/configure.mjs is not in the list above: its message names the old files it removes on a rerun.
      { files: ['scripts/configure.mjs'], pattern: /start-monitoring|monitoring-check|alert-rules|test:monitoring/i },
      { files: ['.env.example', 'scripts/db-roles.mjs', 'scripts/configure-db-roles.sql', 'docker/volumes/db/roles.sql', 'scripts/rotate-db-passwords.sh', 'scripts/db-roles.sh'], pattern: /DB_PASSWORD_MONITORING|monitoring_verifier/ },
    ],
    checks: [
      ['no docker file name looks like the monitoring stack', () => {
        assert.deepEqual(readdirSync(root + 'docker').filter(name => /alert|prometheus|exporter|cadvisor/i.test(name)), []);
      }],
      ['no Compose service has the monitoring profile, a monitoring volume or a monitoring port', () => {
        for (const file of ['docker/docker-compose.yml', 'docker/docker-compose.override.yml']) {
          const text = read(file);
          assert.doesNotMatch(text, /profiles:\s*\[[^\]]*"monitoring"/, `${file} has a monitoring profile`);
          assert.doesNotMatch(text, /^  (?:prometheus|alertmanager|postgres-exporter|node-exporter|cadvisor):/m, `${file} defines a monitoring service`);
          assert.doesNotMatch(text, /prometheus_data|WAREHOUSE_(?:MONITORING|METRICS|ALERTMANAGER)_PATH|KONG_STATUS_LISTEN|\b8100\b/, file);
        }
        assert.doesNotMatch(read('docker/kong.yml'), /prometheus|status_code_metrics/);
      }],
      ['the checker is wired in: setup, start and restore-host print the timer command, doctor warns, CI runs one pass', () => {
        assert.ok(existsSync(root + 'scripts/watch.mjs') && existsSync(root + 'scripts/watch-timer.sh') && existsSync(root + 'scripts/watch-daily.sh'));
        assert.match(read('setup.sh'), /watch-timer\.sh" hint/);
        assert.match(read('setup.sh'), /WAREHOUSE_STATE_DIR="\$STATE" bash "\$ROOT\/scripts\/watch-timer\.sh" hint/, 'the hint gets the normalised state');
        assert.doesNotMatch(read('setup.sh'), /^echo .*sudo bash/m, 'the install command is printed once, by hint');
        assert.match(read('start.sh'), /WAREHOUSE_STATE_DIR="\$STATE" bash "\$ROOT\/scripts\/watch-timer\.sh" hint/);
        assert.match(read('scripts/restore-host.sh'), /sudo bash scripts\/watch-timer\.sh install --state \$state/);
        assert.match(read('stop.sh'), /node scripts\/watch\.mjs mute <minutes>/);
        assert.match(read('scripts/doctor.mjs'), /checkerWarnings/);
        assert.match(read('.github/workflows/ci.yml'), /node scripts\/watch\.mjs run\n/);
        assert.doesNotMatch(read('migrations/00000000000000_baseline.sql'), /warehouse_monitoring/, 'the baseline neither creates nor grants the dropped role');
      }],
    ],
  },
];

for (const c of components) {
  test(`${c.name}: the removed paths are gone`, () => {
    for (const path of c.gone) assert.equal(existsSync(root + path), false, `${path} is removed`);
    if (c.goneTree) assert.deepEqual(indexed().filter(file => c.goneTree.test(file)), []);
  });

  const allowedFiles = [...(c.scan?.allowed.keys() ?? []), ...(c.mustExist ?? [])];
  if (allowedFiles.length) {
    test(`${c.name}: every file that may still name it, or that the checks read, exists`, () => {
      for (const file of allowedFiles) assert.ok(existsSync(root + file), `${file} no longer exists: remove it from the table`);
      // An exemption that no longer matches is stale: it would silently cover a future mention.
      for (const file of c.scan?.allowed.keys() ?? []) {
        assert.ok(c.scan.pattern.test(read(file)) || (c.scan.inNames && c.scan.pattern.test(file)), `${file} no longer names ${c.name}: remove it from the allow-list`);
      }
    });
  }

  if (c.scan) {
    const { pattern, allowed, skipPrefix, lock, inNames } = c.scan;
    test(`${c.name}: no file names it except ${[...allowed.keys()].join(', ')}`, () => {
      const found = [];
      for (const file of tracked()) {
        if (BINARY.test(file) || allowed.has(file) || (lock && file === 'package-lock.json')) continue;
        if (skipPrefix && file.startsWith(skipPrefix)) continue;
        if (pattern.test(read(file)) || (inNames && pattern.test(file))) found.push(file);
      }
      assert.deepEqual(found, [], `these files still name ${c.name}`);
    });
  }

  for (const { files, pattern } of c.clean ?? []) {
    test(`${c.name}: ${files.length} named file(s) do not match ${pattern}`, () => {
      for (const file of files) assert.doesNotMatch(read(file), pattern, file);
    });
  }

  for (const [title, check] of c.checks ?? []) test(`${c.name}: ${title}`, check);
}
