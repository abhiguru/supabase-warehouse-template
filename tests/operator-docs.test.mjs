import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');

test('the troubleshooting guide acts only on the selected installation and has no reset', () => {
  const guide = read('docs/TROUBLESHOOTING.md');
  // Fixed container names belong to some other Compose project on the host (a separate
  // Supabase deployment, another installation); scripts/compose.sh selects this one by
  // WAREHOUSE_STATE_DIR and refuses another checkout's project.
  assert.doesNotMatch(guide, /docker (logs|exec|restart|stop|start|rm) (-\S+ )*supabase-/, 'a docker command names a fixed supabase-* container');
  assert.doesNotMatch(guide, /\bdown -v\b/, 'a reset that deletes the volumes');
  assert.doesNotMatch(guide, /^#+ .*Reset Everything/m);
  assert.match(guide, /export WAREHOUSE_STATE_DIR=/);
  assert.match(guide, /bash scripts\/compose\.sh/);
  // `docker stats` with no IDs lists every container on the host: never pass it an unchecked `ps -q`.
  assert.doesNotMatch(guide, /docker stats[^\n]*\$\(bash scripts\/compose\.sh ps -q\)/, 'docker stats on an unchecked ps -q');
  assert.match(guide, /ids=\$\(bash scripts\/compose\.sh ps -q\); \[ -n "\$ids" \] && docker stats --no-stream \$ids/);
  for (const heading of ['In-place restore of the same instance', 'Recover a lost host from the USB drive', 'Rerun and upgrade']) {
    assert.ok(read('docs/OPERATOR_INSTALL.md').includes(`# ${heading}`), `OPERATOR_INSTALL.md has no "${heading}" heading`);
    assert.ok(guide.includes(heading), `the guide does not point at "${heading}"`);
  }
});

test('the API contract guide names commands that exist', () => {
  const guide = read('docs/API_CONTRACT.md');
  const scripts = JSON.parse(read('package.json')).scripts;
  // `npm run test:api` was removed with the historical API demos.
  assert.doesNotMatch(guide, /test:api/);
  assert.equal(scripts['test:api'], undefined);
  assert.equal(scripts['check:contract'], 'node scripts/check-mobile-contract.mjs');
  assert.match(guide, /npm run check:contract -- \.\.\/rn-warehouse-template/);
  for (const name of [...guide.matchAll(/npm run ([a-z:-]+)/g)].map(match => match[1])) {
    assert.ok(scripts[name], `docs/API_CONTRACT.md names npm run ${name}, which package.json does not have`);
  }
});

test('the container security record names commands that exist', () => {
  const guide = read('docs/CONTAINER_SECURITY.md');
  const scripts = JSON.parse(read('package.json')).scripts;
  // `npm run test:api` was removed with the historical API demos; the contract check is check:contract,
  // described in docs/API_CONTRACT.md and docs/RELEASE_CHECKLIST.md (the old acceptance narrative that named it here is gone).
  assert.doesNotMatch(guide, /test:api/);
  for (const name of [...guide.matchAll(/npm run ([a-z:-]+)/g)].map(match => match[1])) {
    assert.ok(scripts[name], `docs/CONTAINER_SECURITY.md names npm run ${name}, which package.json does not have`);
  }
});

// The OTP section of docs/OPERATOR_INSTALL.md, kept to what the code and the migrations do
// (TW-BE-014, TW-CFG-001, TW-CFG-002, TW-CFG-005, X-7).
const otpSection = () => {
  const guide = read('docs/OPERATOR_INSTALL.md');
  const from = guide.indexOf('## Authentication and OTP limits');
  const to = guide.indexOf('**Sessions.**', from);
  assert.ok(from > 0 && to > from, 'the OTP section was found');
  return guide.slice(from, to);
};

test('the OTP cleanup is described as it runs, and pg_cron is named only where a migration creates it', () => {
  // TW-BE-014: the installation does not install pg_cron; the only OTP clean-up is the 7-day ephemeral_auth retention rule
  // (migration 123 removed the every-100th-insert trigger), run by the daily checker or the manual retention command.
  const createsPgCron = readdirSync(new URL('../migrations/', import.meta.url))
    .some(name => /CREATE\s+EXTENSION[^;]*pg_cron/i.test(read(`migrations/${name}`)));
  // The baseline does not create it; the guide may name it only in the upgrade note about migration 106 (the removal).
  if (!createsPgCron) {
    const stray = read('docs/OPERATOR_INSTALL.md').split(/\n\s*\n/).filter(paragraph => /pg_cron/.test(paragraph) && !/migration 106/i.test(paragraph));
    assert.deepEqual(stray, []);
  }
  const section = otpSection();
  assert.match(section, /OTPs expire after 5 minutes/);
  assert.match(section, /not removed on a database timer/);
  assert.match(section, /checker's daily run/);
  assert.match(section, /7-day `ephemeral_auth` retention\s+rule deletes expired OTP rows older than 7 days/);
  assert.doesNotMatch(section, /100th/);
  assert.match(section, /retention:apply/);
  assert.doesNotMatch(read('migrations/00000000000123_slim_round2.sql').replace(/^--.*$/gm, ''), /CREATE\s+TRIGGER\s+trigger_auto_cleanup_otps/i);
  assert.match(read('docs/OPERATOR_INSTALL.md'), /## Retention\n\nRetention is the owner-approved clean-up/);
});

test('the OTP section names the HMAC-SHA256 construction and what a key rotation does to pending codes', () => {
  // TW-CFG-001 (owner decision D13): HMAC-SHA256 over phone:code:request id, keyed with the JWT secret.
  const section = otpSection();
  assert.match(section, /HMAC-SHA256 over `phone:code:request id`/);
  assert.match(section, /never as a bare\s+SHA-256/);
  assert.match(section, /rotation changes that secret[\s\S]*codes issued before it stop\s+verifying/);
  assert.match(read('scripts/rotate-auth.sql'), /Pending challenges hold HMACs of the previous secret/);
});

test('the OTP section states the provider request-ID contract and the success without an ID', () => {
  // TW-CFG-002 / TW-CFG-003 / X-3: the contract identity mirrors.
  const section = otpSection();
  assert.match(section, /`message`\. The facility trims it, accepts 1 to 255 characters/);
  assert.match(section, /`otp_verifications\.msg91_request_id`/);
  assert.match(section, /never returned to\s+a client or written to a log/);
  assert.match(section, /a blank or non-text one, one over\s+255 characters/);
  assert.match(section, /with a\s+failing status as `provider_unavailable`/);
  assert.match(section, /`success_no_id`/);
  assert.match(section, /no second SMS is sent/);
  assert.match(section, /`type`\s+and `status` disagree/);
});

test('the OTP section documents the provider-request ceiling, the timeout rule and the no-send switch', () => {
  // TW-CFG-005 (owner decision D15).
  const section = otpSection();
  assert.match(section, /`otp_daily_provider_attempt_cap`, \*\*off until you set it\*\*/);
  assert.match(section, /`provider_ambiguous`/);
  assert.match(section, /warehouse_security\.otp_provider_attempts/);
  assert.match(section, /A cap of text `0` is accepted and blocks every send/);
  // The one rule for which values are placeholders is described where fixtures are installed (X-7).
  const guide = read('docs/OPERATOR_INSTALL.md');
  assert.match(guide, /\*\*Test installations \(CI, review fixtures\)\.\*\*/);
  assert.match(guide, /isolated-no-delivery-key/);
  assert.match(guide, /reserved `\.test`\s+domain/);
  assert.match(guide, /without a route to the internet/);
});

test('the Compose requirement is a capability, as in the identity runbook, and doctor checks it', () => {
  const guide = read('docs/OPERATOR_INSTALL.md');
  assert.match(guide, /The requirement is a Compose plugin whose `docker compose up` accepts\s+`--wait-timeout`/);
  assert.match(guide, /Docker Compose v2\.40\.3 with Docker Engine 29\.9\.1/);
  assert.match(guide, /Docker Compose v5\.6\.0 with Docker Engine 29\.9\.1 \(the development host; verified\s+for this service and for the facility backend\)/);
  assert.doesNotMatch(guide, /5\.5\.1/);
  assert.doesNotMatch(guide, /central-identity-template/, 'a link to a private repository');
  // No concrete 5.x incompatibility is known (X-6), so the advice to replace a 5.x plugin is gone.
  assert.doesNotMatch(guide, /replace (any|a) 5\.x|Compose reports a 5\.x|install an available 2\.x/i);
  assert.doesNotMatch(guide, /pick a 2\.x build/);
  assert.doesNotMatch(guide, /^- Linux x86-64; Ubuntu/m, 'two bullets start with Linux x86-64');
});

test('the guide has a section for several facilities on one host that names --gateway-port', () => {
  const guide = read('docs/OPERATOR_INSTALL.md');
  assert.ok(guide.includes('## Several facilities on one host'));
  assert.match(guide, /--gateway-port 18001/);
  assert.doesNotMatch(guide.slice(guide.indexOf('## Several facilities')), /--admin-phone 91[0-9]{10}/, 'a real-looking phone number in the example');
  assert.match(guide, /last part of the state path|different last part/);
  assert.match(guide, /USB backup serves one installation per host/);
  assert.ok(guide.includes('(#several-facilities-on-one-host)'));
});

test('no heading occurs twice in the operator runbook, the container security record or the monitoring guide', () => {
  // A merge of a branch that carries commits main took as a squash can add a whole section a second time without a conflict.
  for (const file of ['docs/OPERATOR_INSTALL.md', 'docs/CONTAINER_SECURITY.md', 'docs/MONITORING.md']) {
    let fenced = false;
    const seen = new Map();
    for (const line of read(file).split('\n')) {
      if (/^```/.test(line)) { fenced = !fenced; continue; }
      if (fenced || !/^#{1,6} /.test(line)) continue;
      seen.set(line, (seen.get(line) ?? 0) + 1);
    }
    const repeated = [...seen].filter(([, count]) => count > 1).map(([heading]) => heading);
    assert.deepEqual(repeated, [], `${file} repeats a heading`);
  }
});
