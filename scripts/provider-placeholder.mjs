// What is not a real SMS provider value, in plain JavaScript that imports
// nothing. This text exists twice, byte for byte:
//   functions/operator-otp/provider-placeholder.mjs  for the edge function (the
//                                                    container mounts functions/ only)
//   scripts/provider-placeholder.mjs                 for setup and the doctor
//                                                    (scripts/ runs without functions/)
// tests/provider-placeholder.test.mjs fails when the two differ; change both together.
//
// Three kinds of value are never a provider credential:
//   - an empty one;
//   - template text: `your-`, `changeme` or `fake_` (.env.example and the docs);
//   - the fixture sentinel `isolated-` (the value CI and review fixtures install with).
// The edge function never calls the provider with any of them, whatever network the
// container has, so a fixture cannot send a real SMS by accident (incident
// TW-ENV-008). The installer and the doctor refuse template text everywhere. They accept
// the sentinel only for a reserved `.test` address (isFixtureAddress), which no real
// installation can have, so CI and fixtures can still install while a real facility
// that carries the sentinel is told that it has no SMS provider.

const TEMPLATE_TEXT = /^(your-|changeme|fake_)/i;
const FIXTURE_SENTINEL = /^isolated-/i;

export function isProviderPlaceholder(value, { allowFixtureSentinel = false } = {}) {
  const text = typeof value === 'string' ? value.trim() : '';
  if (!text || TEMPLATE_TEXT.test(text)) return true;
  return FIXTURE_SENTINEL.test(text) && !allowFixtureSentinel;
}

// True for an address under the reserved `.test` top-level domain (RFC 6761), the
// only host names CI and the fixtures use.
export function isFixtureAddress(address) {
  try {
    const host = new URL(address).hostname.toLowerCase();
    return host === 'test' || host.endsWith('.test');
  } catch { return false; }
}
