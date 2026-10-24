// The optional letterhead image of the GRN, dispatch, invoice and customer stock PDFs (setup.sh --letterhead-file):
// setup (scripts/configure.mjs), the document HTML, the router's reader, the worker lists, doctor and watch.
// The backup, verify-restore and restore-host cases are in backup-operator.test.mjs and restore-host.test.mjs.
import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { configure, parseConfigureArgs } from '../scripts/configure.mjs';
import { readEnv, letterheadFault } from '../scripts/doctor-common.mjs';
import { checkLetterhead } from '../scripts/doctor.mjs';
import { checkLetterhead as watchLetterhead, CHECKS } from '../scripts/watch.mjs';
import { documentHtml } from '../functions/_shared/document-html.ts';
import { isLetterheadUri, letterheadDataUri } from '../functions/_shared/letterhead.ts';
import { letterheadReader } from '../functions/main/letterhead-reader.ts';
import { workerEnv, workerEnvNames } from '../functions/main/worker-env.ts';
import { jpegLetterhead, pngLetterhead } from './backup-test-helpers.mjs';

const PLAIN_HTML_CSP = `content="default-src 'none'; style-src 'unsafe-inline'"`;

function scratchSetup() {
  const scratch = mkdtempSync(join(tmpdir(), 'warehouse-letterhead-'));
  const root = join(scratch, 'checkout');
  const providerEnv = join(scratch, 'provider.env');
  mkdirSync(root);
  copyFileSync(new URL('../.env.example', import.meta.url), join(root, '.env.example'));
  writeFileSync(providerEnv, 'SMS_PROVIDER=msg91\nMSG91_AUTH_KEY=provider-key\nMSG91_TEMPLATE_ID=flow-id\nMSG91_PE_ID=pe-id\nMSG91_SENDER_ID=WHOUSE\n', { mode: 0o600 });
  const png = join(scratch, 'banner.png'); writeFileSync(png, pngLetterhead);
  const jpg = join(scratch, 'banner.jpg'); writeFileSync(jpg, jpegLetterhead);
  const base = { apiUrl: 'https://api.example.com', company: 'Acme Stores', providerEnv };
  return { scratch, root, base, png, jpg, state: join(scratch, 'state') };
}

test('setup --letterhead-file: PNG and JPEG are copied (mode 0644) and recorded; a rerun without the flag keeps them; png to jpg removes the old file; off removes it', () => {
  const { scratch, root, base, png, jpg, state } = scratchSetup();
  try {
    const envPath = join(state, 'config/compose.env');
    const publicDir = join(state, 'public');
    // First install with a PNG. The copy has a different name from the source: the kind comes from the bytes.
    const odd = join(scratch, 'logo.dat'); writeFileSync(odd, pngLetterhead);
    const created = configure(root, { ...base, stateDir: state, letterheadFile: odd });
    assert.equal(created.created, true); assert.equal(created.letterhead, 'letterhead.png');
    assert.deepEqual(readFileSync(join(publicDir, 'letterhead.png')), pngLetterhead);
    assert.equal(statSync(join(publicDir, 'letterhead.png')).mode & 0o777, 0o644);
    assert.equal(readEnv(envPath).LETTERHEAD_FILE, 'letterhead.png');
    assert.deepEqual(readdirSync(publicDir).sort(), ['instance.json', 'letterhead.png'], 'no temporary file is left');

    // A rerun without the flag keeps it; the same flag again changes nothing.
    const kept = readFileSync(envPath);
    assert.equal(configure(root, { stateDir: state }).letterheadUpdated, false);
    assert.deepEqual(readFileSync(envPath), kept);
    assert.equal(existsSync(join(publicDir, 'letterhead.png')), true);
    assert.equal(configure(root, { stateDir: state, letterheadFile: png }).letterheadUpdated, false);

    // Switching to a JPEG removes the PNG and renames the setting.
    const switched = configure(root, { stateDir: state, letterheadFile: jpg });
    assert.equal(switched.letterheadUpdated, true); assert.equal(switched.letterhead, 'letterhead.jpg');
    assert.deepEqual(readdirSync(publicDir).sort(), ['instance.json', 'letterhead.jpg']);
    assert.deepEqual(readFileSync(join(publicDir, 'letterhead.jpg')), jpegLetterhead);
    assert.equal(readEnv(envPath).LETTERHEAD_FILE, 'letterhead.jpg');
    // ... and back.
    configure(root, { stateDir: state, letterheadFile: png });
    assert.deepEqual(readdirSync(publicDir).sort(), ['instance.json', 'letterhead.png']);

    // off removes the file and empties the setting; off again changes nothing.
    const off = configure(root, { stateDir: state, letterheadFile: 'off' });
    assert.equal(off.letterheadUpdated, true); assert.equal(off.letterhead, null);
    assert.deepEqual(readdirSync(publicDir).sort(), ['instance.json']);
    assert.equal(readEnv(envPath).LETTERHEAD_FILE, '');
    const after = readFileSync(envPath);
    const again = configure(root, { stateDir: state, letterheadFile: 'off' });
    assert.equal(again.letterheadUpdated, false); assert.equal(again.letterhead, undefined);
    assert.deepEqual(readFileSync(envPath), after);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('setup --letterhead-file refuses a relative path, a missing file, a wrong signature and a file over 2 MiB, and copies nothing', () => {
  const { scratch, root, base, png, state } = scratchSetup();
  try {
    configure(root, { ...base, stateDir: state });
    const envPath = join(state, 'config/compose.env');
    const before = readFileSync(envPath);
    const text = join(scratch, 'banner.txt'); writeFileSync(text, 'not an image');
    const gif = join(scratch, 'banner.gif'); writeFileSync(gif, Buffer.from('GIF89a......'));
    const webp = join(scratch, 'banner.webp'); writeFileSync(webp, Buffer.from('RIFF....WEBPVP8 '));
    const truncatedPng = join(scratch, 'short.png'); writeFileSync(truncatedPng, pngLetterhead.subarray(0, 5));
    const empty = join(scratch, 'empty'); writeFileSync(empty, '');
    const big = join(scratch, 'big.png'); writeFileSync(big, Buffer.concat([pngLetterhead, Buffer.alloc(2 * 1024 * 1024)]));
    const exact = join(scratch, 'exact.png'); writeFileSync(exact, Buffer.concat([pngLetterhead, Buffer.alloc(2 * 1024 * 1024 - pngLetterhead.length)]));
    for (const [file, message] of [['banner.png', /absolute path/], [join(scratch, 'missing.png'), /readable regular file/], [scratch, /readable regular file/],
      [text, /not a JPEG or PNG/], [gif, /not a JPEG or PNG/], [webp, /not a JPEG or PNG/], [truncatedPng, /not a JPEG or PNG/], [empty, /not a JPEG or PNG/], [big, /larger than 2 MiB/]]) {
      assert.throws(() => configure(root, { stateDir: state, letterheadFile: file }), message, file);
      assert.deepEqual(readdirSync(join(state, 'public')), ['instance.json'], `${file}: nothing was copied`);
      assert.deepEqual(readFileSync(envPath), before, `${file}: compose.env is unchanged`);
    }
    // Exactly 2 MiB is allowed. A fresh install with a refused file creates no state.
    assert.equal(configure(root, { stateDir: state, letterheadFile: exact }).letterheadUpdated, true);
    const fresh = join(scratch, 'fresh');
    assert.throws(() => configure(root, { ...base, stateDir: fresh, letterheadFile: text }), /not a JPEG or PNG/);
    assert.equal(existsSync(fresh), false);
    // A symlink to a PNG is followed (as --central-jwks-file does) and the copy is a plain file.
    const link = join(scratch, 'link.png'); symlinkSync(png, link);
    configure(root, { stateDir: state, letterheadFile: link });
    assert.equal(statSync(join(state, 'public/letterhead.png')).isFile(), true);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('setup appends the LETTERHEAD_FILE line to the compose.env of an older state, and a state without it can turn it off', () => {
  const { scratch, root, base, png, state } = scratchSetup();
  try {
    configure(root, { ...base, stateDir: state });
    const envPath = join(state, 'config/compose.env');
    const withLine = readFileSync(envPath, 'utf8');
    const older = withLine.replace(/^# Optional letterhead[^]*?LETTERHEAD_FILE=\n/m, '').replace(/^LETTERHEAD_FILE=.*\n/m, '');
    assert.ok(!older.includes('LETTERHEAD_FILE'), 'the fixture lacks the line');
    writeFileSync(envPath, older, { mode: 0o600 });
    // off on a state without the line changes nothing, not even by appending an empty line.
    assert.equal(configure(root, { stateDir: state, letterheadFile: 'off' }).letterheadUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), older);
    assert.equal(configure(root, { stateDir: state }).letterheadUpdated, false);
    assert.equal(readFileSync(envPath, 'utf8'), older);
    configure(root, { stateDir: state, letterheadFile: png });
    assert.equal(readFileSync(envPath, 'utf8'), `${older}LETTERHEAD_FILE=letterhead.png\n`);
    assert.equal(statSync(envPath).mode & 0o777, 0o600);
    // A new state carries the empty line from .env.example.
    assert.match(withLine, /^LETTERHEAD_FILE=$/m);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('the command line takes --letterhead-file, prints one confirmation, and the usage message lists it', () => {
  const { scratch, root, base, png, state } = scratchSetup();
  try {
    configure(root, { ...base, stateDir: state });
    assert.deepEqual(parseConfigureArgs(['--state-dir', state, '--letterhead-file', png]), { stateDir: state, letterheadFile: png });
    assert.throws(() => parseConfigureArgs(['--bogus', 'x']), /\[--letterhead-file ABSOLUTE\|off\]/);
    const run = args => spawnSync(process.execPath, [new URL('../scripts/configure.mjs', import.meta.url).pathname, '--state-dir', state, ...args],
      { encoding: 'utf8', env: { ...process.env, NODE_TEST_CONTEXT: '' } });
    const stored = run(['--letterhead-file', png]);
    assert.equal(stored.status, 0, stored.stderr);
    assert.match(stored.stdout, /Stored the letterhead image public\/letterhead\.png: the GRN, dispatch, invoice and customer stock PDFs print it at the top\./);
    assert.doesNotMatch(stored.stdout, /Preserved existing operator state unchanged/);
    const removed = run(['--letterhead-file', 'off']);
    assert.match(removed.stdout, /Removed the letterhead image: the GRN, dispatch, invoice and customer stock PDFs are plain again\./);
    const refused = run(['--letterhead-file', join(scratch, 'nope')]);
    assert.equal(refused.status, 1); assert.match(refused.stderr, /Configure: --letterhead-file must be a readable regular file/);
    const setup = readFileSync(new URL('../setup.sh', import.meta.url), 'utf8');
    assert.match(setup, /--letterhead-file\|--gateway-port\)/);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
});

test('documentHtml without a letterhead is byte for byte the plain document; with one it adds the image and img-src data: only', () => {
  const plain = documentHtml('GRN', 'Co', { Number: 'G1' }, ['Item'], [['Cumin']]);
  assert.ok(plain.includes(PLAIN_HTML_CSP));
  assert.ok(!plain.includes('<img') && !plain.includes('img-src') && !plain.includes('letterhead'));
  for (const none of [undefined, '', null]) assert.equal(documentHtml('GRN', 'Co', { Number: 'G1' }, ['Item'], [['Cumin']], none), plain);
  // The exact plain document, as released before the letterhead existed.
  assert.equal(plain, `<!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
    <style>body{font:12px 'Liberation Sans','Noto Sans Gujarati',sans-serif;color:#18212f}h1{font-size:24px}h2{font-size:18px}table{border-collapse:collapse;width:100%;margin-top:24px}th,td{padding:8px;border-bottom:1px solid #ddd;text-align:left}th{background:#edf1f5}tr{break-inside:avoid}small{color:#555}</style>
    </head><body><h1>Co</h1><h2>GRN</h2>
    <p><strong>Number:</strong> G1</p>
    <table><thead><tr><th>Item</th></tr></thead>
    <tbody><tr><td>Cumin</td></tr></tbody></table>
    <p><small>Open-source starter layout. Configure your business details and document terms before operational use.</small></p></body></html>`);

  const uri = letterheadDataUri(pngLetterhead);
  assert.match(uri, /^data:image\/png;base64,[A-Za-z0-9+/]+=*$/);
  const withImage = documentHtml('GRN', 'Co', { Number: 'G1' }, ['Item'], [['Cumin']], uri);
  assert.ok(withImage.includes(`content="default-src 'none'; img-src data:; style-src 'unsafe-inline'"`));
  assert.ok(withImage.includes(`<body><img class="letterhead" src="${uri}" alt=""><h1>Co</h1>`), 'the image is the first thing on the page');
  assert.ok(withImage.includes('.letterhead{width:100%;height:auto;display:block;margin-bottom:16px}'));
  assert.equal(withImage.match(/<img /g).length, 1);
  assert.equal(withImage.replace(`<img class="letterhead" src="${uri}" alt="">`, '').replace(' img-src data:;', '').replace('.letterhead{width:100%;height:auto;display:block;margin-bottom:16px}', ''), plain, 'nothing else changed');
  // A JPEG too.
  assert.match(documentHtml('GRN', 'Co', {}, [], [], letterheadDataUri(jpegLetterhead)), /<img class="letterhead" src="data:image\/jpeg;base64,/);
});

test('documentHtml ignores a letterhead value that is not exactly a JPEG or PNG data URI', () => {
  const good = letterheadDataUri(pngLetterhead);
  const plain = documentHtml('GRN', 'Co', {}, [], []);
  const hostile = [
    'data:image/png;base64,x" onerror="alert(1)', `${good}" onerror="alert(1)`, `${good}\n`, ` ${good}`, `${good}<script>`,
    'javascript:alert(1)', 'https://attacker.example.test/pixel.png', 'http://private.internal/a.png', '//attacker.example.test/a.png',
    'data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=', 'data:text/html;base64,PGgxPmhpPC9oMT4=', 'data:image/gif;base64,R0lGODlh', 'data:image/png;base64,', 'data:image/png,abc',
    'data:image/png;base64,AAA=A', 'data:image/png;base64,AA A', 'data:image/png;charset=utf-8;base64,AAAA', 'DATA:image/png;base64,AAAA', 'data:image/png;base64,AAAA"><script>x</script>',
    "data:image/png;base64,AAAA' onload='x", 'data:image/jpeg;base64,AA AA', 42, {}, [good],
  ];
  for (const value of hostile) assert.equal(documentHtml('GRN', 'Co', {}, [], [], value), plain, String(value));
  assert.equal(isLetterheadUri(good), true);
  for (const value of hostile) assert.equal(isLetterheadUri(value), false, String(value));
});

test('letterheadDataUri takes only a JPEG or PNG of at most 2 MiB', () => {
  assert.match(letterheadDataUri(pngLetterhead), /^data:image\/png;base64,/);
  assert.match(letterheadDataUri(jpegLetterhead), /^data:image\/jpeg;base64,/);
  assert.equal(Buffer.from(letterheadDataUri(pngLetterhead).split(',')[1], 'base64').equals(pngLetterhead), true);
  const large = Buffer.concat([pngLetterhead, Buffer.alloc(2 * 1024 * 1024 - pngLetterhead.length)]);
  assert.match(letterheadDataUri(large), /^data:image\/png;base64,/, 'exactly 2 MiB, past the 32 KiB chunk size too');
  assert.equal(Buffer.from(letterheadDataUri(large).split(',')[1], 'base64').equals(large), true);
  assert.equal(letterheadDataUri(Buffer.concat([large, Buffer.from([0])])), null);
  for (const bytes of [Buffer.alloc(0), Buffer.from('GIF89a'), Buffer.from('<svg/>'), pngLetterhead.subarray(0, 7), Buffer.from([0xff, 0xd8])]) assert.equal(letterheadDataUri(bytes), null);
});

// The router's reader: a PDF must never fail because of the letterhead.
function reader(files, env = { LETTERHEAD_FILE: 'letterhead.png', LETTERHEAD_DIR: '/etc/warehouse/public' }) {
  const logs = [];
  const reads = [];
  const read = letterheadReader({
    env: name => env[name],
    stat: async path => { const f = files[path]; if (!f) throw new Error('ENOENT'); return { isFile: f.isFile ?? true, size: f.bytes.length, mtimeMs: f.mtimeMs ?? 1 }; },
    readFile: async path => { reads.push(path); const f = files[path]; if (!f || f.unreadable) throw new Error('EACCES'); return f.bytes; },
    log: line => logs.push(line),
  });
  return { read, logs, reads, env, files };
}

test('the letterhead reader returns the data URI, caches it, notices a replaced file, and falls back to no image with one log line', async () => {
  const path = '/etc/warehouse/public/letterhead.png';
  const r = reader({ [path]: { bytes: pngLetterhead } });
  const first = await r.read();
  assert.equal(first, letterheadDataUri(pngLetterhead));
  assert.equal(await r.read(), first);
  assert.deepEqual(r.reads, [path], 'read once, then from the cache');
  r.files[path] = { bytes: Buffer.concat([pngLetterhead, Buffer.from('more')]), mtimeMs: 2 };
  assert.equal(await r.read(), letterheadDataUri(r.files[path].bytes), 'a replaced file is read again');
  assert.deepEqual(r.logs, []);

  // The file disappears: no image, one line, however many PDFs follow; it comes back when the file does.
  delete r.files[path];
  for (let i = 0; i < 3; i += 1) assert.equal(await r.read(), '');
  assert.equal(r.logs.length, 1); assert.match(r.logs[0], /letterhead: letterhead\.png could not be read; PDFs are made without it/);
  r.files[path] = { bytes: pngLetterhead, mtimeMs: 3 };
  assert.equal(await r.read(), letterheadDataUri(pngLetterhead));
  assert.equal(r.logs.length, 1);
});

test('the letterhead reader leaves the image out for an empty setting, a bad name, a missing directory, unreadable, oversized, non-image and non-regular files', async () => {
  const dir = '/etc/warehouse/public';
  const quiet = reader({}, {});
  assert.equal(await quiet.read(), ''); assert.deepEqual(quiet.logs, [], 'an empty setting is not a fault');
  for (const [label, env, files, message] of [
    ['bad name', { LETTERHEAD_FILE: '../config/compose.env', LETTERHEAD_DIR: dir }, {}, /must be letterhead\.jpg or letterhead\.png/],
    ['another name', { LETTERHEAD_FILE: 'central-jwks.json', LETTERHEAD_DIR: dir }, {}, /must be letterhead\.jpg or letterhead\.png/],
    ['no directory', { LETTERHEAD_FILE: 'letterhead.png' }, {}, /must be letterhead/],
    ['missing', { LETTERHEAD_FILE: 'letterhead.png', LETTERHEAD_DIR: dir }, {}, /could not be read/],
    ['unreadable', { LETTERHEAD_FILE: 'letterhead.png', LETTERHEAD_DIR: dir }, { [`${dir}/letterhead.png`]: { bytes: pngLetterhead, unreadable: true } }, /could not be read/],
    ['too large', { LETTERHEAD_FILE: 'letterhead.png', LETTERHEAD_DIR: dir }, { [`${dir}/letterhead.png`]: { bytes: Buffer.concat([pngLetterhead, Buffer.alloc(2 * 1024 * 1024)]) } }, /larger than 2 MiB/],
    ['not an image', { LETTERHEAD_FILE: 'letterhead.png', LETTERHEAD_DIR: dir }, { [`${dir}/letterhead.png`]: { bytes: Buffer.from('<svg/>') } }, /not a JPEG or PNG/],
    ['not a file', { LETTERHEAD_FILE: 'letterhead.jpg', LETTERHEAD_DIR: dir }, { [`${dir}/letterhead.jpg`]: { bytes: jpegLetterhead, isFile: false } }, /not a regular file/],
  ]) {
    const r = reader(files, env);
    assert.equal(await r.read(), '', label);
    assert.equal(await r.read(), '', label);
    assert.equal(r.logs.length, 1, `${label}: one log line`);
    assert.match(r.logs[0], message, label);
  }
});

test('only the four document PDF workers receive the letterhead, and the router and compose pass it the way they pass the central key file', () => {
  const container = { JWT_SECRET: 'x', SUPABASE_URL: 'u', SUPABASE_ANON_KEY: 'a', SUPABASE_PUBLIC_URL: 'p', PDF_RENDERER_URL: 'r', LETTERHEAD_FILE: 'letterhead.png', LETTERHEAD_DIR: '/etc/warehouse/public' };
  const uri = letterheadDataUri(pngLetterhead);
  for (const name of Object.keys(workerEnvNames)) {
    const got = Object.fromEntries(workerEnv(name, container, { LETTERHEAD_DATA_URI: uri }));
    const four = ['generate-grn-pdf', 'generate-dispatch-pdf', 'generate-invoice-pdf', 'generate-customer-stock-pdf'].includes(name);
    assert.equal(got.LETTERHEAD_DATA_URI, four ? uri : undefined, name);
    assert.ok(!('LETTERHEAD_FILE' in got) && !('LETTERHEAD_DIR' in got), `${name} received the file setting`);
  }
  const router = readFileSync(new URL('../functions/main/index.ts', import.meta.url), 'utf8');
  assert.match(router, /const letterheadFunctions = new Set\(\['generate-grn-pdf', 'generate-dispatch-pdf', 'generate-invoice-pdf', 'generate-customer-stock-pdf'\]\);/);
  assert.match(router, /if \(letterheadFunctions\.has\(name\)\) \{\n      const uri = await readLetterhead\(\);\n      if \(uri\) extra\.LETTERHEAD_DATA_URI = uri;/);
  assert.doesNotMatch(router, /generate-report-pdf'\]\);\nconst readLetterhead/);
  const compose = readFileSync(new URL('../docker/docker-compose.yml', import.meta.url), 'utf8');
  const block = compose.slice(compose.indexOf('\n  functions:\n'), compose.indexOf('\n  db:\n'));
  assert.ok(block.includes('LETTERHEAD_FILE: ${LETTERHEAD_FILE:-}') && block.includes('LETTERHEAD_DIR: /etc/warehouse/public'));
  assert.doesNotMatch(compose.slice(compose.indexOf('\n  db:\n')), /LETTERHEAD/, 'the database container has no letterhead setting');
  // document-pdf passes what the router gave it; the report PDF does not know of it.
  assert.match(readFileSync(new URL('../functions/_shared/document-pdf.ts', import.meta.url), 'utf8'), /documentHtml\(kind\.toUpperCase\(\),company\.data\.value,metadata,columns,rows,Deno\.env\.get\('LETTERHEAD_DATA_URI'\) \|\| undefined\)/);
  assert.doesNotMatch(readFileSync(new URL('../functions/_shared/report-pdf.ts', import.meta.url), 'utf8'), /LETTERHEAD|letterhead/);
});

test('doctor and watch warn when LETTERHEAD_FILE is set but the file is missing or unusable, with the rerun command, and are silent otherwise', () => {
  const state = mkdtempSync(join(tmpdir(), 'warehouse-letterhead-doctor-'));
  mkdirSync(join(state, 'public')); mkdirSync(join(state, 'config'));
  const ctx = env => ({ state, env_: () => env });
  try {
    for (const env of [{}, { LETTERHEAD_FILE: '' }]) {
      assert.equal(checkLetterhead(env, state), '');
      assert.equal(watchLetterhead(ctx(env))[0].ok, true);
    }
    const env = { LETTERHEAD_FILE: 'letterhead.png' };
    const missing = checkLetterhead(env, state);
    assert.match(missing, new RegExp(`${state}/public/letterhead\\.png is missing`));
    assert.match(missing, /setup\.sh --operator[^]*--letterhead-file <the image>[^]*--letterhead-file off/);
    const watched = watchLetterhead(ctx(env))[0];
    assert.equal(watched.ok, false); assert.match(watched.detail, /letterhead\.png is missing/);

    writeFileSync(join(state, 'public/letterhead.png'), pngLetterhead);
    assert.equal(checkLetterhead(env, state), ''); assert.equal(watchLetterhead(ctx(env))[0].ok, true);
    writeFileSync(join(state, 'public/letterhead.png'), '<html>moved</html>');
    assert.match(checkLetterhead(env, state), /is not a JPEG or PNG image/);
    writeFileSync(join(state, 'public/letterhead.png'), jpegLetterhead);
    assert.match(checkLetterhead(env, state), /is not a JPEG or PNG image/, 'a JPEG under the PNG name is not what the setting says');
    writeFileSync(join(state, 'public/letterhead.png'), Buffer.concat([pngLetterhead, Buffer.alloc(2 * 1024 * 1024)]));
    assert.match(checkLetterhead(env, state), /larger than 2 MiB/);
    rmSync(join(state, 'public/letterhead.png'));
    symlinkSync(join(state, 'public'), join(state, 'public/letterhead.png'));
    assert.match(checkLetterhead(env, state), /must be a regular file/);
    for (const name of ['../config/compose.env', '/etc/passwd', 'letterhead.gif', 'central-jwks.json']) assert.match(checkLetterhead({ LETTERHEAD_FILE: name }, state), /must be letterhead\.jpg or letterhead\.png/, name);
    assert.equal(letterheadFault('letterhead.jpg', state)?.code, 'missing');
    assert.ok(CHECKS.some(([name, fn]) => name === 'letterhead' && fn === watchLetterhead));
    // doctor reports it as a warning, never as a failure.
    const doctor = readFileSync(new URL('../scripts/doctor.mjs', import.meta.url), 'utf8');
    assert.match(doctor, /const letterheadWarning = checkLetterhead\(env, state\);\n  if \(letterheadWarning\) console\.error\(`Warning: \$\{letterheadWarning\}`\);/);
  } finally { rmSync(state, { recursive: true, force: true }); }
});
