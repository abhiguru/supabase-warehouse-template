// A printer name becomes part of the CUPS URL path, so it is limited to the
// characters a CUPS queue name can have (the same rule print-via-ipp applies).
export function validPrinterName(value: unknown): value is string {
  return typeof value === 'string' && /^[a-zA-Z0-9_-]{1,127}$/.test(value);
}

// What the caller is told when a printer status check fails. Only the two
// causes an administrator can act on are named; any other error text (host
// names, socket and parser messages) stays in the server log.
export function printerStatusFailure(error: unknown): { status: number; message: string } {
  const text = error instanceof Error ? error.message : String((error as { message?: unknown })?.message ?? '');
  if (text.includes('ECONNREFUSED')) {
    return { status: 503, message: 'Cannot connect to printer. Check if CUPS service is running.' };
  }
  if (text.includes('not found')) {
    return { status: 404, message: 'Printer not found. Check printer name.' };
  }
  return { status: 500, message: 'Printer status unavailable' };
}
