/**
 * IPP (Internet Printing Protocol) Client Wrapper
 * Provides typed interface for CUPS operations
 */

import type {
  IPPResponse,
  IPPGetJobAttributesMessage,
} from "./ipp-types.ts";
import { cupsQueueUrl } from "./print-config.ts";

// The one place the ipp library is loaded (the printing code, print-transport.ts included, goes through it).
export async function ippPrinter(url: string): Promise<{ execute: (operation: string, message: unknown, callback: (err: Error | null, res: any) => void) => void }> {
  const ipp = await import("npm:ipp@2.0.1");
  return ipp.Printer(url);
}

/**
 * The whole Get-Job-Attributes reply from CUPS, for jobObservation
 * (ipp-validate.ts) to read: a job CUPS no longer lists answers
 * client-error-not-found, which is not the same as a reply without a state.
 *
 * The job is asked for on its own queue (PRINTER_NAME, the queue the job was
 * submitted to): CUPS accepts printer-uri together with job-id there. The old
 * default (printers/default) named a queue that does not exist, so every job
 * ended 'unknown' even when it printed.
 */
export async function getCUPSJobReply(cupsJobId: number): Promise<IPPResponse> {
  const url = cupsQueueUrl(name => Deno.env.get(name));
  if (url === null) throw new Error('PRINTER_NAME is not a valid CUPS queue name');
  const printer = await ippPrinter(url);

  const msg: IPPGetJobAttributesMessage = {
    "operation-attributes-tag": {
      "requesting-user-name": "background-status-monitor",
      "job-id": cupsJobId,
    },
  };

  return await new Promise((resolve, reject) => {
    printer.execute("Get-Job-Attributes", msg, (err: Error | null, res: IPPResponse) => {
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
