/**
 * IPP (Internet Printing Protocol) Client Wrapper
 * Provides typed interface for CUPS operations
 */

import type {
  IPPResponse,
  IPPGetJobAttributesMessage,
  IPPJobAttributes,
} from "./ipp-types.ts";

const CUPS_PRINTER_URL = Deno.env.get('CUPS_PRINTER_URL') || "http://cups:631/printers/default";

/**
 * Get job attributes from CUPS
 */
export async function getCUPSJobAttributes(
  cupsJobId: number
): Promise<IPPJobAttributes | null> {
  try {
    const ipp = await import("npm:ipp");
    const printer = ipp.Printer(CUPS_PRINTER_URL);

    const msg: IPPGetJobAttributesMessage = {
      "operation-attributes-tag": {
        "requesting-user-name": "background-status-monitor",
        "job-id": cupsJobId,
      },
    };

    const result: IPPResponse = await new Promise((resolve, reject) => {
      printer.execute("Get-Job-Attributes", msg, (err: Error, res: IPPResponse) => {
        if (err) {
          reject(err);
        } else {
          resolve(res);
        }
      });
    });

    return result?.["job-attributes-tag"] || null;
  } catch (error) {
    console.error(`[IPP Client] Failed to get job attributes for CUPS job ${cupsJobId}:`, error);
    throw error;
  }
}

export async function getCUPSJobState(cupsJobId: number): Promise<number | string | null> {
  const attrs = await getCUPSJobAttributes(cupsJobId);
  return attrs?.["job-state"] ?? null;
}

export async function cupsJobExists(cupsJobId: number): Promise<boolean> {
  try {
    const attrs = await getCUPSJobAttributes(cupsJobId);
    return attrs !== null;
  } catch (error) {
    return false;
  }
}

export class CUPSError extends Error {
  constructor(message: string, public cupsJobId?: number) {
    super(message);
    this.name = "CUPSError";
  }
}
