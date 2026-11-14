// Doctor warning for the USB backup drive (scripts/backup-usb.sh). When USB backup is not set up for this state it says so (the
// backups and their key then sit only on this host), unless the decision not to keep an off-host copy is recorded. Returns null when
// the last copy is recent and successful (the saved images included) and,
// when archives are encrypted, the operator has confirmed a copy of the backup key. It warns first when the installation
// still writes readable archives although nobody typed --no-encrypt: it never ran `backup-usb.sh setup` after encryption
// became the default.
import { readFileSync, lstatSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import { resolve } from 'node:path';
import { declinedMarker, OFFHOST_DECLINED_NAME, OFFHOST_DECLINED_SENTENCE } from './declined-marker.mjs';

const fields = text => Object.fromEntries(text.split('\n').filter(line => line.includes('=')).map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
const read = path => { try { return readFileSync(path, 'utf8'); } catch { return null; } };

// The fingerprint scripts/backup-key.sh (backup_key_fingerprint) records: the first 16 hexadecimal characters of the
// HMAC-SHA256 of the label under the key. It is not the key and cannot be turned back into it.
export const keyFingerprint = key => createHmac('sha256', Buffer.from(key, 'hex')).update('warehouse-backup-key-fingerprint-v1\n').digest('hex').slice(0, 16);

// null when a copy of the backup key was confirmed (scripts/backup-key-escrow.sh) for the key in use, else the reason.
export function escrowProblem(state) {
  const keyText = read(resolve(state, 'config/backup.key'));
  const key = (keyText ?? '').split('\n')[0].replace(/\r$/, '');
  if (!/^[0-9a-f]{64}$/.test(key)) return null; // no usable key here: the backup commands say so themselves
  // As scripts/backup-key.sh does: a record that is a link is not trusted, and the first fingerprint line counts.
  const path = resolve(state, 'config/backup-key.escrow');
  let isLink = false;
  try { isLink = lstatSync(path).isSymbolicLink(); } catch { /* absent: read() says so */ }
  const record = isLink ? null : read(path);
  if (record === null) return 'there is no key escrow record';
  const lines = record.split('\n');
  const recorded = lines.find(line => line.startsWith('key_fingerprint='))?.slice('key_fingerprint='.length);
  if (lines[0] !== 'warehouse-backup-key-escrow-v1' || !/^[0-9a-f]{16}$/.test(recorded ?? '')) return 'the key escrow record is not valid';
  if (recorded !== keyFingerprint(key)) return 'the key escrow record is for another backup key (the key was replaced since the copy was confirmed)';
  return null;
}

// What an installation with no USB backup is told: the backups and the key that opens them sit on this one disk.
export const NO_OFFHOST_COPY = `No copy of the backups is kept outside this host: set up the USB backup drive (docs/OPERATOR_INSTALL.md, "USB backup drive"), or record the decision in config/${OFFHOST_DECLINED_NAME}.`;

// Information, never an alert: when the drives that wrote a copy in the last 30 days are fewer than two, the copy never leaves the building
// (a drive that stays plugged in is in the same fire, flood or theft as the host). null when there is no history (config/usb-backup.history,
// "<epoch> <filesystem UUID>" lines that scripts/backup-usb.sh appends after a good copy) or two drives wrote.
export const ROTATION_NOTE = 'Only one USB drive has written a backup in the last 30 days: take a copy away from the building by enrolling a second drive and swapping them weekly.';
export function usbRotationNote(state, now = Date.now()) {
  const history = read(resolve(state, 'config/usb-backup.history'));
  if (!history) return null;
  const drives = new Set();
  for (const line of history.split('\n')) {
    const [epoch, uuid, ...rest] = line.trim().split(/\s+/);
    if (rest.length || !uuid || !/^\d+$/.test(epoch)) continue;
    const age = now - Number(epoch) * 1000;
    if (age >= 0 && age <= 30 * 86400000) drives.add(uuid);
  }
  return drives.size === 1 ? ROTATION_NOTE : null;
}

// The optional off-site copy (scripts/offsite.sh): { enabled, fresh, problem }. fresh: an upload was checked in the last 2 days (this
// satisfies the off-host copy rule, as a recent USB copy does). problem: what the alert offsite_upload_failed says, or null: the last
// run failed, or it is on and no checked upload exists after 2 days. Reads two files of the state; the credentials are never read here.
export const OFFSITE_FRESH_MS = 2 * 86400000;
export function offsiteStatus(state, now = Date.now()) {
  const conf = fields(read(resolve(state, 'config/offsite.conf')) ?? '');
  const enabled = conf.ENABLED === 'yes';
  if (!enabled) return { enabled: false, fresh: false, problem: null };
  const last = fields(read(resolve(state, 'config/offsite.last')) ?? '');
  const success = (Number(last.last_success_epoch) || 0) * 1000;
  const fresh = success > 0 && now - success <= OFFSITE_FRESH_MS && last.result !== 'failed';
  const since = (Number(conf.ENABLED_EPOCH) || 0) * 1000;
  let problem = null;
  if (last.result === 'failed') problem = `The off-site copy of the backups failed at ${last.finished_utc || 'an unknown time'}: ${last.message || 'no detail'}. Run bash scripts/offsite.sh status.`;
  else if (!fresh && (success > 0 || now - since > OFFSITE_FRESH_MS)) problem = 'No off-site upload has been checked in the last 2 days (the nightly upload did not run or did not finish). Run bash scripts/offsite.sh status.';
  return { enabled, fresh, problem };
}

export function usbBackupWarning(state, {
  now = Date.now(),
  maxAgeDays = Number(process.env.WAREHOUSE_USB_BACKUP_MAX_AGE_DAYS || 7),
  etc = process.env.WAREHOUSE_USB_BACKUP_ETC || '/etc',
  offsiteFresh = false,   // true: a checked off-site upload exists from the last 2 days; it counts as the off-host copy only where USB is not set up here (the key copy rule still applies)
  graceOver = true,   // false: the checker is in its first 7 days, so "no copy yet" is not said (a failed, stale or key-copy fault always is)
} = {}) {
  const conf = read(resolve(etc, 'warehouse-usb-backup.conf'));
  const last = read(resolve(state, 'config/usb-backup.last'));
  const noConf = !conf || fields(conf).STATE !== resolve(state);
  // Not set up here. A recorded decision (config/offhost-copy-declined, exact sentence, mode 0600) is the operator's answer, whatever an old
  // usb-backup.last says; it does not excuse an unconfirmed copy of the backup key, which is said all the same.
  const declined = noConf && declinedMarker(state, OFFHOST_DECLINED_NAME, OFFHOST_DECLINED_SENTENCE);
  if (noConf && (!last || declined || offsiteFresh)) {
    const problem = escrowProblem(state);
    const show = `run WAREHOUSE_STATE_DIR=${resolve(state)} bash scripts/backup-key-escrow.sh show`;
    const noCopy = !declined && graceOver && !offsiteFresh;
    if (offsiteFresh) return problem ? `The backup key copy is not confirmed (${problem}); the off-site copy is encrypted with the backup key and cannot be opened without it: ${show}` : null;
    if (noCopy) return problem ? `${NO_OFFHOST_COPY} The backup key copy is not confirmed either (${problem}): ${show}` : NO_OFFHOST_COPY;
    return problem ? `The backup key copy is not confirmed (${problem}): ${show}` : null;
  }
  const setUp = conf && fields(conf).STATE === resolve(state) ? fields(conf) : null;
  if (setUp) {
    // The setup of an earlier release stored ENCRYPT=no and wrote WAREHOUSE_BACKUP_ENCRYPT=0 into the unit as the default, not as
    // the operator's choice. Only a typed --no-encrypt (ENCRYPT_SET=typed) keeps readable archives; every other installation is
    // still writing them until it runs setup again, which also installs the longer time limit and the keep count of this release.
    const unit = read(resolve(etc, 'systemd/system/warehouse-usb-backup@.service')) ?? '';
    const unitReadable = /^Environment=WAREHOUSE_BACKUP_ENCRYPT=0$/m.test(unit);
    if (setUp.ENCRYPT_SET !== 'typed' && (setUp.ENCRYPT === 'no' || unitReadable)) {
      return `USB archives are still written unencrypted (the default of earlier releases; nobody typed --no-encrypt), and this installation has not run the USB setup since encryption became the default: run sudo bash scripts/backup-usb.sh setup --state ${resolve(state)}; it switches them to encrypted archives (readable archives, which hold every credential, stay only with --no-encrypt) and installs this release's unit`;
    }
  }
  // Archives are encrypted with the backup key, which lives only on this machine's disk: without a confirmed copy kept
  // elsewhere, the loss of the host is also the loss of every archive. Runs and enrolment are refused until it is confirmed.
  if (setUp && setUp.ENCRYPT === 'yes') {
    const problem = escrowProblem(state);
    if (problem) return `USB archives are encrypted but the backup key copy is not confirmed (${problem}); runs are refused until it is: run WAREHOUSE_STATE_DIR=${resolve(state)} bash scripts/backup-key-escrow.sh show`;
  }
  // With USB set up here, its checks are the same with or without the off-site copy (the USB rule is unchanged, and the saved images are
  // copied to the USB drive only): a fresh off-site upload never hides a failed, stale or missing USB copy or its images problem. The
  // off-site copy is encrypted with the backup key as well, so when it is fresh its key copy is checked too (when USB archives are
  // encrypted the check above already did), and said beside any USB problem.
  const usb = usbRunProblem(last, { now, maxAgeDays, graceOver });
  const keyProblem = offsiteFresh ? escrowProblem(state) : null;
  if (!keyProblem) return usb;
  const keyText = `The backup key copy is not confirmed (${keyProblem}); the off-site copy is encrypted with the backup key and cannot be opened without it: run WAREHOUSE_STATE_DIR=${resolve(state)} bash scripts/backup-key-escrow.sh show`;
  return usb ? `${usb} ${keyText}` : keyText;
}

// The checks of the last run of an installed USB backup (config/usb-backup.last), as they were before the off-site copy existed.
function usbRunProblem(last, { now, maxAgeDays, graceOver }) {
  if (!last) return graceOver ? 'USB backup is set up but no copy has been made yet: attach the enrolled USB drive.' : null;
  const run = fields(last);
  if (run.result !== 'ok') return `The last USB backup failed at ${run.finished_utc || 'an unknown time'}: ${run.message || 'no detail'}. Run bash scripts/backup-usb.sh status.`;
  const success = Number(run.last_success_epoch) * 1000;
  const days = Math.floor((now - success) / 86400000);
  if (!Number.isFinite(days) || days >= maxAgeDays) return `The last successful USB backup is ${Number.isFinite(days) ? `${days} days` : 'of unknown age'} old: attach the enrolled USB drive.`;
  // The archive was copied; only the saved images were not (scripts/backup-usb.sh records that apart from a failed copy).
  if (run.images_problem) return `The last USB backup copied the archive but not the saved images: ${run.images_problem}. The drive then holds no saved images or an earlier copy, and a lost-host restore from it builds the images it lacks.`;
  return null;
}
