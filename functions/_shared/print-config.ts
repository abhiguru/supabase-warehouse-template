// Where print jobs go, read from the environment of the print functions (functions/main/worker-env.ts).
// This module imports nothing so that the node tests can load it directly.
//
//   PRINT_TRANSPORT   cups (default) | bridge. cups: the CUPS container of the `printing` compose profile (Linux hosts).
//                     bridge: the Windows print bridge (scripts/windows/print-bridge.ps1), for a Windows host whose backend runs in WSL2.
//   PRINTER_NAME      the one queue name: the CUPS queue on cups, the Windows printer name on bridge. Default LQ1310_RAW.
//   PRINTBRIDGE_URL   bridge only: http://<windows host>:<port>, no path.
//   PRINTBRIDGE_TOKEN bridge only: the shared secret the bridge checks (X-Print-Token).

export type PrintTransportName = 'cups' | 'bridge';
export type EnvGet = (name: string) => string | undefined;

export const DEFAULT_PRINTER_NAME = 'LQ1310_RAW';
export const CUPS_SERVER_URL = 'http://cups:631';

const CUPS_QUEUE = /^[a-zA-Z0-9_-]{1,127}$/;
// A Windows printer name may hold spaces and a few punctuation marks (the usual "EPSON LQ-1310 ESC/P2" has a slash); it travels in a
// header, so printable ASCII only: no control characters, CR or LF.
const BRIDGE_PRINTER = /^[A-Za-z0-9][A-Za-z0-9 _.()#/-]{0,126}$/;

/** cups when unset or empty, bridge when asked for, null for any other value (a configuration error, never guessed). */
export function printTransportName(get: EnvGet): PrintTransportName | null {
  const value = (get('PRINT_TRANSPORT') ?? '').trim().toLowerCase();
  if (value === '' || value === 'cups') return 'cups';
  if (value === 'bridge') return 'bridge';
  return null;
}

/** The configured queue name, or null when it is not valid for the transport. */
export function printerName(get: EnvGet, transport: PrintTransportName = printTransportName(get) ?? 'cups'): string | null {
  const name = (get('PRINTER_NAME') ?? '').trim() || DEFAULT_PRINTER_NAME;
  return (transport === 'bridge' ? BRIDGE_PRINTER : CUPS_QUEUE).test(name) ? name : null;
}

/** The IPP address of the CUPS queue (also where a job is looked up: CUPS answers Get-Job-Attributes on the queue the job is in). */
export function cupsQueueUrl(get: EnvGet): string | null {
  const name = printerName(get, 'cups');
  return name === null ? null : `${CUPS_SERVER_URL}/printers/${name}`;
}

/** The bridge address without a trailing slash, or null when it is empty or not an http(s) address. */
export function bridgeBaseUrl(get: EnvGet): string | null {
  const raw = (get('PRINTBRIDGE_URL') ?? '').trim().replace(/\/+$/, '');
  try {
    const url = new URL(raw);
    return (url.protocol === 'http:' || url.protocol === 'https:') && url.pathname === '/' && !url.search && !url.hash ? raw : null;
  } catch {
    return null;
  }
}

/** A document name that is safe in an IPP job name and an HTTP header: printable ASCII, at most 100 characters. */
export function safeDocName(value: string): string {
  const cleaned = value.replace(/[^\x20-\x7E]/g, '?').trim().slice(0, 100);
  return cleaned || 'Print Job';
}

/** The IPP user name a CUPS job is submitted under, and cancelled under (CUPS lets only the job's owner cancel it: cupsd.conf, Cancel-Job). */
export const cupsJobUser = (jobType: string | null | undefined): string => `warehouse-${String(jobType ?? '').toLowerCase()}`;
