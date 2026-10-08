import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Node resolves module URLs through symlinks, but argv may retain /var or a
// symlinked checkout path. Compare physical paths before running a CLI entry.
export function isMain(moduleUrl) {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(moduleUrl));
  } catch {
    return false;
  }
}
