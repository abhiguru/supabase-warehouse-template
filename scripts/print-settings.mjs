import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { replaceEnvLines } from './keys.mjs';

// The print settings of compose.env (docs/PRINTING.md):
//   PRINT_TRANSPORT    bridge on a WSL2 host (Docker Engine in the distro, printer on Windows), cups on any other Linux host
//   PRINTER_NAME       LQ1310_RAW (the CUPS queue, or the name of the Windows printer)
//   PRINTBRIDGE_TOKEN  32 random bytes in hex: the shared secret between the functions and the Windows bridge
// The WSL check: the kernel release names Microsoft (the check scripts/backup.sh uses), or the distro sets WSL_DISTRO_NAME / WSL_INTEROP,
// or the WSLInterop binfmt entry exists (a custom kernel may not say Microsoft). WAREHOUSE_OSRELEASE_FILE is the test hook: when it is
// set only that file decides, so a test never depends on the machine it runs on.
export function isWsl(osreleaseFile = process.env.WAREHOUSE_OSRELEASE_FILE || '') {
  const kernelSays = file => {
    try {
      return /microsoft/i.test(readFileSync(file, 'utf8'));
    } catch {
      return false;
    }
  };
  if (osreleaseFile) return kernelSays(osreleaseFile);
  return kernelSays('/proc/sys/kernel/osrelease')
    || Boolean(process.env.WSL_DISTRO_NAME || process.env.WSL_INTEROP)
    || existsSync('/proc/sys/fs/binfmt_misc/WSLInterop');
}

// What a fresh state gets.
export function printValues(wsl = isWsl()) {
  return { PRINT_TRANSPORT: wsl ? 'bridge' : 'cups', PRINTER_NAME: 'LQ1310_RAW', PRINTBRIDGE_TOKEN: randomBytes(32).toString('hex') };
}

// compose.env text with every missing (absent or empty) print value added; a value that exists is never replaced.
// An existing state keeps printing off (capabilities.printing is untouched) but gets the values the operator steps need.
export function addMissingPrintValues(text, wsl = isWsl()) {
  const fresh = printValues(wsl);
  let result = text;
  const added = [];
  for (const [name, value] of Object.entries(fresh)) {
    const line = result.match(new RegExp(`^${name}=(.*)$`, 'm'));
    if (line && line[1] !== '') continue;
    if (line) result = replaceEnvLines(result, { [name]: value });
    else result += `${result === '' || result.endsWith('\n') ? '' : '\n'}${name}=${value}\n`;
    added.push(name);
  }
  return { text: result, added };
}
