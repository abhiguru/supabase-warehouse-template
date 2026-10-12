// The rules for a central issuer's key set (JWKS), in plain JavaScript that
// imports nothing. This text exists twice, byte for byte:
//   functions/central-exchange/key-set.mjs  for the edge function (the
//                                           container mounts functions/ only)
//   scripts/central-key-set.mjs             for setup (--central-jwks-file;
//                                           scripts/ runs without functions/)
// tests/configure.test.mjs fails when the two differ; change both together.

export const KEY_SET_MAX_BYTES = 64 * 1024;

// The public P-256 signature keys of a parsed key set, reduced to the members
// verification needs. Keys of another kind or use, without a key id, or
// published with their private part are left out. Throws an Error whose
// message names the fault when the document is not a key set, holds no usable
// key, or names one key id twice (which key signs would then be ambiguous).
export function usableKeys(document) {
  const listed = document && typeof document === 'object' ? document.keys : undefined;
  if (!Array.isArray(listed)) throw new Error('key set malformed');
  const keys = [];
  for (const jwk of listed) {
    if (!jwk || typeof jwk !== 'object') continue;
    if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' || typeof jwk.x !== 'string' || typeof jwk.y !== 'string') continue;
    if (typeof jwk.kid !== 'string' || !jwk.kid || 'd' in jwk) continue;
    if (jwk.use !== undefined && jwk.use !== 'sig') continue;
    if (jwk.alg !== undefined && jwk.alg !== 'ES256') continue;
    if (jwk.key_ops !== undefined && !(Array.isArray(jwk.key_ops) && jwk.key_ops.includes('verify'))) continue;
    keys.push({ kty: 'EC', crv: 'P-256', x: jwk.x, y: jwk.y, kid: jwk.kid, alg: 'ES256', use: 'sig' });
  }
  if (!keys.length) throw new Error('key set holds no P-256 signature key');
  if (new Set(keys.map(key => key.kid)).size !== keys.length) throw new Error('key set names a key id twice');
  return keys;
}

// True when any key of the set carries private key material (a `d` member,
// or the private members of an RSA or symmetric key).
export function holdsPrivateKey(document) {
  const listed = document && typeof document === 'object' && Array.isArray(document.keys) ? document.keys : [];
  return listed.some(jwk => jwk && typeof jwk === 'object'
    && ['d', 'p', 'q', 'dp', 'dq', 'qi', 'oth', 'k'].some(member => member in jwk));
}
