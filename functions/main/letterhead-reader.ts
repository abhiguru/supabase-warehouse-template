// The router reads the optional letterhead image (setup.sh --letterhead-file) from the read-only public directory, as it reads
// the central key file, and hands the four document PDF workers the finished data URI as LETTERHEAD_DATA_URI. A letterhead
// that is missing, unreadable, too large or not a JPEG/PNG is logged once and left out: a PDF never fails because of it.
import { LETTERHEAD_MAX_BYTES, letterheadDataUri } from '../_shared/letterhead.ts';

const NAME = /^letterhead\.(jpg|png)$/;

export interface LetterheadDeps {
  env: (name: string) => string | undefined;
  stat: (path: string) => Promise<{ isFile: boolean; size: number; mtimeMs: number }>;
  readFile: (path: string) => Promise<Uint8Array>;
  log: (line: string) => void;
}

/**
 * A reader that returns the data URI ('' for none). The file is read again only when its modification time or size
 * changes (a replaced image is picked up without recreating the container); a fault is logged once until it changes.
 */
export function letterheadReader(deps: LetterheadDeps): () => Promise<string> {
  let key = '';
  let uri = '';
  let lastFault = '';
  const fault = (message: string) => {
    if (message !== lastFault) deps.log(`letterhead: ${message}; PDFs are made without it`);
    lastFault = message;
    key = '';
    uri = '';
    return '';
  };
  return async () => {
    const file = deps.env('LETTERHEAD_FILE');
    const directory = deps.env('LETTERHEAD_DIR');
    if (!file) { lastFault = ''; key = ''; uri = ''; return ''; }
    if (!directory || !NAME.test(file)) return fault('LETTERHEAD_FILE must be letterhead.jpg or letterhead.png');
    const path = `${directory}/${file}`;
    try {
      const info = await deps.stat(path);
      if (!info.isFile) return fault(`${file} is not a regular file`);
      if (info.size > LETTERHEAD_MAX_BYTES) return fault(`${file} is larger than 2 MiB`);
      const now = `${file}:${info.mtimeMs}:${info.size}`;
      if (now === key) return uri;
      const built = letterheadDataUri(await deps.readFile(path));
      if (!built) return fault(`${file} is not a JPEG or PNG image`);
      key = now; uri = built; lastFault = '';
      return uri;
    } catch {
      return fault(`${file} could not be read`);
    }
  };
}
