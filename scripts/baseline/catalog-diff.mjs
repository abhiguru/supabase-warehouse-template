// Compares two databases (running containers) by catalog and by seed-row hashes, and checks every difference against
// an allow-list of expected differences.
//
//   node scripts/baseline/catalog-diff.mjs <containerA> <containerB> [--allow <file>] [--image supabase|pg17] [--unmasked] [--full] [--write <dir>]
//
// A is the chain-built database, B the baseline-built one. Each side is described by catalog-dump.sql and seed-dump.sql
// (one "kind|key|detail" line per fact). Output: every line that exists on one side only, sorted. Exit 0 when each such line
// is covered by an allow-list entry, 1 when something else differs or an entry that applies to this run matched nothing,
// 2 on a usage or database error.
// --image says which database image B runs on (supabase = the old Supabase image, pg17 = postgres:17 plus the bootstrap).
// --unmasked compares seed rows with nothing masked (both sides come from the same installation).
//
// Allow-list file (default scripts/baseline/allowed-differences.txt): lines starting with # are comments, blank lines are
// ignored; every other line is "<side>[@<image>] <regex>" where side is A (the line is only in A) or B (only in B), the
// optional image (supabase or pg17) limits the entry to runs on that image, and the regex is matched against the whole
// line (trailing spaces of a regex are lost: end it with a character class or $). An entry that applies to the run and
// matches nothing FAILS the run: a stale entry would otherwise hide a later, real difference.
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { isMain } from '../is-main.mjs';

const HERE = fileURLToPath(new URL('.', import.meta.url));
const DB_PASSWORD = 'disposable-test-database-only';

// Splits psql output into the non-empty fact lines (returns a sorted array; duplicates are kept so counts matter).
export function parseLines(text) {
  return text.split('\n').map(l => l.replace(/\r$/, '')).filter(l => l !== '').sort();
}

// The old image owns auth.email(), auth.role() and auth.uid() by supabase_auth_admin; the baseline gives them to supabase_admin
// (a removed role). Instead of allowing every line of these functions, side A is rewritten so that ONLY the owner change is
// absorbed: a changed body, a lost SET search_path or a lost EXECUTE grant still differs (review H1).
export function normaliseOwnerFacts(lines) {
  const key = /^(function|acl\|function)\|auth\.(email|role|uid)\(\)\|/;
  return lines.map(l => {
    if (!key.test(l)) return l;
    if (l.startsWith('function|')) return l.replace(' owner supabase_auth_admin ', ' owner supabase_admin ');
    return l.replace(/^(acl\|function\|[^|]+\|)supabase_auth_admin -> supabase_auth_admin /, '$1supabase_admin -> supabase_admin ')
      .replace(/^(acl\|function\|[^|]+\|)supabase_auth_admin -> /, '$1supabase_admin -> ');
  }).sort();
}

// Multiset difference of two sorted line arrays: { onlyA, onlyB }.
export function diffLines(a, b) {
  const count = new Map();
  for (const l of b) count.set(l, (count.get(l) ?? 0) + 1);
  const onlyA = [];
  for (const l of a) {
    const n = count.get(l) ?? 0;
    if (n > 0) count.set(l, n - 1); else onlyA.push(l);
  }
  const onlyB = [];
  for (const [l, n] of count) for (let i = 0; i < n; i++) onlyB.push(l);
  return { onlyA, onlyB: onlyB.sort() };
}

// Allow-list text -> [{ side, pattern, regex, line }]. Throws on a malformed line or regex.
export function parseAllowList(text) {
  const entries = [];
  text.split('\n').forEach((raw, i) => {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) return;
    const m = line.match(/^([AB])(?:@(supabase|pg17))?\s+(\S.*)$/);
    if (!m) throw new Error(`allow-list line ${i + 1}: expected "A <regex>" or "B <regex>" (optionally A@supabase, B@pg17), got: ${raw}`);
    let regex;
    try { regex = new RegExp(m[3]); } catch (e) { throw new Error(`allow-list line ${i + 1}: bad regex (${e.message})`); }
    entries.push({ side: m[1], image: m[2] ?? '', pattern: m[3], regex, line: i + 1, used: 0 });
  });
  return entries;
}

// Splits the differences into allowed (with the entry that covers each) and unexpected. Counts uses per entry.
// `image` limits the entries to those without an image tag or with this tag; without it every entry applies.
export function applyAllowList(diff, entries, { image = '' } = {}) {
  entries = entries.filter(e => !image || !e.image || e.image === image);
  for (const e of entries) e.used = 0;
  const unexpected = [];
  let allowed = 0;
  for (const [side, lines] of [['A', diff.onlyA], ['B', diff.onlyB]]) {
    for (const line of lines) {
      const hit = entries.find(e => e.side === side && e.regex.test(line));
      if (hit) { hit.used++; allowed++; } else unexpected.push({ side, line });
    }
  }
  return { unexpected, allowed, unused: entries.filter(e => e.used === 0) };
}

export function formatReport(result, { full = false } = {}) {
  const cut = s => (full || s.length <= 300 ? s : `${s.slice(0, 300)}... [${s.length} chars]`);
  const out = [];
  for (const { side, line } of result.unexpected) out.push(`${side === 'A' ? 'only in A (chain)   ' : 'only in B (baseline)'} ${cut(line)}`);
  return out.join('\n');
}

function psqlRun(container, sql, { unmasked = false } = {}) {
  const r = spawnSync('docker', ['exec', '-i', '-e', `PGPASSWORD=${DB_PASSWORD}`, ...(unmasked ? ['-e', 'PGOPTIONS=-c baseline.unmasked=on'] : []), container, 'psql', '-q', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
    { input: sql, encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`psql in ${container} failed: ${r.stderr || r.error}`);
  return r.stdout;
}

export function dumpFacts(container, { unmasked = false } = {}) {
  const catalog = psqlRun(container, readFileSync(resolve(HERE, 'catalog-dump.sql'), 'utf8'));
  const seed = psqlRun(container, readFileSync(resolve(HERE, 'seed-dump.sql'), 'utf8'), { unmasked });
  return parseLines(`${catalog}\n${seed}`);
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  const positional = [];
  let allowFile = resolve(HERE, 'allowed-differences.txt'), full = false, writeDir = null, image = '', unmasked = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--allow') allowFile = args[++i];
    else if (args[i] === '--full') full = true;
    else if (args[i] === '--image') image = args[++i];
    else if (args[i] === '--unmasked') unmasked = true;
    else if (args[i] === '--write') writeDir = args[++i];
    else positional.push(args[i]);
  }
  if (positional.length !== 2) { console.error('usage: catalog-diff.mjs <containerA> <containerB> [--allow file] [--image supabase|pg17] [--unmasked] [--full] [--write dir]'); process.exit(2); }
  try {
    const entries = parseAllowList(readFileSync(allowFile, 'utf8'));
    if (image && !['supabase', 'pg17'].includes(image)) throw new Error('--image must be supabase or pg17');
    const a = normaliseOwnerFacts(dumpFacts(positional[0], { unmasked })), b = dumpFacts(positional[1], { unmasked });
    if (writeDir) { mkdirSync(writeDir, { recursive: true }); writeFileSync(resolve(writeDir, 'A.txt'), a.join('\n') + '\n'); writeFileSync(resolve(writeDir, 'B.txt'), b.join('\n') + '\n'); }
    const kinds = new Set(a.map(l => l.split('|')[0]));
    const result = applyAllowList(diffLines(a, b), entries, { image });
    const active = entries.filter(e => !image || !e.image || e.image === image);
    console.log(`Compared ${a.length} facts of A with ${b.length} facts of B (${kinds.size} kinds).`);
    console.log(`Allowed differences: ${result.allowed}; unexpected: ${result.unexpected.length}.`);
    for (const e of active) console.log(`  allow ${e.side} ${e.used}x  ${e.pattern}`);
    for (const e of result.unused) console.log(`  UNUSED allow-list entry (line ${e.line}): ${e.side}${e.image ? '@' + e.image : ''} ${e.pattern}`);
    if (result.unexpected.length || result.unused.length) { if (result.unexpected.length) { console.log('\nUnexpected differences:'); console.log(formatReport(result, { full })); }
      if (result.unused.length) console.log('\nAn allow-list entry that matched nothing is stale: remove it (or fix the baseline that no longer needs it).');
      process.exit(1); }
    console.log('No unexpected differences.');
  } catch (e) { console.error(e.message); process.exit(2); }
}
