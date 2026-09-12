import { verifyRequest } from './jwt.ts';

export interface UserProfile {
  id: string;
  auth_user_id: string;
  name: string;
  display_name: string;
  mobile: string;
  role: 'admin' | 'supervisor' | 'customer' | 'user';
  active: boolean;
}
export interface AuthError { status: number; message: string }

export async function validateUserAccess(req: Request): Promise<UserProfile> {
  const payload = await verifyRequest(req);
  if (payload.role === 'service_role') {
    return { id: 'service_role', auth_user_id: 'service_role', name: 'Service', display_name: 'Service', mobile: '', role: 'admin', active: true };
  }
  if (payload.role !== 'authenticated' || typeof payload.sub !== 'string' ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(payload.sub)) {
    throw { status: 401, message: 'User access token required' };
  }
  const url = Deno.env.get('SUPABASE_URL');
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw { status: 500, message: 'Server configuration missing' };
  const response = await fetch(`${url}/rest/v1/user_profiles?auth_user_id=eq.${encodeURIComponent(payload.sub)}&select=id,auth_user_id,name,display_name,mobile,role,active`, {
    // Preserve the caller JWT so PostgREST's session hook checks revocation too.
    headers: { apikey: key, Authorization: req.headers.get('Authorization')! },
  });
  if (response.status === 401 || response.status === 403) throw { status: 403, message: 'Session expired or revoked' };
  if (!response.ok) throw { status: 503, message: 'Profile lookup unavailable' };
  const profiles = await response.json();
  if (!Array.isArray(profiles) || profiles.length !== 1 || !profiles[0].active) {
    throw { status: 403, message: 'Profile missing or inactive' };
  }
  return profiles[0];
}

// The optional second argument preserves compatibility with existing callers.
export async function validatePrintAccess(req: Request, _supabase?: unknown): Promise<UserProfile> {
  const profile = await validateUserAccess(req);
  if (!['admin', 'supervisor'].includes(profile.role)) {
    throw { status: 403, message: 'Admin or supervisor access required' };
  }
  return profile;
}

export function createAuthErrorResponse(error: unknown, corsHeaders: Record<string, string>): Response {
  const status = typeof error === 'object' && error !== null && 'status' in error ? Number(error.status) : 500;
  const safeStatus = [400, 401, 403, 404, 405, 503].includes(status) ? status : 500;
  const message = safeStatus < 500 && typeof error === 'object' && error !== null && 'message' in error ? String(error.message) : 'Server unavailable';
  return new Response(JSON.stringify({ success: false, error: message }), {
    status: safeStatus, headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}
