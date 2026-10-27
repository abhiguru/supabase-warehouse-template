// What get-public-config tells the app about this backend, read from two files setup.sh writes into the state's public directory
// (scripts/release-info.mjs): release.json (which release is running) and app-compat.json (the oldest app build it answers).
// The router (functions/main/index.ts) reads the files and passes their text.

export type BackendRelease = { backendRelease: string | null; schemaHead: string | null };

// Raised for a missing or malformed app-compat.json, so the caller can say what to do instead of the generic "finish migrations" answer.
export class AppCompatError extends Error {}

const NAME = /^[A-Za-z0-9_.+-]{1,100}$/;

// An absent or unreadable release.json is not an error: the app shows "unknown", the function still answers.
export function parseRelease(text: string | undefined): BackendRelease {
  try {
    const document = JSON.parse(text ?? '');
    const pick = (value: unknown) => (typeof value === 'string' && NAME.test(value) ? value : null);
    return { backendRelease: pick(document?.backendRelease), schemaHead: pick(document?.schemaHead) };
  } catch {
    return { backendRelease: null, schemaHead: null };
  }
}

// The minimum comes from the release (app-compat.json), never from the instance manifest. A missing or malformed file is an
// error: the function then answers 503 rather than tell phones a wrong minimum; setup.sh writes the file on every run.
export function parseMinimumClientVersion(text: string | undefined): string {
  let version: unknown;
  try { version = JSON.parse(text ?? '')?.minimumClientVersion; } catch { /* reported below */ }
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+$/.test(version)) {
    throw new AppCompatError('app-compat.json missing or invalid; run setup.sh again');
  }
  return version;
}
