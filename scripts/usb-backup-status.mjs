// Doctor warning for the USB backup drive (scripts/backup-usb.sh). Returns null when
// USB backup is not set up for this state or the last copy is recent and successful.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const fields = text => Object.fromEntries(text.split('\n').filter(line => line.includes('=')).map(line => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
const read = path => { try { return readFileSync(path, 'utf8'); } catch { return null; } };

export function usbBackupWarning(state, {
  now = Date.now(),
  maxAgeDays = Number(process.env.WAREHOUSE_USB_BACKUP_MAX_AGE_DAYS || 7),
  etc = process.env.WAREHOUSE_USB_BACKUP_ETC || '/etc',
} = {}) {
  const conf = read(resolve(etc, 'warehouse-usb-backup.conf'));
  const last = read(resolve(state, 'config/usb-backup.last'));
  if (!last && (!conf || fields(conf).STATE !== resolve(state))) return null;
  if (!last) return 'USB backup is set up but no copy has been made yet: attach the enrolled USB drive.';
  const run = fields(last);
  if (run.result !== 'ok') return `The last USB backup failed at ${run.finished_utc || 'an unknown time'}: ${run.message || 'no detail'}. Run bash scripts/backup-usb.sh status.`;
  const success = Number(run.last_success_epoch) * 1000;
  const days = Math.floor((now - success) / 86400000);
  if (!Number.isFinite(days) || days >= maxAgeDays) return `The last successful USB backup is ${Number.isFinite(days) ? `${days} days` : 'of unknown age'} old: attach the enrolled USB drive.`;
  return null;
}
