// The numbering rule of GRN, dispatch and invoice numbers (docs/OPERATOR_INSTALL.md, "Document numbers").
//
//   node numbering.mjs rule TYPE SPEC
//       checks a rule written as setup.sh's --grn-numbering, --dispatch-numbering or --invoice-numbering takes it and prints
//       it as the JSON warehouse_security.apply_document_numbering stores (setup.sh runs this before it changes anything, so a
//       refusal changes nothing). Exit 1 with the reason on a refusal.
//
// SPEC, one rule, parts separated by commas, the scheme first:
//   letters[,first=A][,digits=4][,per-letter=1000][,check=on|off]   A0001 ... A1000, B0001 ... ; first=X is the series of FAS (X, Y, Z, A, B ...)
//   year[,prefix=GRN/][,digits=4][,start=1][,check=on|off]         GRN/26-27/0001, starting again on every 1 April (GRN and dispatch)
//   sequence[,prefix=I][,digits=4][,start=1][,check=on|off]        I0001, or 1001, 1002 ... with no prefix
//   free                                                           any text, typed by hand (GRN and dispatch)
//   check=on refuses a typed number outside the rule when the document is saved; check=off saves it (a taken number is still refused) and
//   the rule still suggests the next number. Left out, the check stays as it is stored: a facility whose numbers did not follow the rule
//   at the update starts with it off (doctor says so). Not for free or for invoices (an invoice number is always a whole number).
//   An invoice number is a whole number: year (starts again at 1 every financial year, as before) or sequence (keeps
//   counting across years), each with an optional start=N.
// The database checks the same rules again (migration 127); this file only refuses early, with the operator's words.
// It imports node: built-ins and local files only (upgrade-preflight.sh runs the scripts directory without node_modules).
import { isMain } from './is-main.mjs';

export const TYPES = ['grn', 'dispatch', 'invoice'];
const KEYS = {
  letters: { first: 'first_letter', digits: 'width', 'per-letter': 'per_letter', check: 'check' },
  year: { prefix: 'prefix', digits: 'width', start: 'start', check: 'check' },
  sequence: { prefix: 'prefix', digits: 'width', start: 'start', check: 'check' },
  free: {},
};
const INVOICE_KEYS = { start: 'start' };

// The rule object for a spec, or throws an Error whose message says what to change.
export function parseSpec(type, spec) {
  if (!TYPES.includes(type)) throw new Error(`Unknown document type ${type}. Use grn, dispatch or invoice.`);
  const parts = String(spec ?? '').trim().split(',').map(part => part.trim());
  const scheme = parts.shift();
  const invoice = type === 'invoice';
  if (invoice ? !['year', 'sequence'].includes(scheme) : !Object.hasOwn(KEYS, scheme)) {
    throw new Error(invoice
      ? `An invoice number is a whole number: use year (starts again at 1 every financial year) or sequence (keeps counting), not "${scheme}".`
      : `Unknown scheme "${scheme}". Use letters, year, sequence or free.`);
  }
  const allowed = invoice ? INVOICE_KEYS : KEYS[scheme];
  const rule = { scheme };
  for (const part of parts) {
    const match = /^([a-z-]+)=(.*)$/.exec(part);
    if (!match || !Object.hasOwn(allowed, match[1])) {
      throw new Error(`"${part}" does not belong to a ${scheme} rule${invoice ? ' for invoices' : ''}${Object.keys(allowed).length ? ` (it takes ${Object.keys(allowed).join(', ')})` : ''}.`);
    }
    const field = allowed[match[1]];
    if (Object.hasOwn(rule, field)) throw new Error(`${match[1]} is given twice.`);
    const value = match[2];
    if (field === 'prefix') {
      if (!/^[A-Z0-9/-]{0,10}$/.test(value)) throw new Error('The prefix can have up to 10 characters: capital letters, digits, / and -.');
      rule.prefix = value;
    } else if (field === 'check') {
      if (!['on', 'off'].includes(value)) throw new Error('The check must be on (a number outside the rule is refused) or off (it is saved).');
      rule.check = value === 'on';
    } else if (field === 'first_letter') {
      if (!/^[A-Z]$/.test(value)) throw new Error('The first letter must be one capital letter.');
      rule.first_letter = value;
    } else {
      const [low, high, what] = {
        width: [1, 7, 'The number of digits must be a whole number from 1 to 7.'],
        start: [1, 9999999, 'The first number must be a whole number from 1 to 9999999.'],
        per_letter: [1, 9999999, 'The numbers per letter must be a whole number from 1 to 9999999.'],
      }[field];
      if (!/^[0-9]{1,8}$/.test(value) || Number(value) < low || Number(value) > high) throw new Error(what);
      rule[field] = Number(value);
    }
  }
  if (scheme === 'year' && !invoice && (rule.prefix ?? '').length + 6 + (rule.width ?? 4) > 20) {
    throw new Error(`A number with this prefix, the year (26-27/) and ${rule.width ?? 4} digits is longer than 20 characters.`);
  }
  return rule;
}

// Reads the rules the database holds, for `node scripts/doctor.mjs`: a line such as
// "Document numbers: GRN A#### (letters), dispatch I#### (sequence), invoice # (year)". Never throws: it is information, and an
// unreadable answer gives ''. `run` is a function that takes the psql arguments and returns { ok, output } (doctor passes the db container).
export const NUMBERING_SQL = "SELECT document_type || '|' || scheme || '|' || COALESCE(warehouse_security.document_number_pattern(n, warehouse_security.business_date(now())), 'typed by hand') "
  + "FROM warehouse_security.document_numbering n ORDER BY CASE document_type WHEN 'grn' THEN 1 WHEN 'dispatch' THEN 2 ELSE 3 END";
export function numberingLine(run) {
  const answer = run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', NUMBERING_SQL]);
  if (!answer.ok) return '';
  const rows = answer.output.trim().split('\n').map(line => /^(grn|dispatch|invoice)\|([a-z]+)\|(.*)$/.exec(line));
  if (rows.length !== 3 || rows.some(row => !row)) return '';
  return `Document numbers: ${rows.map(([, type, scheme, pattern]) => `${type === 'grn' ? 'GRN' : type} ${pattern} (${scheme})`).join(', ')}`;
}

// The rules whose check is off, and GRN letters in use outside the main run (and a highest letter that follows a letter that is not full), for `node scripts/doctor.mjs`: one warning text each. Never
// throws; an unreadable answer gives []. `run` is as for numberingLine. The text says how to switch the check on with the rule that is stored.
export const NUMBERING_PROBLEMS_SQL = "SELECT jsonb_build_object('off', COALESCE((SELECT jsonb_agg(jsonb_build_object('type', n.document_type, 'rule', warehouse_security.document_rule_json(n), "
  + "'hint', warehouse_security.document_number_pattern(n, warehouse_security.business_date(now())), 'misfits', warehouse_security.document_number_misfits(n)) "
  + "ORDER BY CASE n.document_type WHEN 'grn' THEN 1 WHEN 'dispatch' THEN 2 ELSE 3 END) FROM warehouse_security.document_numbering n WHERE NOT n.\"check\"), '[]'::jsonb), "
  + "'strays', warehouse_security.grn_stray_letters())::text";
const NAMES = { grn: 'GRN', dispatch: 'Dispatch', invoice: 'Invoice' };
// The spec of a stored rule, as setup.sh takes it, with check=on.
export function specOf(rule) {
  const parts = rule.scheme === 'letters'
    ? [`first=${rule.first_letter}`, `digits=${rule.width}`, `per-letter=${rule.per_letter}`]
    : [`prefix=${rule.prefix}`, `digits=${rule.width}`, `start=${rule.start}`];
  return [rule.scheme, ...parts, 'check=on'].join(',');
}
export function numberingProblems(run) {
  const answer = run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', NUMBERING_PROBLEMS_SQL]);
  if (!answer.ok) return [];
  let found;
  try { found = JSON.parse(answer.output.trim()); } catch { return []; }
  const problems = [];
  for (const { type, rule, hint, misfits } of Array.isArray(found?.off) ? found.off : []) {
    const count = Number(misfits?.count ?? 0);
    const examples = (misfits?.examples ?? []).join(', ');
    problems.push(`${NAMES[type] ?? type} numbers are not checked: ${count} existing number${count === 1 ? ' does' : 's do'} not follow ${hint}${examples ? ` (for example ${examples})` : ''}, so a number outside the rule is saved. `
      + `To refuse them, run setup.sh --operator <your usual options> --${type}-numbering ${specOf(rule)} (the numbers saved so far keep theirs), or an administrator switches the check on in the app.`);
  }
  const strays = Array.isArray(found?.strays?.strays) ? found.strays.strays : [];
  const open = found?.strays?.previous_not_full;
  if (strays.length) {
    problems.push(`GRN letters are in use outside the main series ${found.strays.series}: ${strays.map(({ letter, numbers, example }) => `${letter} (${numbers} number${numbers === 1 ? '' : 's'}, ${example})`).join(', ')}. `
      + 'A stray letter can steer the suggested GRN number; correct the number if it was a typing slip.');
  }
  if (open?.letter && open?.previous && open?.highest) {
    problems.push(`GRN letter ${open.letter} is in use while the letter before it, ${open.previous}, is not full (its highest number is ${open.highest}), so the suggested GRN number continues ${open.letter}. `
      + `If a ${open.letter} number was a typing slip, correct it.`);
  }
  return problems;
}

if (isMain(import.meta.url)) {
  try {
    const [command, type, spec] = process.argv.slice(2);
    if (command !== 'rule' || process.argv.length !== 5) throw new Error('Usage: node scripts/numbering.mjs rule grn|dispatch|invoice SPEC');
    console.log(JSON.stringify(parseSpec(type, spec)));
  } catch (error) {
    console.error(`Document numbers: ${error.message}`);
    process.exitCode = 1;
  }
}
