import { jwtVerify } from 'jose';

// Verify the signature BEFORE trusting sub, role, or expiry. Decoding alone is not auth.
export async function verifyToken(token: string, secret: string) {
  if (!secret || secret.length < 32) throw new Error('JWT secret is not configured');
  const { payload } = await jwtVerify(token, new TextEncoder().encode(secret), {
    algorithms: ['HS256'],
    issuer: 'supabase',
    requiredClaims: ['exp', 'role'],
  });
  if (!['anon', 'authenticated', 'service_role'].includes(String(payload.role)) || payload.type === 'refresh') {
    throw new Error('An access token is required');
  }
  return payload;
}

export async function verifyRequest(req: Request) {
  const match = /^Bearer\s+(\S+)$/i.exec(req.headers.get('authorization') ?? '');
  if (!match) throw { status: 401, message: 'Bearer access token required' };
  try {
    return await verifyToken(match[1], Deno.env.get('JWT_SECRET') ?? '');
  } catch {
    throw { status: 401, message: 'Invalid or expired access token' };
  }
}
