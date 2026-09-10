/**
 * Authentication and Authorization Helpers
 *
 * Security Features:
 * - JWT token validation (custom OTP-based auth system)
 * - Role-based access control (admin/supervisor only for protected operations)
 * - User profile retrieval
 *
 * Note: This system uses custom JWT generation via verify_otp_or_register(),
 * NOT GoTrue/Supabase Auth. JWT validation is done by decoding the token
 * and verifying the user exists in user_profiles.
 */

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.39.3'

function decodeJWT(token: string): any {
  const parts = token.split('.')
  if (parts.length !== 3) {
    throw new Error('Invalid JWT format')
  }

  const payload = parts[1]
  const padded = payload + '==='.slice(0, (4 - (payload.length % 4)) % 4)
  const base64 = padded.replace(/-/g, '+').replace(/_/g, '/')
  const decoded = atob(base64)
  return JSON.parse(decoded)
}

export interface UserProfile {
  id: string
  auth_user_id: string
  name: string
  display_name: string
  email: string | null
  mobile: string
  role: 'admin' | 'supervisor' | 'customer'
  active: boolean
  phone_verified: boolean
}

export interface AuthError {
  status: number
  message: string
}

/**
 * Validate that user has access (admin or supervisor only)
 */
export async function validatePrintAccess(
  req: Request,
  supabase: SupabaseClient
): Promise<UserProfile> {
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) {
    throw {
      status: 401,
      message: 'Authentication required. Please include Authorization header with Bearer token.'
    } as AuthError
  }

  let tokenPayload: any
  try {
    const token = authHeader.replace(/^[Bb]earer\s+/, '').trim()
    tokenPayload = decodeJWT(token)
  } catch (e) {
    console.error('validatePrintAccess: Invalid JWT token format:', e.message)
    throw {
      status: 401,
      message: 'Invalid token format.'
    } as AuthError
  }

  const tokenRole = tokenPayload.role
  if (tokenRole === 'service_role') {
    console.log('validatePrintAccess: Service role token - full access granted')
    return {
      id: 'service_role',
      auth_user_id: 'service_role',
      name: 'Service Role',
      display_name: 'Service Role',
      email: null,
      mobile: '',
      role: 'admin',
      active: true,
      phone_verified: true,
    } as UserProfile
  }

  const userId = tokenPayload.sub
  if (!userId) {
    console.error('validatePrintAccess: Token missing user ID (sub claim)')
    throw {
      status: 401,
      message: 'Token missing user identification.'
    } as AuthError
  }

  if (tokenPayload.exp && tokenPayload.exp < Date.now() / 1000) {
    console.error('validatePrintAccess: Token expired')
    throw {
      status: 401,
      message: 'Token has expired. Please login again.'
    } as AuthError
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  if (!supabaseUrl || !serviceRoleKey) {
    console.error('validatePrintAccess: Missing SUPABASE_URL or SERVICE_ROLE_KEY')
    throw {
      status: 500,
      message: 'Server configuration error'
    } as AuthError
  }

  const restUrl = `${supabaseUrl}/rest/v1/user_profiles?auth_user_id=eq.${userId}`
  console.log(`validatePrintAccess: Fetching user profile for auth_user_id: ${userId}`)

  const response = await fetch(restUrl, {
    method: 'GET',
    headers: {
      'apikey': serviceRoleKey,
      'Authorization': `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json',
    }
  })

  if (!response.ok) {
    const errorBody = await response.text()
    console.error(`validatePrintAccess: REST API error: ${response.status} ${response.statusText}`)
    throw {
      status: 401,
      message: 'Failed to fetch user profile'
    } as AuthError
  }

  const results = await response.json() as any[]
  const userProfile = Array.isArray(results) && results.length > 0 ? results[0] : null

  if (!userProfile) {
    console.error('validatePrintAccess: User profile not found for auth_user_id:', userId)
    throw {
      status: 401,
      message: 'User profile not found. Please contact administrator.'
    } as AuthError
  }

  const allowedRoles = ['admin', 'supervisor']
  if (!allowedRoles.includes(userProfile.role)) {
    console.warn(`validatePrintAccess: User ${userProfile.name} (role: ${userProfile.role}) attempted unauthorized access`)
    throw {
      status: 403,
      message: `Access denied. This operation requires admin or supervisor role. Your role: ${userProfile.role}`
    } as AuthError
  }

  if (!userProfile.active) {
    throw {
      status: 403,
      message: 'Access denied. Your account is inactive.'
    } as AuthError
  }

  console.log(`validatePrintAccess: User ${userProfile.name} (${userProfile.role}) authorized`)
  return userProfile as UserProfile
}

/**
 * Create standardized error response
 */
export function createAuthErrorResponse(
  error: AuthError | any,
  corsHeaders: Record<string, string>
): Response {
  const status = error.status || 500
  const message = error.message || 'Internal server error'

  return new Response(
    JSON.stringify({
      success: false,
      error: message,
      timestamp: new Date().toISOString()
    }, null, 2),
    {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: status
    }
  )
}
