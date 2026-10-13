// Amounts and the financial year of the pre-printed invoice (print-invoice-preprinted).
//
// PRINT2 (review 2026-10-13): the print computed each line's storage amount as
// duration * quantity * rate, a ONE_TIME receipt included, whose storage is
// charged once. get_invoice_range_for_print returns each line's storage_amount
// as the invoice rule computes it (migration 72); the print uses that number and
// never computes one. PRINT5: without a financial year the print took the
// calendar year, so from January to March it asked for the wrong year.
// This module imports nothing so that the node tests can load it directly.

// The storage amount of one invoice line as the database computed it. A line
// without it (a database before migration 72) stops the print.
export function lineStorageAmount(line: unknown): number {
  const value = (line as { storage_amount?: unknown } | null)?.storage_amount;
  const amount = typeof value === 'number' ? value : typeof value === 'string' && value.trim() !== '' ? Number(value) : NaN;
  if (!Number.isFinite(amount) || amount < 0) {
    throw new Error('An invoice line has no storage amount from the database; apply migration 72 before printing');
  }
  return amount;
}

// The storage amounts of several lines, added in paise so that the total is exact.
export function cumulativeStorageAmount(lines: unknown[]): number {
  return lines.reduce((paise: number, line) => paise + Math.round(lineStorageAmount(line) * 100), 0) / 100;
}

// India's financial year at a moment: the year in which the 1 April to 31 March
// year began, on the Asia/Kolkata calendar (UTC+05:30, no daylight saving). The
// same rule as warehouse_security.financial_year(warehouse_security.business_date(now())).
export function indiaFinancialYear(now: Date): number {
  const india = new Date(now.getTime() + 330 * 60 * 1000);
  const year = india.getUTCFullYear();
  return india.getUTCMonth() + 1 >= 4 ? year : year - 1;
}

// The financial year a print request asks for: missing means the current
// Indian one; otherwise an integer from 2000 to 9999 (as generate-invoice-pdf
// takes it); anything else is refused with 400.
export function resolveInvoiceFinYear(value: unknown, now: Date): number {
  if (value === undefined || value === null || value === '') return indiaFinancialYear(now);
  const year = typeof value === 'number' || typeof value === 'string' ? Number(value) : NaN;
  if (!Number.isInteger(year) || year < 2000 || year > 9999) {
    throw { status: 400, message: 'Invalid financial year' };
  }
  return year;
}
