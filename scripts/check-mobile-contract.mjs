#!/usr/bin/env node
// Static lower-bound inventory: names only; not a substitute for live API/role tests.
import { readdirSync, readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

function files(root, extension) {
  return readdirSync(root, { withFileTypes: true }).flatMap(entry => {
    const path = join(root, entry.name);
    if (entry.name === '__tests__' || /\.(test|spec)\./.test(entry.name)) return [];
    return entry.isDirectory() ? files(path, extension) : extension.test(entry.name) ? [path] : [];
  });
}
const mobile = process.argv[2];
if (!mobile) {
  console.error('Usage: node scripts/check-mobile-contract.mjs /path/to/rn-warehouse-template');
  process.exit(2);
}
const root = fileURLToPath(new URL('..', import.meta.url));
const sql = files(join(root, 'migrations'), /\.sql$/).map(path => readFileSync(path, 'utf8')).join('\n');
const ts = createRequire(resolve(mobile, 'package.json'))('typescript');
const calls = { rpc: new Set(), tables: new Set(), edge: new Set() };
for (const path of ['src', 'app'].flatMap(dir => files(resolve(mobile, dir), /\.tsx?$/))) {
  const tree = ts.createSourceFile(path, readFileSync(path, 'utf8'), ts.ScriptTarget.Latest, true);
  const visit = (node) => {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'executeRPC') {
      const arg = node.arguments[1];
      if (arg && ts.isStringLiteralLike(arg)) calls.rpc.add(arg.text);
    }
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
      const method = node.expression.name.text;
      const arg = node.arguments[0];
      if (arg && ts.isStringLiteralLike(arg)) {
        if (method === 'rpc') calls.rpc.add(arg.text);
        if (method === 'from' && !node.expression.expression.getText(tree).includes('.storage')) calls.tables.add(arg.text);
        if (method === 'invoke' && node.expression.expression.getText(tree).includes('.functions')) calls.edge.add(arg.text);
      }
    }
    if (ts.isStringLiteralLike(node) || ts.isTemplateExpression(node)) {
      const value = ts.isTemplateExpression(node) ? node.head.text + node.templateSpans.map(span => span.literal.text).join('') : node.text;
      for (const match of value.matchAll(/\/functions\/v1\/([a-z][a-z0-9-]*)/g)) calls.edge.add(match[1]);
    }
    ts.forEachChild(node, visit);
  };
  visit(tree);
}
const names = (text, pattern) => [...new Set([...text.matchAll(pattern)].map(match => match[1]))].sort();
const groups = {
  rpc: {
    called: [...calls.rpc].sort(),
    defined: names(sql, /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?([a-z][a-z0-9_]*)\s*\(/gi),
  },
  tables: {
    called: [...calls.tables].sort(),
    defined: names(sql, /CREATE\s+(?:TABLE|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?public\.([a-z][a-z0-9_]*)/gi),
  },
  edge: {
    called: [...calls.edge].sort(),
    defined: readdirSync(join(root, 'functions'), { withFileTypes: true }).filter(entry => entry.isDirectory() && !['main', '_shared'].includes(entry.name)).map(entry => entry.name).sort(),
  },
};
let missing = 0;
for (const group of Object.values(groups)) {
  group.missing = group.called.filter(name => !group.defined.includes(name));
  missing += group.missing.length;
}
console.log(JSON.stringify({ note: 'Static name coverage only. Dynamic calls, signatures, SQL validity, RLS, and storage bucket policies require separate tests.', ...groups }, null, 2));
process.exitCode = missing ? 1 : 0;
