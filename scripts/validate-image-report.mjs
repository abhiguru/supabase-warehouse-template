// Validates one Trivy image report (JSON, SchemaVersion 2).
//
//   node validate-image-report.mjs REPORT IMAGE
//     Strict: the report must be for IMAGE, carry a versioned package inventory
//     in every result, and hold no HIGH or CRITICAL row.
//   node validate-image-report.mjs REPORT IMAGE --exceptions LEDGER --recipe RECIPE
//     The same checks, but a row (or a missing inventory) may be covered by a
//     valid entry of the exception ledger (docker/image-exceptions.json) for
//     RECIPE: the Dockerfile path of a built image (docker/<name>/Dockerfile) or
//     the pinned reference of a pulled one. scripts/scan-images.sh runs it twice
//     per image: on the --ignore-unfixed report (rows with a listed fix) and on
//     the full report (rows with no fix as well).
//
// Ledger rules (an invalid entry rejects the whole ledger, used or not):
// - every entry names a recipe, a class, an owner, a reason, the date the owner
//   reviewed it and an expiry no later than 90 days after that review; an entry
//   that has expired, or was reviewed in the future, is invalid;
// - class "no-fix" covers rows with no fixed version only, by status and severity;
//   a row with a listed fix is never covered by it;
// - class "advisory" covers the named advisories in the named packages, with or
//   without a fix: the way to record a fix the publisher has not shipped yet;
// - class "no-package-inventory" accepts a report with no results at all, only for
//   the exact image digest it names (in the image reference and in the scanned
//   image's repository digests), with its compensating controls listed.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const DAY = 24 * 60 * 60 * 1000;
export const MAX_EXCEPTION_DAYS = 90;
const SEVERITIES = ['HIGH', 'CRITICAL'];
const NO_FIX_STATUSES = ['affected', 'fix_deferred', 'will_not_fix', 'under_investigation', 'end_of_life', 'unknown'];
const FIELDS = {
  common: ['id', 'recipe', 'class', 'owner', 'reason', 'reviewed', 'expires'],
  'no-fix': ['statuses', 'severities', 'pkgClass'],
  advisory: ['advisories', 'packages', 'severities'],
  'no-package-inventory': ['digest', 'compensatingControls'],
};

const fail = message => { throw new Error(message); };
const nonEmptyString = value => typeof value === 'string' && value.trim().length > 0;
const stringList = (value, allowed) => Array.isArray(value) && value.length > 0 &&
  value.every(item => nonEmptyString(item) && (!allowed || allowed.includes(item))) &&
  new Set(value).size === value.length;

function day(value, what) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) fail(`${what} is not a YYYY-MM-DD date`);
  const time = Date.parse(`${value}T00:00:00Z`);
  if (Number.isNaN(time) || new Date(time).toISOString().slice(0, 10) !== value) fail(`${what} is not a real date`);
  return time;
}

export function utcToday(now = new Date()) {
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
}

// Returns the entries, or throws naming the first invalid one.
export function validateLedger(ledger, today = utcToday()) {
  if (!ledger || typeof ledger !== 'object' || Array.isArray(ledger)) fail('exception ledger is not a JSON object');
  if (ledger.schemaVersion !== 1) fail('exception ledger schemaVersion must be 1');
  if (!Array.isArray(ledger.exceptions)) fail('exception ledger has no exceptions list');
  const ids = new Set();
  for (const entry of ledger.exceptions) {
    const id = entry?.id;
    const where = `exception ${nonEmptyString(id) ? id : '(no id)'}`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) fail(`${where} is not an object`);
    if (typeof id !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(id)) fail(`${where}: id must be lower-case letters, digits and hyphens`);
    if (ids.has(id)) fail(`${where}: duplicate id`);
    ids.add(id);
    if (!Object.hasOwn(FIELDS, entry.class) || entry.class === 'common') fail(`${where}: unknown class ${JSON.stringify(entry.class)}`);
    const allowed = [...FIELDS.common, ...FIELDS[entry.class]];
    const unknown = Object.keys(entry).filter(key => !allowed.includes(key));
    if (unknown.length) fail(`${where}: unknown field ${unknown.join(', ')}`);
    if (!nonEmptyString(entry.recipe)) fail(`${where}: no recipe`);
    if (typeof entry.owner !== 'string' || !/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/.test(entry.owner)) fail(`${where}: no named owner`);
    if (!nonEmptyString(entry.reason) || entry.reason.trim().length < 20) fail(`${where}: no reason`);
    const reviewed = day(entry.reviewed, `${where}: reviewed`);
    const expires = day(entry.expires, `${where}: expires`);
    if (reviewed > today) fail(`${where}: reviewed ${entry.reviewed} is in the future`);
    if (expires <= reviewed) fail(`${where}: expires ${entry.expires} is not after its review`);
    if (expires - reviewed > MAX_EXCEPTION_DAYS * DAY) fail(`${where}: expires more than ${MAX_EXCEPTION_DAYS} days after its review`);
    if (expires < today) fail(`${where}: expired on ${entry.expires}`);
    if (entry.class === 'no-fix') {
      if (!stringList(entry.statuses, NO_FIX_STATUSES)) fail(`${where}: statuses must list no-fix statuses (${NO_FIX_STATUSES.join(', ')})`);
      if (!stringList(entry.severities, SEVERITIES)) fail(`${where}: severities must list HIGH and/or CRITICAL`);
      if (entry.pkgClass !== undefined && !['os-pkgs', 'lang-pkgs'].includes(entry.pkgClass)) fail(`${where}: pkgClass must be os-pkgs or lang-pkgs`);
    } else if (entry.class === 'advisory') {
      if (!stringList(entry.advisories)) fail(`${where}: advisories must list advisory IDs`);
      if (!stringList(entry.packages)) fail(`${where}: packages must list package names`);
      if (!stringList(entry.severities, SEVERITIES)) fail(`${where}: severities must list HIGH and/or CRITICAL`);
    } else {
      if (typeof entry.digest !== 'string' || !/^sha256:[0-9a-f]{64}$/.test(entry.digest)) fail(`${where}: digest must be sha256:<64 hex>`);
      if (!entry.recipe.endsWith(`@${entry.digest}`)) fail(`${where}: recipe must be the image reference pinned to its digest`);
      if (!stringList(entry.compensatingControls)) fail(`${where}: compensatingControls must be listed`);
    }
  }
  return ledger.exceptions;
}

const hasFix = row => nonEmptyString(row.FixedVersion) || row.Status === 'fixed';

function covers(entry, row, result) {
  if (!entry.severities?.includes(row.Severity)) return false;
  if (entry.class === 'advisory') return entry.advisories.includes(row.VulnerabilityID) && entry.packages.includes(row.PkgName);
  if (entry.class !== 'no-fix' || hasFix(row)) return false;
  return entry.statuses.includes(row.Status ?? 'unknown') && (!entry.pkgClass || entry.pkgClass === result.Class);
}

// Returns a summary line, or throws with the reason the evidence is rejected.
export function validateReport(report, image, { entries = [], recipe } = {}) {
  if (report?.SchemaVersion !== 2 || report.ArtifactName !== image || report.ArtifactType !== 'container_image' ||
      (report.Results !== undefined && !Array.isArray(report.Results))) {
    fail('missing or mismatched container scan evidence');
  }
  const own = recipe === undefined ? [] : entries.filter(entry => entry.recipe === recipe);
  if (!report.Results?.length) {
    const digests = Array.isArray(report.Metadata?.RepoDigests) ? report.Metadata.RepoDigests : [];
    const accepted = own.find(entry => entry.class === 'no-package-inventory' && image.endsWith(`@${entry.digest}`) &&
      digests.some(value => typeof value === 'string' && value.endsWith(`@${entry.digest}`)));
    if (!accepted) fail('missing or mismatched container scan evidence (no package results, and no no-package-inventory exception for this image digest)');
    return `no package inventory, accepted by exception ${accepted.id} until ${accepted.expires}`;
  }
  const uncovered = [];
  const used = new Map();
  for (const result of report.Results) {
    if (!result?.Target || !['os-pkgs', 'lang-pkgs'].includes(result.Class) || !Array.isArray(result.Packages) ||
        !result.Packages.some(pkg => typeof pkg?.Name === 'string' && pkg.Name.length > 0 &&
          typeof pkg.Version === 'string' && pkg.Version.length > 0) ||
        (result.Vulnerabilities !== undefined && !Array.isArray(result.Vulnerabilities))) {
      fail('invalid vulnerability result or missing versioned package inventory');
    }
    for (const row of result.Vulnerabilities ?? []) {
      if (!SEVERITIES.includes(row?.Severity)) continue;
      const entry = own.find(candidate => covers(candidate, row, result));
      if (entry) used.set(entry.id, (used.get(entry.id) ?? 0) + 1);
      else uncovered.push(row);
    }
  }
  if (uncovered.length) {
    const shown = uncovered.slice(0, 5).map(row => `${row.VulnerabilityID ?? '?'} ${row.PkgName ?? '?'} ${row.InstalledVersion ?? '?'}` +
      (hasFix(row) ? ` (fixed in ${row.FixedVersion ?? '?'})` : ` (${row.Status ?? 'no status'})`));
    fail(`HIGH/CRITICAL vulnerabilities remain: ${uncovered.length} row(s) without a valid exception, e.g. ${shown.join('; ')}`);
  }
  const total = [...used.values()].reduce((sum, count) => sum + count, 0);
  return total ? `${total} HIGH/CRITICAL row(s) covered by exceptions ${[...used.keys()].join(', ')}` : 'no HIGH/CRITICAL rows';
}

function main(argv) {
  const [path, image, ...rest] = argv;
  const options = {};
  while (rest.length) {
    const flag = rest.shift();
    if (!['--exceptions', '--recipe'].includes(flag) || rest.length === 0) fail(`unknown or incomplete option ${flag}`);
    options[flag.slice(2)] = rest.shift();
  }
  if ((options.exceptions === undefined) !== (options.recipe === undefined)) fail('--exceptions and --recipe go together');
  if (!path || !image) fail('usage: validate-image-report.mjs REPORT IMAGE [--exceptions LEDGER --recipe RECIPE]');
  const entries = options.exceptions === undefined ? [] : validateLedger(JSON.parse(readFileSync(options.exceptions, 'utf8')));
  return validateReport(JSON.parse(readFileSync(path, 'utf8')), image, { entries, recipe: options.recipe });
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const image = process.argv[3];
  try {
    console.log(`Image scan evidence accepted for ${image}: ${main(process.argv.slice(2))}`);
  } catch (error) {
    console.error(`Image scan evidence rejected for ${image}: ${error.message}`);
    process.exitCode = 1;
  }
}
