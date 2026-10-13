/**
 * IPP (Internet Printing Protocol) Type Definitions
 * Based on RFC 2911 and npm:ipp library
 *
 * The job and printer state constants and their mappings live in
 * ipp-validate.ts (plain `as const` objects, so that the node tests can
 * load them) with the checks of IPP replies; they are re-exported here.
 */

export {
  IPPJobState,
  IPPPrinterState,
  mapIPPStateToStatus,
  isTerminalState,
  mapPrinterStateToStatus,
} from './ipp-validate.ts';
export type { PrintJobStatus, PrinterStatus } from './ipp-validate.ts';

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
  statusCode?: string | number;
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

export interface IPPPrinterAttributes {
  "printer-state": number;
  "printer-state-reasons": string[];
  "printer-state-message"?: string;
  "printer-is-accepting-jobs"?: boolean;
  "queued-job-count"?: number;
  "printer-uri-supported"?: string[];
  "printer-up-time"?: number;
}
