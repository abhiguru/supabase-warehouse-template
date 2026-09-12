/**
 * Print Job Status Monitor
 * Background task that polls CUPS and updates database when jobs complete
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import { getCUPSJobState, cupsJobExists } from "./ipp-client.ts";
import { mapIPPStateToStatus, isTerminalState } from "./ipp-types.ts";
import type { PrintJobStatus } from "./ipp-types.ts";

/**
 * Configuration for status monitoring
 */
const MONITOR_CONFIG = {
  pollIntervalMs: 5000, // Check every 5 seconds (faster detection)
  maxAttempts: 12, // Poll for up to 60 seconds (12 * 5s = 60s)
  maxRetries: 3, // Retry failed CUPS queries up to 3 times
};

/**
 * Sleep utility
 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Check print job status with retries
 */
async function checkCUPSStatus(cupsJobId: number): Promise<{
  jobState: number | string | null;
  exists: boolean;
}> {
  let lastError: Error | null = null;

  for (let retry = 0; retry < MONITOR_CONFIG.maxRetries; retry++) {
    try {
      const jobState = await getCUPSJobState(cupsJobId);

      if (jobState === null) {
        // Job not found - check if it exists at all
        const exists = await cupsJobExists(cupsJobId);
        return { jobState: null, exists };
      }

      return { jobState, exists: true };
    } catch (error) {
      lastError = error as Error;
      console.warn(
        `[Status Monitor] CUPS query retry ${retry + 1}/${MONITOR_CONFIG.maxRetries} for job ${cupsJobId}:`,
        error
      );

      if (retry < MONITOR_CONFIG.maxRetries - 1) {
        await sleep(1000 * (retry + 1)); // Exponential backoff: 1s, 2s, 3s
      }
    }
  }

  // All retries failed
  throw lastError || new Error("Unknown CUPS query error");
}

/**
 * Update print job status in database
 */
async function updateDatabaseStatus(
  printJobId: string,
  newStatus: PrintJobStatus,
  supabaseUrl: string,
  supabaseKey: string,
  errorMessage?: string
): Promise<void> {
  const supabase = createClient(supabaseUrl, supabaseKey);

  const updateData: {
    status: PrintJobStatus;
    updated_at: string;
    completed_at?: string;
    error_message?: string;
  } = {
    status: newStatus,
    updated_at: new Date().toISOString(),
  };

  // Set completed_at for terminal states
  if (["completed", "cancelled", "failed"].includes(newStatus)) {
    updateData.completed_at = new Date().toISOString();
  }

  if (errorMessage) {
    updateData.error_message = errorMessage;
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
    `[Status Monitor] Updated job ${printJobId} to status: ${newStatus}`
  );
}

/**
 * Main background task: Monitor print job status until completion
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

  let attempts = 0;

  // Initial delay before first check (give job time to start)
  await sleep(5000); // 5 seconds

  while (attempts < MONITOR_CONFIG.maxAttempts) {
    attempts++;

    try {
      // Query CUPS for job status
      const { jobState, exists } = await checkCUPSStatus(cupsJobId);

      // Handle job not found in CUPS
      if (!exists) {
        console.log(
          `[Status Monitor] CUPS job ${cupsJobId} not found (attempt ${attempts}/${MONITOR_CONFIG.maxAttempts})`
        );

        // If we've been checking for >1 minute and job doesn't exist, assume completed
        if (attempts > 6) {
          // 6 * 10s = 60s
          console.log(
            `[Status Monitor] Job ${cupsJobId} not found after 1 minute - assuming completed`
          );
          await updateDatabaseStatus(
            printJobId,
            "completed",
            supabaseUrl,
            supabaseKey,
            "Job not found in CUPS history (assumed completed)"
          );
          return;
        }

        // Otherwise, keep checking
        await sleep(MONITOR_CONFIG.pollIntervalMs);
        continue;
      }

      // Job exists but no state returned
      if (jobState === null) {
        console.warn(
          `[Status Monitor] Job ${cupsJobId} exists but has no state (attempt ${attempts})`
        );
        await sleep(MONITOR_CONFIG.pollIntervalMs);
        continue;
      }

      // Map IPP state to our database status
      const newStatus = mapIPPStateToStatus(jobState);

      if (!newStatus) {
        console.warn(
          `[Status Monitor] Unknown IPP job state ${jobState} for job ${cupsJobId}`
        );
        await sleep(MONITOR_CONFIG.pollIntervalMs);
        continue;
      }

      // Check if job reached terminal state
      if (isTerminalState(jobState)) {
        console.log(
          `[Status Monitor] Job ${cupsJobId} reached terminal state: ${newStatus} (IPP state ${jobState})`
        );
        await updateDatabaseStatus(
          printJobId,
          newStatus,
          supabaseUrl,
          supabaseKey
        );
        return; // Done monitoring
      }

      // Job still in progress
      console.log(
        `[Status Monitor] Job ${cupsJobId} still in progress (state: ${jobState}, attempt ${attempts}/${MONITOR_CONFIG.maxAttempts})`
      );
      await sleep(MONITOR_CONFIG.pollIntervalMs);
    } catch (error) {
      console.error(
        `[Status Monitor] Error checking status for job ${printJobId} (attempt ${attempts}):`,
        error
      );

      // Don't fail the whole monitor on transient errors - keep trying
      await sleep(MONITOR_CONFIG.pollIntervalMs);
    }
  }

  // Timeout after max attempts - printer likely offline
  console.warn(
    `[Status Monitor] Timeout after ${MONITOR_CONFIG.maxAttempts} attempts (${
      (MONITOR_CONFIG.maxAttempts * MONITOR_CONFIG.pollIntervalMs) / 1000
    }s) for job ${printJobId}`
  );

  // Mark as FAILED - printer is offline or not responding
  await updateDatabaseStatus(
    printJobId,
    "failed",
    supabaseUrl,
    supabaseKey,
    `Printer offline or not responding - timeout after ${
      (MONITOR_CONFIG.maxAttempts * MONITOR_CONFIG.pollIntervalMs) / 1000
    } seconds`
  );
}
