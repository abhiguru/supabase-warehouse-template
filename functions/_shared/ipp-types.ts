/**
 * IPP (Internet Printing Protocol) Type Definitions
 * Based on RFC 2911 and npm:ipp library
 */

export enum IPPJobState {
  PENDING = 3,
  PENDING_HELD = 4,
  PROCESSING = 5,
  PROCESSING_STOPPED = 6,
  CANCELED = 7,
  ABORTED = 8,
  COMPLETED = 9,
}

export interface IPPJobAttributes {
  "job-state": number | string;
  "job-state-reasons": string[];
  "job-name"?: string;
  "job-id"?: number;
  "job-uri"?: string;
  "time-at-creation"?: number;
  "time-at-processing"?: number;
  "time-at-completed"?: number;
}

export interface IPPResponse {
  "job-attributes-tag"?: IPPJobAttributes;
  "operation-attributes-tag"?: {
    "status-code": number;
    "status-message"?: string;
  };
}

export interface IPPGetJobAttributesMessage {
  "operation-attributes-tag": {
    "requesting-user-name": string;
    "job-id": number;
  };
}

export interface IPPCancelJobMessage {
  "operation-attributes-tag": {
    "requesting-user-name": string;
    "job-id": number;
  };
}

export type PrintJobStatus = "queued" | "printing" | "completed" | "cancelled" | "failed";

export function mapIPPStateToStatus(ippState: number | string): PrintJobStatus | null {
  if (typeof ippState === 'string') {
    const stateLower = ippState.toLowerCase();
    if (stateLower === 'pending' || stateLower === 'pending-held') return "queued";
    if (stateLower === 'processing' || stateLower === 'processing-stopped') return "printing";
    if (stateLower === 'completed') return "completed";
    if (stateLower === 'canceled' || stateLower === 'cancelled') return "cancelled";
    if (stateLower === 'aborted') return "failed";
    return null;
  }

  switch (ippState) {
    case IPPJobState.PENDING:
    case IPPJobState.PENDING_HELD:
      return "queued";
    case IPPJobState.PROCESSING:
    case IPPJobState.PROCESSING_STOPPED:
      return "printing";
    case IPPJobState.COMPLETED:
      return "completed";
    case IPPJobState.CANCELED:
      return "cancelled";
    case IPPJobState.ABORTED:
      return "failed";
    default:
      return null;
  }
}

export function isTerminalState(ippState: number | string): boolean {
  if (typeof ippState === 'string') {
    const stateLower = ippState.toLowerCase();
    return ['completed', 'canceled', 'cancelled', 'aborted'].includes(stateLower);
  }
  return [IPPJobState.COMPLETED, IPPJobState.CANCELED, IPPJobState.ABORTED].includes(ippState);
}

export enum IPPPrinterState {
  IDLE = 3,
  PROCESSING = 4,
  STOPPED = 5
}

export interface IPPPrinterAttributes {
  "printer-state": number;
  "printer-state-reasons": string[];
  "printer-state-message"?: string;
  "printer-is-accepting-jobs"?: boolean;
  "queued-job-count"?: number;
  "printer-uri-supported"?: string[];
  "printer-up-time"?: number;
}

export type PrinterStatus = "online" | "offline" | "error" | "busy";

export function mapPrinterStateToStatus(
  printerState: number,
  stateReasons: string[],
  isAcceptingJobs: boolean = true
): { status: PrinterStatus; message: string } {
  if (printerState === IPPPrinterState.STOPPED) {
    if (stateReasons.includes('media-needed')) return { status: 'error', message: 'Out of paper' };
    if (stateReasons.includes('media-jam')) return { status: 'error', message: 'Paper jam' };
    if (stateReasons.includes('door-open')) return { status: 'error', message: 'Printer door/cover is open' };
    if (stateReasons.includes('marker-supply-empty')) return { status: 'error', message: 'Out of ink/ribbon' };
    if (stateReasons.includes('marker-supply-low')) return { status: 'error', message: 'Low on ink/ribbon' };
    if (stateReasons.includes('offline')) return { status: 'offline', message: 'Printer is offline' };
    if (stateReasons.includes('paused')) return { status: 'offline', message: 'Printer is paused' };
    return { status: 'offline', message: 'Printer is stopped' };
  }

  if (printerState === IPPPrinterState.PROCESSING) {
    return { status: 'busy', message: 'Printer is currently printing' };
  }

  if (!isAcceptingJobs) {
    const reasonsArray = Array.isArray(stateReasons) ? stateReasons : [stateReasons];
    const disconnectReasons = reasonsArray.filter(reason =>
      reason && (
        reason.toLowerCase().includes('disconnect') ||
        reason.toLowerCase().includes('unplugged') ||
        reason.toLowerCase().includes('usb')
      )
    );
    if (disconnectReasons.length > 0) {
      return { status: 'offline', message: 'Printer is not connected (USB disconnected)' };
    }
    return { status: 'offline', message: 'Printer is not accepting jobs' };
  }

  return { status: 'online', message: 'Printer is ready' };
}
