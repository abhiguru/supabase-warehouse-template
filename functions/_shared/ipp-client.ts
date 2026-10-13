/**
 * IPP (Internet Printing Protocol) Client Wrapper
 * Provides typed interface for CUPS operations
 */

import type {
  IPPResponse,
  IPPGetJobAttributesMessage,
} from "./ipp-types.ts";

const CUPS_PRINTER_URL = Deno.env.get('CUPS_PRINTER_URL') || "http://cups:631/printers/default";

/**
 * The whole Get-Job-Attributes reply from CUPS, for jobObservation
 * (ipp-validate.ts) to read: a job CUPS no longer lists answers
 * client-error-not-found, which is not the same as a reply without a state.
 */
export async function getCUPSJobReply(cupsJobId: number): Promise<IPPResponse> {
  const ipp = await import("npm:ipp@2.0.1");
  const printer = ipp.Printer(CUPS_PRINTER_URL);

  const msg: IPPGetJobAttributesMessage = {
    "operation-attributes-tag": {
      "requesting-user-name": "background-status-monitor",
      "job-id": cupsJobId,
    },
  };

  return await new Promise((resolve, reject) => {
    printer.execute("Get-Job-Attributes", msg, (err: Error, res: IPPResponse) => {
      if (err) {
        reject(err);
      } else {
        resolve(res);
      }
    });
  });
}

export class CUPSError extends Error {
  constructor(message: string, public cupsJobId?: number) {
    super(message);
    this.name = "CUPSError";
  }
}
