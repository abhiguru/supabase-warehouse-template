// The record of an upgrade that has not finished: $WAREHOUSE_STATE_DIR/config/upgrade-in-progress, written by upgrade.sh.
//
//   node scripts/upgrade-record.mjs message    one paragraph for doctor, start.sh and status: "an upgrade from X to Y was
//                                              interrupted at step Z ..."; prints nothing when there is no record, when the
//                                              record was written before anything changed, or while upgrade.sh itself runs
//   node scripts/upgrade-record.mjs report     the same, then the complete way forward and the complete way back (exit 1
//                                              when there is nothing to report): upgrade.sh prints it when a step fails
//   node scripts/upgrade-record.mjs rollback   only the way back, for an operator whose terminal scrolled away
//
// upgrade.sh writes the record (plain `key=value` lines, mode 0600) BEFORE the first change it makes and updates the step as each
// step starts. A rerun of the same command reads it, so it names the right backup and the right old commit and does not take a
// new backup of a half-upgraded database; success deletes it. Whatever releases are on either side of an upgrade, this file keeps
// to the format it has (`format=1`): fields are added, never renamed, so the reader of one release understands the writer of
// another. This module only reads: upgrade.sh (bash) is the only writer.
import { lstatSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { isMain } from './is-main.mjs';

export const RECORD_FILE = 'config/upgrade-in-progress';
const SHA = /^[0-9a-f]{40}$/;
const PRE_IMAGES_TAG = /^pre-[A-Za-z0-9_.-]{1,100}$/;
const clean = text => String(text ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim();

// The record, or null when there is none. A record that cannot be read as one is { invalid: reason }.
// `verified` is true once the backup taken before the upgrade has been proved to restore: only from then on can the facility
// differ from the old release's, which is when the record is something to act on.
export function readUpgradeRecord(state) {
  const path = join(state, RECORD_FILE);
  const stat = lstatSync(path, { throwIfNoEntry: false });
  if (!stat) return null;
  if (!stat.isFile()) return { invalid: `${RECORD_FILE} is not a regular file` };
  let text;
  try { text = readFileSync(path, 'utf8'); } catch (error) { return { invalid: `${RECORD_FILE} cannot be read: ${error.code ?? error.message}` }; }
  const fields = {};
  for (const line of text.split('\n')) {
    const match = /^([a-z_]+)=(.*)$/.exec(line);
    if (match && !(match[1] in fields)) fields[match[1]] = match[2];
  }
  const verified = fields.verified === 'yes';
  if (!SHA.test(fields.from_sha ?? '') || !SHA.test(fields.to_sha ?? '')) return { invalid: `${RECORD_FILE} does not name the two commits` };
  if (verified && !(fields.backup ?? '').startsWith('/')) return { invalid: `${RECORD_FILE} says the backup was verified but does not name it` };
  return {
    path, state, verified,
    fromSha: fields.from_sha, fromLabel: clean(fields.from_label) || fields.from_sha.slice(0, 12), fromTag: clean(fields.from_tag),
    toSha: fields.to_sha, toLabel: clean(fields.to_label) || fields.to_sha.slice(0, 12),
    command: clean(fields.command), backup: clean(fields.backup), step: clean(fields.step) || 'unknown', started: clean(fields.started),
    adminPhone: clean(fields.admin_phone), adminName: clean(fields.admin_name), webhookOff: fields.webhook_off === 'yes',
    // Whether the release had a preflight (ok | absent), and the tag upgrade.sh gave the images of the old release (pre-<label>), '' when it
    // saved none: a record of an upgrade.sh from before these fields has neither, and its way back is the one that rebuilds the images.
    preflight: clean(fields.preflight), preImages: PRE_IMAGES_TAG.test(fields.pre_images ?? '') ? fields.pre_images : '',
  };
}

const quote = text => `'${String(text).replace(/'/g, `'\\''`)}'`;
const mask = phone => (/^91\d{10}$/.test(phone) ? `${phone.slice(0, 2)}******${phone.slice(-4)}` : '');

// The paragraph for doctor, start.sh and the status commands. `own` is upgrade.sh describing its own failed run: nobody needs
// telling to wait for it.
export function interruptedMessage(record, { own = false } = {}) {
  if (!record || record.invalid || !record.verified) return null;
  return [
    `An upgrade from ${record.fromLabel} to ${record.toLabel} was interrupted at step "${record.step}" (started ${record.started || 'at an unknown time'}; ${RECORD_FILE}). The facility may be half upgraded.${own ? '' : ' If upgrade.sh is still running in another terminal, wait for it.'}`,
    `Continue: bash upgrade.sh ${record.command || '<the same command as before>'}   (it reuses the verified backup and takes no new one).`,
    `Or go back to ${record.fromLabel}: node scripts/upgrade-record.mjs rollback   (prints the commands).`,
  ].join(' ');
}

// What an operator runs to put the facility back on the old release, in order. Everything recorded after the backup is lost.
export function rollbackLines(record) {
  const phone = mask(record.adminPhone);
  const setup = `bash setup.sh --operator --state-dir ${quote(record.state)} --admin-phone 91XXXXXXXXXX --admin-name NAME${record.webhookOff ? ' --alert-webhook-file off' : ''}`;
  return [
    `To go back to ${record.fromLabel} (${record.fromSha}) instead, run these in the checkout, in this order. Everything the facility recorded after the backup was taken is lost:`,
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
    '  node scripts/doctor.mjs --local',
    `  rm -f ${quote(join(record.state, RECORD_FILE))}`,
    'The last line only ends the report of an interrupted upgrade; run it when the facility is healthy on the old release. docs/OPERATOR_INSTALL.md, "If it stops", explains each line.',
  ];
}

// For doctor and the status commands. Quiet while upgrade.sh itself runs (it sets WAREHOUSE_UPGRADE_RUNNING for its children).
export function interruptedUpgradeWarning(state, env = process.env) {
  if (env.WAREHOUSE_UPGRADE_RUNNING) return null;
  try { return interruptedMessage(readUpgradeRecord(state)); } catch { return null; }
}

function main(argv, env) {
  const [command] = argv;
  const state = env.WAREHOUSE_STATE_DIR;
  if (!['message', 'report', 'rollback'].includes(command) || !state?.startsWith('/')) {
    console.error('Usage: WAREHOUSE_STATE_DIR=/absolute/state node scripts/upgrade-record.mjs message|report|rollback');
    return 2;
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
