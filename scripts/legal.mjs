// The facility's legal settings (migration 199, WH-140): the values the app's terms and privacy pages are filled from.
//   node scripts/legal.mjs check --legal-city=VALUE ...   checks the setup.sh options and prints them as the JSON object the database takes
// Doctor warns about the grievance email, phone and the seat that are empty (docs/PRIVACY_FOR_OPERATORS.md).
import { isMain } from './is-main.mjs';

export const LEGAL_OPTIONS = { '--legal-name': 'legalName', '--legal-city': 'city', '--legal-state': 'state',
  '--grievance-name': 'grievanceName', '--grievance-email': 'grievanceEmail', '--grievance-phone': 'grievancePhone' };

// Same rules as warehouse_security.apply_facility_legal, so setup refuses a bad value before it starts anything.
export function checkLegal(values) {
  const out = {};
  for (const [option, key] of Object.entries(LEGAL_OPTIONS)) {
    if (!(key in values)) continue;
    const value = String(values[key]).trim();
    if (value.length > 120 || /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(value)) throw new Error(`${option} must be printable text of at most 120 characters.`);
    if (key === 'grievanceEmail' && value && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value)) throw new Error('--grievance-email must be an email address.');
    if (key === 'grievancePhone' && value && !/^[0-9+() -]{5,20}$/.test(value)) throw new Error('--grievance-phone must be 5 to 20 digits, spaces, + ( ) or -.');
    out[key] = value;
  }
  return out;
}

export const LEGAL_SQL = 'SELECT warehouse_security.facility_legal()::text';
const LABELS = { city: 'city', state: 'state', grievanceName: 'grievance officer\'s name', grievanceEmail: 'grievance email', grievancePhone: 'grievance phone' };
// One warning per empty value, for `node scripts/doctor.mjs`. Never throws: an unreadable answer gives []. `run` takes the psql arguments and
// returns { ok, output } (doctor passes the db container).
export function legalProblems(run) {
  const answer = run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'supabase_admin', '-d', 'postgres', '-c', LEGAL_SQL]);
  if (!answer.ok) return [];
  let found;
  try { found = JSON.parse(answer.output.trim()); } catch { return []; }
  return Object.entries(LABELS).filter(([key]) => typeof found?.[key] === 'string' && found[key].trim() === '').map(([key, label]) =>
    `The ${label} for the app's terms and privacy pages is empty, so they read "Not given yet". Set it with setup.sh --operator <your usual options> ${Object.entries(LEGAL_OPTIONS).find(([, k]) => k === key)[0]} VALUE, or an administrator sets it in the app (docs/PRIVACY_FOR_OPERATORS.md).`);
}

if (isMain(import.meta.url)) {
  try {
    const [command, ...pairs] = process.argv.slice(2);
    if (command !== 'check') throw new Error('Usage: node scripts/legal.mjs check --legal-city=VALUE ...');
    const values = {};
    for (const pair of pairs) {
      const i = pair.indexOf('=');
      if (!(pair.slice(0, i) in LEGAL_OPTIONS)) throw new Error(`unknown option ${pair.slice(0, i)}`);
      values[LEGAL_OPTIONS[pair.slice(0, i)]] = pair.slice(i + 1);
    }
    console.log(JSON.stringify(checkLegal(values)));
  } catch (error) {
    console.error(`Legal settings: ${error.message}`);
    process.exitCode = 1;
  }
}
