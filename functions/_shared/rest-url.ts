// Where PostgREST is reached. No environment reads here: callers pass the values, so a function that imports this file
// needs only the names it reads itself (tests/worker-env.test.mjs).

/** A direct service address from the environment (no trailing slash), or '' when it is not set. */
export const withoutSlash = (value: string | undefined): string => (value ? value.replace(/\/+$/, '') : '');

/**
 * The PostgREST base address for a caller that uses only REST (no Storage): the direct address (SUPABASE_REST_URL, e.g.
 * http://rest:3000) when it is set, else the gateway's /rest/v1 path. Only `apikey` and `Authorization` are sent to it,
 * as before; nothing the client sent (CF-Connecting-IP) is forwarded.
 */
export function restBaseUrl(gatewayUrl: string, directRestUrl: string | undefined): string {
  const direct = withoutSlash(directRestUrl);
  return direct !== '' ? direct : `${gatewayUrl.replace(/\/+$/, '')}/rest/v1`;
}
