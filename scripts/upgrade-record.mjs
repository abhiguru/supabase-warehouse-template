// The record of an upgrade that has not finished: $WAREHOUSE_STATE_DIR/config/upgrade-in-progress, written by upgrade.sh.
//
//   node scripts/upgrade-record.mjs message    one paragraph for doctor, start.sh and status: "an upgrade from X to Y was
//                                              interrupted at step Z ..."; prints nothing when there is no record, when the
//                                              record was written before anything changed, or while upgrade.sh itself runs
//   node scripts/upgrade-record.mjs report     the same, then the complete way forward and the complete way back (exit 1
//                                              when there is nothing to report): upgrade.sh prints it when a step fails
//   node scripts/upgrade-record.mjs rollback   only the way back, for an operator whose terminal scrolled away
//   node scripts/upgrade-record.mjs rollback --last
//                                              the way back from an upgrade that FINISHED (config/upgrade-last, which upgrade.sh
//                                              keeps after a success): headed with what it loses, and closing the API first
//
// upgrade.sh writes the record (plain `key=value` lines, mode 0600) BEFORE the first change it makes and updates the step as each
// step starts. A rerun of the same command reads it, so it names the right backup and the right old commit and does not take a
// new backup of a half-upgraded database; success renames it to config/upgrade-last (with finished= and result=ok), which only
// `rollback --last` reads: it is history, not a warning, and doctor, start.sh and the checker never report it. Whatever releases are on either side of an upgrade, this file keeps
// to the format it has (`format=1`): fields are added, never renamed, so the reader of one release understands the writer of
// another. This module only reads: upgrade.sh (bash) is the only writer.
import { existsSync, lstatSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isMain } from './is-main.mjs';

export const RECORD_FILE = 'config/upgrade-in-progress';
export const LAST_FILE = 'config/upgrade-last';
const SHA = /^[0-9a-f]{40}$/;
const PRE_IMAGES_TAG = /^pre-[A-Za-z0-9_.-]{1,100}$/;
const clean = text => String(text ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim();

// The record, or null when there is none. A record that cannot be read as one is { invalid: reason }.
// `verified` is true once the backup taken before the upgrade has been proved to restore: only from then on can the facility
// differ from the old release's, which is when the record is something to act on.
export function readUpgradeRecord(state, file = RECORD_FILE) {
  const path = join(state, file);
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return null;
  if (!stat.isFile()) return { invalid: `${file} is not a regular file` };
  let text;
  try { text = readFileSync(path, 'utf8'); } catch (error) { return { invalid: `${file} cannot be read: ${error.code ?? error.message}` }; }
  const fields = {};
  for (const line of text.split('\n')) {
    const match = /^([a-z_]+)=(.*)$/.exec(line);
    if (match && !(match[1] in fields)) fields[match[1]] = match[2];
  }
  const verified = fields.verified === 'yes';
  if (!SHA.test(fields.from_sha ?? '') || !SHA.test(fields.to_sha ?? '')) return { invalid: `${file} does not name the two commits` };
  if (verified && !(fields.backup ?? '').startsWith('/')) return { invalid: `${file} says the backup was verified but does not name it` };
  return {
    path, state, verified,
    fromSha: fields.from_sha, fromLabel: clean(fields.from_label) || fields.from_sha.slice(0, 12), fromTag: clean(fields.from_tag),
    toSha: fields.to_sha, toLabel: clean(fields.to_label) || fields.to_sha.slice(0, 12),
    command: clean(fields.command), backup: clean(fields.backup), step: clean(fields.step) || 'unknown', started: clean(fields.started),
    adminPhone: clean(fields.admin_phone), adminName: clean(fields.admin_name), webhookOff: fields.webhook_off === 'yes',
    // Whether the release had a preflight (ok | absent), and the tag upgrade.sh gave the images of the old release (pre-<label>), '' when it
    // saved none: a record of an upgrade.sh from before these fields has neither, and its way back is the one that rebuilds the images.
    preflight: clean(fields.preflight), preImages: PRE_IMAGES_TAG.test(fields.pre_images ?? '') ? fields.pre_images : '',
    // Whether upgrade.sh closed the API (maintenance mode, scripts/maintenance.sh) for this upgrade: a record of an upgrade.sh from before it has
    // no such line, and its way back is the one that does not mention maintenance mode (the old release may not have the script).
    maintenance: fields.maintenance === 'on',
    // The record has a maintenance= line at all: the release that wrote it closes the API (and so has scripts/maintenance.sh to open it again).
    maintenanceKnown: 'maintenance' in fields,
    // upgrade.sh opened the API at the end and the health check that follows failed: the API is OPEN (maintenance=opened), whatever the step says.
    apiOpen: fields.maintenance === 'opened',
    // upgrade-last only: when upgrade.sh finished (UTC).
    finished: clean(fields.finished),
  };
}

const quote = text => `'${String(text).replace(/'/g, `'\\''`)}'`;
// The time in the name of a backup folder (warehouse-YYYYMMDDTHHMMSSZ), as 'YYYY-MM-DD HH:MM:SS', or ''.
const backupTime = path => {
  const match = /warehouse-(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z\/?$/.exec(path ?? '');
  return match ? `${match[1]}-${match[2]}-${match[3]} ${match[4]}:${match[5]}:${match[6]}` : '';
};
const mask = phone => (/^91\d{10}$/.test(phone) ? `${phone.slice(0, 2)}******${phone.slice(-4)}` : '');

// The paragraph for doctor, start.sh and the status commands. `own` is upgrade.sh describing its own failed run: nobody needs
// telling to wait for it.
export function interruptedMessage(record, { own = false } = {}) {
  if (!record || record.invalid || !record.verified) return null;
  return [
    `An upgrade from ${record.fromLabel} to ${record.toLabel} was interrupted at step "${record.step}" (started ${record.started || 'at an unknown time'}; ${RECORD_FILE}). The facility may be half upgraded.${own ? '' : ' If upgrade.sh is still running in another terminal, wait for it.'}`,
    `Continue: bash upgrade.sh ${record.command || '<the same command as before>'}   (it reuses the verified backup and takes no new one).`,
    `Or go back to ${record.fromLabel}: node scripts/upgrade-record.mjs rollback   (prints the commands).`,
    ...(record.apiOpen ? ['The API is open to phones again (maintenance mode is off); the health check that follows failed, so look at it: node scripts/watch.mjs health.'] : []),
    ...(record.maintenance ? ['The API stays closed to phones (maintenance mode: they are told the server is being updated) until the upgrade has finished or you run: bash scripts/maintenance.sh off.'] : []),
  ].join(' ');
}

// What an operator runs to put the facility back on the old release, in order. Everything recorded after the backup is lost: with the API closed
// (maintenance mode, from before the backup) that is only what reached the database another way, fas-sync if it was not paused.
// `last`: the way back from an upgrade that finished (config/upgrade-last). The API was open for phones since, so what they recorded since the
// backup is lost as well; the list therefore starts by closing the API (the first thing, so that nothing more is recorded that is then lost),
// opens it again before the doctor, and ends with the removal of upgrade-last, not of the record of an interrupted upgrade.
export function rollbackLines(record, { last = false, imagesGone = false } = {}) {
  const phone = mask(record.adminPhone);
  // An upgrade-last of an upgrade.sh from before maintenance mode has no maintenance= line: its old release may have no scripts/maintenance.sh.
  const closes = last ? record.maintenanceKnown : record.maintenance;
  // The saved images of the old release (pre-<release>) were removed since (docker image prune, a later upgrade): no restore or save line, and setup builds.
  if (imagesGone) record = { ...record, preImages: '' };
  const headline = last
    ? `To go back to ${record.fromLabel} (${record.fromSha}) after the upgrade to ${record.toLabel} that finished${record.finished ? ` at ${record.finished}` : ''}, run these in the checkout, in this order. WARNING: everything the facility recorded after the backup${backupTime(record.backup) ? ` (taken ${backupTime(record.backup)} UTC)` : ''} is lost, and phones have been recording since the upgrade finished: every receipt, dispatch, invoice and order entered since is NOT in the backup and is gone after this. This is the last resort: when the problem can be fixed by a patch release of ${record.toLabel}, wait for that and upgrade to it instead.${imagesGone ? ` The images of ${record.fromLabel} that the upgrade saved are no longer on this host, so the old release's setup builds its images again (that needs the network).` : ''}`
    : `To go back to ${record.fromLabel} (${record.fromSha}) instead, run these in the checkout, in this order. ${record.maintenance
      ? 'The API has been closed to phones since before the backup, so phones recorded nothing after it; what reached the database another way (fas-sync, if it was not paused, or a psql session) is lost:'
      : 'Everything the facility recorded after the backup was taken is lost:'}`;
  const setup = `bash setup.sh --operator --state-dir ${quote(record.state)} --admin-phone 91XXXXXXXXXX --admin-name NAME${record.webhookOff ? ' --alert-webhook-file off' : ''}`;
  return [
    headline,
    // The finished upgrade is put back on record as an interrupted one first: until the list has been run to its end, doctor, start.sh and the
    // checker report an interrupted upgrade with the way out, and the checker's self-heal stays paused (mode 0600 is kept).
    ...(last ? [
      `  cp -p ${quote(join(record.state, LAST_FILE))} ${quote(join(record.state, RECORD_FILE))}`,
      '      (puts the record of the upgrade back as the report of an interrupted one: from here doctor and the checker say so, and the checker does not repair anything meanwhile)',
    ] : []),
    ...(last && closes ? [
      '  bash scripts/maintenance.sh on',
      '      (closes the API to phones first: from here nothing more is recorded that the restore would lose; it stays closed until the line that opens it)',
    ] : []),
    `  (umask 022; git checkout --detach ${record.fromSha})`,
    '  bash stop.sh',
    ...(record.preImages ? [
      `  bash scripts/pre-images.sh restore ${quote(record.fromLabel)}`,
      `      (puts back the images the old release ran, ${record.preImages}, and their build record, so that setup normally builds nothing; run it before the restore, which also checks the db image)`,
    ] : []),
    `  npm run db:restore -- --yes --restore-config ${quote(record.backup)}`,
    `  ${setup}`,
    `      (the administrator's number and name as at installation${phone ? `; the number is ${phone}` : ''}; setup of the old release ${record.preImages ? 'finds its images current and builds only what the saved set lacks' : 'rebuilds the images that the new release changed'})`,
    ...(record.preImages ? [
      '  bash scripts/build-images.sh --save',
      `      (builds nothing: writes the old release's images and their signed build record to ${join(record.state, 'images')} again, where the new release's still are, because setup found the images current and so saved none; a lost-host restore loads that folder)`,
    ] : []),
    '  bash scripts/compose.sh up -d --force-recreate --no-deps --wait --wait-timeout 180 functions',
    ...(closes ? [
      '  bash scripts/maintenance.sh off',
      `      (opens the API to phones again: ${last ? 'the first line of this list' : 'the upgrade'} closed it, and it stays closed, through the restore and the setup above, until this line; it ends with the health check)`,
    ] : []),
    '  node scripts/doctor.mjs --local',
    last ? `  rm -f ${quote(join(record.state, RECORD_FILE))} ${quote(join(record.state, LAST_FILE))}` : `  rm -f ${quote(join(record.state, RECORD_FILE))}`,
    last
      ? 'The last line removes the report of an interrupted upgrade that the first line made, and the note of the finished one (config/upgrade-last); run it when the doctor is green on the old release. docs/OPERATOR_INSTALL.md, "Found a problem after the upgrade", explains each line.'
      : 'The last line only ends the report of an interrupted upgrade; run it when the facility is healthy on the old release. docs/OPERATOR_INSTALL.md, "If it stops", explains each line.',
  ];
}

// Whether images tagged <something>:<tag> of an installation (warehouse-...) exist on this host: `docker image ls` lists them. No Docker, or an answer
// that is not understood, is "no": the restore line would fail then.
function savedImagesPresent(tag) {
  const listed = spawnSync('docker', ['image', 'ls', '--format', '{{.Repository}} {{.Tag}}'], { encoding: 'utf8' });
  if (listed.status !== 0) return false;
  return listed.stdout.split('\n').some(line => { const [repository, imageTag] = line.trim().split(' '); return imageTag === tag && /^warehouse-/.test(repository ?? ''); });
}

// The way back from the upgrade that finished last (config/upgrade-last): { text } or { refusal } (one sentence). `head` is the commit the checkout
// is at now (the caller asks git); the list is for the release that upgrade installed, so a checkout anywhere else is refused.
export function lastRollbackText(state, { head, exists = existsSync, imagesPresent = savedImagesPresent } = {}) {
  const record = readUpgradeRecord(state, LAST_FILE);
  if (!record) return { refusal: `No finished upgrade is recorded (${LAST_FILE} does not exist: upgrade.sh writes it when an upgrade succeeds).` };
  if (record.invalid) return { refusal: `${record.invalid}; read it, and remove it when it is of no use.` };
  if (lstatSync(join(state, RECORD_FILE), { throwIfNoEntry: false })) return { refusal: `An upgrade is recorded as interrupted (${RECORD_FILE}); use "node scripts/upgrade-record.mjs rollback" for that one, and finish or undo it first.` };
  if (!record.backup || !exists(record.backup)) return { refusal: `The backup of that upgrade (${record.backup || 'none recorded'}) is not on this host any more, so there is nothing to go back to.` };
  if (head !== record.toSha) return { refusal: `This checkout is at ${head ? head.slice(0, 12) : 'an unknown commit'}, not at ${record.toLabel} (${record.toSha.slice(0, 12)}) that the last upgrade installed, so its way back does not fit this facility.` };
  return { text: rollbackLines(record, { last: true, imagesGone: Boolean(record.preImages) && !imagesPresent(record.preImages) }).join('\n') };
}

// For doctor and the status commands. Quiet while upgrade.sh itself runs (it sets WAREHOUSE_UPGRADE_RUNNING for its children).
export function interruptedUpgradeWarning(state, env = process.env) {
  if (env.WAREHOUSE_UPGRADE_RUNNING) return null;
  try { return interruptedMessage(readUpgradeRecord(state)); } catch { return null; }
}

function main(argv, env) {
  const [command, ...flags] = argv;
  const state = env.WAREHOUSE_STATE_DIR;
  const last = command === 'rollback' && flags.length === 1 && flags[0] === '--last';
  if (!['message', 'report', 'rollback'].includes(command) || !state?.startsWith('/') || (flags.length && !last)) {
    console.error('Usage: WAREHOUSE_STATE_DIR=/absolute/state node scripts/upgrade-record.mjs message|report|rollback [--last]');
    return 2;
  }
  if (last) {
    const checkout = join(dirname(fileURLToPath(import.meta.url)), '..');
    const head = spawnSync('git', ['-C', checkout, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
    const answer = lastRollbackText(state, { head: head.status === 0 ? head.stdout.trim() : '' });
    if (answer.refusal) { console.error(answer.refusal); return 1; }
    console.log(answer.text);
    return 0;
  }
  const record = readUpgradeRecord(state);
  if (record?.invalid) { console.error(`Warning: ${record.invalid}. Read it, and remove it when no upgrade is pending.`); return command === 'message' ? 0 : 1; }
  const text = interruptedMessage(record, { own: command === 'report' });
  if (command === 'message') {
    const warning = interruptedUpgradeWarning(state, env);
    if (warning) console.log(warning);
    return 0;
  }
  if (!text) { console.error('No upgrade is recorded as interrupted.'); return 1; }
  if (command === 'report') console.log(text);
  console.log(rollbackLines(record).join('\n'));
  return 0;
}

if (isMain(import.meta.url)) process.exitCode = main(process.argv.slice(2), process.env);
