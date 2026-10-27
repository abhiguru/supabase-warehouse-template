// The names the migrations leave defined, for scripts/check-mobile-contract.mjs: the files are read in the order they are applied
// and a DROP removes what an earlier statement defined, so a function or table the app calls that a migration dropped is reported
// missing. A function is kept per name and argument count (an overload is dropped by its own signature; migration 124 drops the
// 17-argument save_grn and the 18-argument one stays; OUT parameters are not counted). A function a migration builds from
// pg_get_functiondef text cannot be seen as a CREATE; the ALTER, GRANT and COMMENT statements that follow it name it, and name only a
// function that exists, so they count (an ALTER ... RENAME TO or SET SCHEMA is the exception: the old name is gone).

const CREATE_FUNCTION = String.raw`CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?([a-z][a-z0-9_]*)\s*\(`;
const NAMED_FUNCTION = String.raw`(?:\bALTER\s+FUNCTION|\bON\s+FUNCTION)\s+(?:public\.)?([a-z][a-z0-9_]*)\s*\(`;
const CREATE_RELATION = String.raw`CREATE\s+(?:TABLE|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?public\.([a-z][a-z0-9_]*)`;
const DROP_FUNCTION = String.raw`DROP\s+(?:FUNCTION|ROUTINE)\s+(?:IF\s+EXISTS\s+)?`;
const DROP_RELATION = String.raw`DROP\s+(?:TABLE|VIEW)\s+(?:IF\s+EXISTS\s+)?([^;]*);`;

function stripComments(sql) {
  return sql.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/--[^\n]*/g, ' ');
}

// The text between the parenthesis that opens at `open` and its partner, and where the partner is (-1: unbalanced).
function balanced(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '(') depth++;
    else if (text[i] === ')' && --depth === 0) return { inner: text.slice(open + 1, i), end: i };
  }
  return { inner: '', end: -1 };
}
// The number of arguments a signature gives: the top-level commas of the list, not those inside parentheses, brackets (ARRAY[120, 240])
// or quoted text (a default such as '{a,b}'), and without the OUT parameters, which the function's identity (DROP, ALTER) does not list.
function arity(inner) {
  const parts = [''];
  let depth = 0, quote = null;
  for (const character of inner) {
    if (quote) { if (character === quote) quote = null; }
    else if (character === "'" || character === '"') quote = character;
    else if (character === '(' || character === '[') depth++;
    else if (character === ')' || character === ']') depth--;
    else if (character === ',' && depth === 0) { parts.push(''); continue; }
    parts[parts.length - 1] += character;
  }
  return parts.filter(part => part.trim() && !/^\s*OUT\s/i.test(part)).length;
}

/** `texts`: the contents of the migration files, in the order they are applied. Returns { functions, relations } as sorted name arrays. */
export function definedNames(texts) {
  const functions = new Map();
  const relations = new Set();
  const define = (name, count) => { name = name.toLowerCase(); (functions.get(name) ?? functions.set(name, new Set()).get(name)).add(count); };
  const drop = (name, count) => {
    name = name.toLowerCase();
    if (count === null) { functions.delete(name); return; }
    functions.get(name)?.delete(count);
    if (functions.get(name)?.size === 0) functions.delete(name);
  };
  const statement = new RegExp(`${CREATE_FUNCTION}|${NAMED_FUNCTION}|${CREATE_RELATION}|${DROP_FUNCTION}|${DROP_RELATION}`, 'gi');
  for (const raw of texts) {
    const text = stripComments(raw);
    for (const match of text.matchAll(statement)) {
      const name = match[1] ?? match[2];
      if (name !== undefined) {
        const group = balanced(text, match.index + match[0].length - 1);
        const count = arity(group.inner);
        // ALTER FUNCTION f(..) RENAME TO g / SET SCHEMA x: the old name is gone (and the new one exists); any other ALTER, GRANT or COMMENT is evidence.
        const change = /^ALTER/i.test(match[0]) && group.end >= 0 ? /^\s*(?:RENAME\s+TO\s+"?([a-z_][a-z0-9_]*)|SET\s+SCHEMA\s)/i.exec(text.slice(group.end + 1)) : null;
        if (change) {
          drop(name, count);
          if (change[1]) define(change[1], count);
        } else {
          define(name, count);
        }
      } else if (match[3] !== undefined) {
        relations.add(match[3].toLowerCase());
      } else if (match[4] !== undefined) {
        for (const item of match[4].replace(/\s+(?:CASCADE|RESTRICT)\s*$/i, '').split(',')) {
          const relation = item.trim().match(/^(?:"?([a-z_][a-z0-9_]*)"?\.)?"?([a-z_][a-z0-9_]*)"?$/i);
          if (relation && (!relation[1] || relation[1].toLowerCase() === 'public')) relations.delete(relation[2].toLowerCase());
        }
      } else {
        // DROP FUNCTION [IF EXISTS] sig [, sig ...] [CASCADE]: read the signatures one after another from the end of the match.
        let position = match.index + match[0].length;
        for (;;) {
          const item = /^\s*(?:"?([a-z_][a-z0-9_]*)"?\.)?"?([a-z_][a-z0-9_]*)"?\s*/i.exec(text.slice(position));
          if (!item) break;
          position += item[0].length;
          let count = null;
          if (text[position] === '(') {
            const group = balanced(text, position);
            if (group.end < 0) break;
            count = arity(group.inner);
            position = group.end + 1;
          }
          if (!item[1] || item[1].toLowerCase() === 'public') drop(item[2], count);
          const comma = /^\s*,/.exec(text.slice(position));
          if (!comma) break;
          position += comma[0].length;
        }
      }
    }
  }
  return { functions: [...functions.keys()].sort(), relations: [...relations].sort() };
}
