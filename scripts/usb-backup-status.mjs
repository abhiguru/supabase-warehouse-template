// Doctor warning for the USB backup drive (scripts/backup-usb.sh). Returns null when
// USB backup is not set up for this state or the last copy is recent and successful (the saved images included) and,
// when archives are encrypted, the operator has confirmed a copy of the backup key. It warns first when the installation
// still writes readable archives although nobody typed --no-encrypt: it never ran `backup-usb.sh setup` after encryption
// became the default.
import { readFileSync, lstatSync } from 'node:fs';
import { createHmac } from 'node:crypto';
import { resolve } from 'node:path';

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

export function usbBackupWarning(state, {
  now = Date.now(),
  maxAgeDays = Number(process.env.WAREHOUSE_USB_BACKUP_MAX_AGE_DAYS || 7),
  etc = process.env.WAREHOUSE_USB_BACKUP_ETC || '/etc',
} = {}) {
  const conf = read(resolve(etc, 'warehouse-usb-backup.conf'));
  const last = read(resolve(state, 'config/usb-backup.last'));
  if (!last && (!conf || fields(conf).STATE !== resolve(state))) return null;
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
  if (!last) return 'USB backup is set up but no copy has been made yet: attach the enrolled USB drive.';
  const run = fields(last);
  if (run.result !== 'ok') return `The last USB backup failed at ${run.finished_utc || 'an unknown time'}: ${run.message || 'no detail'}. Run bash scripts/backup-usb.sh status.`;
  const success = Number(run.last_success_epoch) * 1000;
  const days = Math.floor((now - success) / 86400000);
  if (!Number.isFinite(days) || days >= maxAgeDays) return `The last successful USB backup is ${Number.isFinite(days) ? `${days} days` : 'of unknown age'} old: attach the enrolled USB drive.`;
  // The archive was copied; only the saved images were not (scripts/backup-usb.sh records that apart from a failed copy).
  if (run.images_problem) return `The last USB backup copied the archive but not the saved images: ${run.images_problem}. The drive then holds no saved images or an earlier copy, and a lost-host restore from it builds the images it lacks.`;
  return null;
}
