// A decision the operator recorded on purpose: config/<name> is a regular file (not a link) owned by the user running the check,
// readable and writable by that user alone (mode 0600), and its text is exactly the sentence the documentation gives for it.
// Anything else (absent, a link, another owner, looser permissions, other text) is not a decision, so the alert it would silence stays on.
import { lstatSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export const OFFHOST_DECLINED_NAME = 'offhost-copy-declined';
export const OFFHOST_DECLINED_SENTENCE = 'We have decided not to keep a copy of the backups outside this host.';

export function declinedMarker(state, name, sentence) {
  const path = resolve(state, 'config', name);
  try {
    const st = lstatSync(path);
    if (!st.isFile() || st.isSymbolicLink()) return false;
    if (typeof process.getuid === 'function' && st.uid !== process.getuid()) return false;
    if ((st.mode & 0o777) !== 0o600) return false;
    return readFileSync(path, 'utf8').trim() === sentence;
  } catch { return false; }
}
