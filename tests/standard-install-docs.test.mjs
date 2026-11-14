// docs/STANDARD_INSTALL.md (WH-136) is a script a technician types. These tests pin it to the scripts it names: every command exists, every
// option and sub-command it uses is one the script accepts at this commit, every link and anchor resolves, the setup command's legal and
// grievance options are the ones scripts/legal.mjs takes (and the guide's own example values pass its checks), and the "Before you start"
// list of the README covers what the guide asks the technician to have. A rename in setup.sh or a script then fails here, not on an
// install day. The guide run on a real machine is not covered (RELEASE_CHECKLIST.md, "Last tested").
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { LEGAL_OPTIONS } from '../scripts/legal.mjs';

const repo = fileURLToPath(new URL('..', import.meta.url));
const read = path => readFileSync(join(repo, path), 'utf8');
const guide = read('docs/STANDARD_INSTALL.md');
const codeBlocks = [...guide.matchAll(/```(?:bash)?\n([\s\S]*?)```/g)].map(m => m[1]);
// Commands as typed: backslash continuations joined, comments and blank lines dropped.
const commands = codeBlocks.join('\n').replace(/\\\n\s*/g, ' ').split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
const slug = heading => heading.toLowerCase().replace(/`/g, '').replace(/[^\p{L}\p{N} _-]/gu, '').trim().replace(/ /g, '-');
const anchors = file => new Set(read(file).split('\n').filter(l => /^#{1,6} /.test(l)).map(l => slug(l.replace(/^#+ /, ''))));

test('the setup command of step 4 uses only options setup.sh accepts, each with a value, and the legal options are legal.mjs\'s', () => {
  const setup = commands.find(c => /bash setup\.sh --operator/.test(c));
  assert.ok(setup, 'step 4 has the setup command');
  const used = [...setup.matchAll(/(?:^| )(--[a-z0-9-]+)(?= |$)/g)].map(m => m[1]);
  const source = read('setup.sh');
  const accepted = new Set([...source.matchAll(/^\s+((?:--[a-z0-9-]+\|?)+)\)/gm)].flatMap(m => m[1].split('|').filter(Boolean)));
  assert.match(source, /if \[\[ "\$\{1:-\}" != --operator \]\]/, 'setup.sh insists on --operator as its first argument');
  for (const option of used.filter(o => o !== '--operator')) assert.ok(accepted.has(option), `setup.sh does not take ${option}`);
  assert.ok(used.includes('--state-dir') && used.includes('--api-url') && used.includes('--provider-env') && used.includes('--admin-phone'), 'the required options are in the command');
  for (const option of Object.keys(LEGAL_OPTIONS)) assert.ok(used.includes(option), `the guide's setup command leaves out ${option}`);
  // The guide's prose lists the six legal and grievance options as "the six --legal-* and --grievance-* values".
  assert.match(guide, /The six `--legal-\*` and `--grievance-\*` values/);
  assert.equal(Object.keys(LEGAL_OPTIONS).length, 6);
  // Optional options the guide tells the reader to leave out or swap exist too.
  for (const option of ['--heartbeat-url-file', '--letterhead-file']) assert.ok(accepted.has(option));
  assert.match(setup, /--letterhead-file off/);
  assert.match(source, /--letterhead-file\) LETTERHEAD_ARG/);
  assert.match(source, /\[\[ "\$2" != ask \]\]/, 'letterhead and webhook files accept the word ask; off is read by configure');
});

test('the example legal and grievance values in step 4 pass the checks setup.sh runs before it starts anything', () => {
  const setup = commands.find(c => /bash setup\.sh --operator/.test(c));
  const args = [];
  for (const [option] of Object.entries(LEGAL_OPTIONS)) {
    const m = new RegExp(`${option} (?:'([^']*)'|(\\S+))`).exec(setup);
    assert.ok(m, `the command gives ${option} a value`);
    args.push(`${option}=${m[1] ?? m[2]}`);
  }
  const r = spawnSync('node', [join(repo, 'scripts/legal.mjs'), 'check', ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr + r.stdout);
  const parsed = JSON.parse(r.stdout);
  assert.equal(Object.keys(parsed).length, 6, 'all six reach the database as one object');
  assert.equal(parsed.grievanceEmail, 'grievance@example.in');
});

test('every script the guide runs exists, and so do the sub-commands and options it gives it', () => {
  const expectations = [
    ['scripts/tunnel.sh', ['create', 'install-service', 'status', '--state']],
    ['scripts/lan.sh', ['on', 'status', 'auto']],
    ['scripts/backup-key-escrow.sh', ['show']],
    ['scripts/backup-usb.sh', ['setup', 'status', '--state', '--enroll']],
    ['scripts/watch-timer.sh', ['install', 'status', '--state']],
    ['scripts/doctor.mjs', ['--local']],
  ];
  const named = new Set(commands.flatMap(c => [...c.matchAll(/(?:bash|node) (scripts\/[a-z0-9-]+\.(?:sh|mjs))/g)].map(m => m[1])));
  for (const [script] of expectations) assert.ok(named.has(script), `the guide no longer runs ${script}; update this test`);
  for (const script of named) assert.ok(existsSync(join(repo, script)), `${script} does not exist`);
  assert.ok(existsSync(join(repo, 'upgrade.sh')) && /bash upgrade\.sh vX\.Y\.Z/.test(guide));
  for (const [script, words] of expectations) {
    const source = read(script);
    for (const word of words) {
      const pattern = word.startsWith('--') ? new RegExp(`${word}\\b`) : new RegExp(`(?:^|[\\s|(])${word}(?:\\)|\\]|\\||\\s|$)`, 'm');
      assert.match(source, pattern, `${script} does not know "${word}"`);
    }
    // Every invocation in the guide uses only words from the table above, so a new sub-command in the guide has to be added here.
    for (const c of commands.filter(c => c.includes(script))) {
      const after = c.split(script)[1].trim().split(/\s+/).filter(w => /^[a-z-]+$/.test(w) || w.startsWith('--'));
      for (const w of after) assert.ok(words.includes(w) || /^--?[a-z]/.test(w) && words.includes(w), `${script} ${w}: not in the list this test pins`);
    }
  }
  // Commands that are shell programs of the installation, not scripts: package names.
  assert.match(commands.join('\n'), /apt-get install -y ca-certificates curl git openssl util-linux xz-utils dnsutils tmux rsync/);
  assert.match(read('docs/OPERATOR_INSTALL.md'), /`flock`\), and `dig` \(package `dnsutils`\)/);
});

test('Node, the SMS provider file and the state paths in the guide agree with the checks that read them', () => {
  const engine = JSON.parse(read('package.json')).engines.node;
  assert.equal(engine, '>=22.18.0');
  assert.match(guide, /prints v22\.18 or newer/);
  const nodePinned = /^NODE=(v22\.\d+\.\d+)/m.exec(guide)[1];
  assert.equal(nodePinned, /^NODE=(v22\.\d+\.\d+)/m.exec(read('docs/OPERATOR_INSTALL.md'))[1], 'the same Node release as the reference');
  assert.ok(Number(nodePinned.split('.')[1]) >= 18);
  // The four values and the provider line of the msg91.env block are the keys doctor.mjs and configure.mjs read.
  const block = /cat > msg91\.env <<'EOF'\n([\s\S]*?)\nEOF/.exec(guide)[1];
  const keys = block.split('\n').map(l => l.split('=')[0]);
  assert.deepEqual(keys, ['SMS_PROVIDER', 'MSG91_AUTH_KEY', 'MSG91_TEMPLATE_ID', 'MSG91_PE_ID', 'MSG91_SENDER_ID']);
  assert.match(read('scripts/doctor.mjs'), /\['SMS_PROVIDER', 'MSG91_AUTH_KEY', 'MSG91_TEMPLATE_ID', 'MSG91_PE_ID', 'MSG91_SENDER_ID'\]/);
  assert.match(block, /SMS_PROVIDER=msg91/);
  // The Flow variable named in step 10 is the one the provider sends.
  assert.match(guide, /Flow variable `OTP`/);
  assert.match(read('functions/operator-otp/provider.ts'), /\bOTP\b/);
  // The state path is the same in every step, and setup's own default is not used.
  for (const c of commands.filter(c => /WAREHOUSE_STATE_DIR=|--state \/srv/.test(c))) assert.match(c, /\/srv\/warehouse\/acme/);
  // The guide ends step 4 with the line setup prints.
  assert.ok(read('setup.sh').includes('Operator services are healthy on the local gateway.') || read('scripts/start.sh')?.includes?.('Operator services are healthy on the local gateway.') || spawnSync('grep', ['-rlF', 'Operator services are healthy on the local gateway.', join(repo, 'scripts'), join(repo, 'setup.sh'), join(repo, 'start.sh')]).status === 0);
});

test('the headings are steps 1 to 11 in order, and every "step N" the guide mentions is the step it means', () => {
  const headings = guide.split('\n').filter(l => /^## /.test(l));
  const steps = headings.filter(h => /^## \d+\. /.test(h)).map(h => h.replace(/^## /, ''));
  assert.deepEqual(steps.map(h => Number(h.split('.')[0])), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
  const title = n => steps[n - 1].toLowerCase();
  const claims = [[4, /setup/], [6, /tunnel/], [7, /fallback/], [8, /usb backup/], [9, /monitoring/], [3, /release/], [5, /health/]];
  for (const [n, word] of claims) assert.match(title(n), word, `step ${n}`);
  // Each place that points at a step: the fragments below say what the step is, and the number must match.
  const refs = [...guide.matchAll(/step (\d+)(?:'s)?/gi)].map(m => ({ n: Number(m[1]), at: m.index }));
  for (const { n, at } of refs) {
    const around = guide.slice(Math.max(0, at - 90), at + 40).toLowerCase();
    if (/api-url|setup of step|run step/.test(around)) assert.equal(n, 4, around);
    if (/route|hostname you will route/.test(around)) assert.equal(n, 6, around);
    if (/fallback address|network fallback|\(step \d\)/.test(around) && /fallback/.test(around)) assert.equal(n, 7, around);
    if (/off-host copy is expected until/.test(around)) assert.equal(n, 8, around);
    if (/stop after step/.test(around)) assert.equal(n, 3, around);
  }
  for (const section of ['Before you start']) assert.ok(guide.includes(section));
  assert.ok(headings.includes('## After the install'));
});

test('every link in the guide resolves to a file, and every anchor to a heading of it', () => {
  const links = [...guide.matchAll(/\]\(([^)\s]+)\)/g)].map(m => m[1]).filter(l => !/^https?:/.test(l));
  assert.ok(links.length > 20);
  for (const link of links) {
    const [file, anchor] = link.split('#');
    const target = file ? resolve(repo, 'docs', file) : join(repo, 'docs/STANDARD_INSTALL.md');
    assert.ok(existsSync(target), `${link}: no such file`);
    if (anchor) assert.ok(anchors(target.slice(repo.length)).has(anchor), `${link}: no heading with that anchor`);
  }
  // The README's own link to this guide, and the section the guide sends the reader to first.
  assert.match(read('README.md'), /docs\/STANDARD_INSTALL\.md/);
  assert.ok(anchors('README.md').has('before-you-start'));
});

test('the README\'s "Before you start" list holds what the guide asks the technician to have in hand', () => {
  const list = /^## Before you start\n([\s\S]*?)^## /m.exec(read('README.md'))[1];
  for (const [word, why] of [[/Cloudflare/, 'the domain and account of step 6'], [/MSG91/, 'the SMS account of steps 2 and 4'], [/DLT/, 'the DLT registration the guide warns about'],
    [/Slack/, 'the alert webhook file of step 2'], [/heartbeat/i, 'the optional heartbeat file'], [/Ubuntu 24\.04/, 'the machine of step 1'],
    [/exFAT/, 'the USB drive of step 8'], [/backup key/, 'the second person of step 8'], [/mobile number/, 'the administrator\'s phone of step 4'],
    [/legal name/, 'the legal name of step 4'], [/grievance officer/i, 'the grievance contact of step 4'], [/Android 12/, 'the phone of step 10']]) assert.match(list, word, why);
  // The guide's own figures agree with the reference's host prerequisites.
  assert.match(guide, /Android 12 or newer, 4 GB of memory/);
  assert.match(list, /4 vCPU, 8 GiB of memory, an SSD and 60 GB/);
  assert.match(guide, /Under 4 vCPU, 8 GiB or 60 GB/);
  // The optional off-site copy mentioned under "After the install" is a feature that exists and is documented where the guide points.
  assert.ok(existsSync(join(repo, 'scripts/offsite.sh')));
  assert.ok(anchors('docs/OPERATOR_INSTALL.md').has('off-site-copy-optional'));
  assert.match(guide, /needs `rclone` installed/);
});

test('the lines the guide says "You should see" are lines the scripts print', () => {
  const sources = ['setup.sh', 'scripts/doctor.mjs', 'scripts/tunnel.sh', 'scripts/lan-common.mjs', 'scripts/watch-timer.sh'].map(read).join('\n');
  for (const line of ['Operator services are healthy on the local gateway.', 'Local operator services and gateway are healthy.', 'Local services and external HTTPS discovery are healthy.',
    'is running from', 'LAN address for the app', 'is installed for']) {
    assert.ok(guide.includes(line), `the guide no longer says "${line}"; update this test`);
    assert.ok(sources.includes(line), `no script prints "${line}", but the guide says it will`);
  }
});
