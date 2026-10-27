#!/usr/bin/env node
// The ordering rule of migrations/ (CONTRIBUTING.md, "Migrations"): the ledger of an installed facility records file names, and
// scripts/migration-plan.mjs applies the files it has not recorded in name order, so the directory may only grow at its end.
//   node scripts/check-migration-order.mjs [BASE_REF] [--root DIR]
// Compares migrations/ in the working tree of DIR (default: this checkout) with migrations/ at BASE_REF (default origin/main; in CI
// the merge base of the pull request) and fails when
//   - a file of the base is missing or was renamed (a facility that recorded the old name would be refused by the plan),
//   - a file of the base has other content (the ledger refuses a changed checksum), or
//   - a new file sorts before the last file of the base (it would run on a fresh install before files a facility has applied already,
//     and on an installed facility after them: two databases of the same release would differ).
// Exit 0: the rule holds. Exit 1: it is broken, each problem on its own line. Exit 2: the base could not be read.
import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

// base, current: Map of file name -> Buffer. Returns the problems, in a stable order.
export function migrationOrderProblems(base, current) {
  const problems = [];
  const names = map => [...map.keys()].sort();
  const added = names(current).filter(name => !base.has(name));
  const lastBase = names(base).at(-1);
  for (const name of names(base)) {
    if (!current.has(name)) {
      const same = added.find(other => current.get(other).equals(base.get(name)));
      problems.push(same === undefined
        ? `${name}: removed. A facility that recorded it would be refused by the migration plan; add a new migration instead.`
        : `${name}: renamed to ${same}. A facility that recorded the old name would be refused by the migration plan; keep the name.`);
    } else if (!current.get(name).equals(base.get(name))) {
      problems.push(`${name}: its content changed. The ledger of an installed facility holds its checksum and refuses a changed file; add a new migration instead.`);
    }
  }
  for (const name of added) {
    if (lastBase !== undefined && name < lastBase) {
      problems.push(`${name}: sorts before ${lastBase}, the last migration of the base. Number it after ${lastBase} (a new file always sorts last).`);
    }
  }
  return problems;
}

function baseFiles(root, ref) {
  const git = args => execFileSync('git', ['-C', root, ...args], { maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
  const listed = git(['ls-tree', '-r', '--name-only', ref, '--', 'migrations/']).toString('utf8').split('\n').filter(Boolean);
  return new Map(listed.filter(path => path.endsWith('.sql')).map(path => [path.slice('migrations/'.length), git(['show', `${ref}:${path}`])]));
}

function currentFiles(root) {
  const directory = resolve(root, 'migrations');
  return new Map(readdirSync(directory).filter(name => name.endsWith('.sql')).map(name => [name, readFileSync(resolve(directory, name))]));
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  let root = fileURLToPath(new URL('..', import.meta.url));
  let ref = 'origin/main';
  const rest = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--root' && args[i + 1]) { root = resolve(args[i + 1]); i += 1; } else rest.push(args[i]);
  }
  if (rest.length > 1 || rest[0]?.startsWith('-')) {
    process.stderr.write('Usage: check-migration-order.mjs [BASE_REF] [--root DIR]\n');
    process.exit(2);
  }
  if (rest.length) ref = rest[0];
  let base;
  try {
    base = baseFiles(root, ref);
  } catch (error) {
    process.stderr.write(`Could not read migrations/ at ${ref}: ${String(error.stderr || error.message).trim()}\nFetch the base first (git fetch origin).\n`);
    process.exit(2);
  }
  const current = currentFiles(root);
  const problems = migrationOrderProblems(base, current);
  if (problems.length) {
    process.stderr.write(`The migration ordering rule is broken (base ${ref}):\n${problems.map(line => `  ${line}`).join('\n')}\nRule: never remove, rename or edit a file in migrations/, and never add one that sorts before an existing one (CONTRIBUTING.md, "Migrations").\n`);
    process.exit(1);
  }
  process.stdout.write(`Migration order holds: ${base.size} files of ${ref} unchanged, ${current.size - base.size} new.\n`);
}
