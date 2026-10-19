/**
 * Print Job Status Monitor
 * Background task that polls CUPS and records how a print job ended.
 *
 * The rule (print-monitor-rule.ts): only a final state CUPS reports finishes a
 * job (completed, cancelled, failed); a job CUPS no longer lists, or one still
 * running when the 35 s budget is spent, is recorded as 'unknown' with a note
 * and no completed_at. The submission (bounded by SUBMIT_TIMEOUT_MS) and the
 * whole run fit the router's 60 s worker lifetime.
 */

import { restClient } from './supabase-rest.ts';
import { getCUPSJobReply } from "./ipp-client.ts";
import { jobObservation } from "./ipp-validate.ts";
import type { PrintJobStatus } from "./ipp-validate.ts";
import { MONITOR_LIMITS, observeJob, runMonitor } from "./print-monitor-rule.ts";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Update print job status in database
 */
async function updateDatabaseStatus(
  printJobId: string,
  step: { status: PrintJobStatus; completedAt: boolean; note?: string },
  supabaseUrl: string,
  supabaseKey: string,
): Promise<void> {
  const supabase = restClient(supabaseUrl, supabaseKey);

  const updateData: {
    status: PrintJobStatus;
    updated_at: string;
    completed_at?: string;
    error_message?: string;
  } = {
    status: step.status,
    updated_at: new Date().toISOString(),
  };

  // Only a final state CUPS confirmed has a completion time.
  if (step.completedAt) {
    updateData.completed_at = new Date().toISOString();
  }

  if (step.note) {
    updateData.error_message = step.note;
  }

  const { error } = await supabase
    .from("print_jobs")
    .update(updateData)
    .eq("id", printJobId);

  if (error) {
    console.error(
      `[Status Monitor] Database update failed for job ${printJobId}:`,
      error
    );
    throw error;
  }

  console.log(
    `[Status Monitor] Updated job ${printJobId} to status: ${step.status}`
  );
}

/**
 * Main background task: Monitor print job status until CUPS confirms an end or
 * the budget is spent.
 *
 * This function is designed to be called with EdgeRuntime.waitUntil()
 * and will run in the background without blocking the HTTP response.
 *
 * @param printJobId - UUID of the print_jobs database record
 * @param cupsJobId - CUPS job ID (integer)
 * @param supabaseUrl - Supabase API URL
 * @param supabaseKey - Supabase service role key (not anon key!)
 */
export async function monitorPrintJobStatus(
  printJobId: string,
  cupsJobId: number,
  supabaseUrl: string,
  supabaseKey: string
): Promise<void> {
  console.log(
    `[Status Monitor] Starting background monitoring for print job ${printJobId} (CUPS job ${cupsJobId})`
  );

  await runMonitor({
    now: () => Date.now(),
    sleep,
    observe: () => observeJob(async () => jobObservation(await getCUPSJobReply(cupsJobId)), sleep, MONITOR_LIMITS),
    update: async (step) => {
      if (step.status === 'unknown') {
        console.warn(`[Status Monitor] Job ${cupsJobId}: ${step.note}`);
      }
      await updateDatabaseStatus(printJobId, step, supabaseUrl, supabaseKey);
    },
  }, MONITOR_LIMITS);
}
