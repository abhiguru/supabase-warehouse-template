// A decision the operator recorded on purpose: config/<name> is a regular file (not a link) owned by the user running the check,
// readable and writable by that user alone (mode 0600), and its text is exactly the sentence the documentation gives for it.
// Anything else (absent, a link, another owner, looser permissions, other text) is not a decision, so the alert it would silence stays on.
import { closeSync, constants, fstatSync, lstatSync, openSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export const OFFHOST_DECLINED_NAME = 'offhost-copy-declined';
export const OFFHOST_DECLINED_SENTENCE = 'We have decided not to keep a copy of the backups outside this host.';
export const HEARTBEAT_DECLINED_NAME = 'heartbeat-declined';
export const HEARTBEAT_DECLINED_SENTENCE = 'We have decided not to use an external heartbeat.';

// The longest file read: the sentence is under 100 characters; a larger file is not the sentence.
const MAX_BYTES = 512;

export function declinedMarker(state, name, sentence) {
  const path = resolve(state, 'config', name);
  let fd;
  try {
    if (!lstatSync(path).isFile()) return false;
    // Open without following a link, then judge the file that was opened (not the name, which may have been swapped since the lstat).
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | (constants.O_NONBLOCK ?? 0));
    const st = fstatSync(fd);
    if (!st.isFile() || st.size > MAX_BYTES) return false;
    if (typeof process.getuid === 'function' && st.uid !== process.getuid()) return false;
    if ((st.mode & 0o777) !== 0o600) return false;
    return readFileSync(fd, 'utf8').trim() === sentence;
  } catch { return false; } finally { if (fd !== undefined) try { closeSync(fd); } catch { /* nothing to close */ } }
}
