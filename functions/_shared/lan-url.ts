// The LAN fallback address that get-config offers to a signed-in phone as urls.lan (docs/API_CONTRACT.md). Present only while the
// operator has the fallback on (LAN_ENABLED=true, written by scripts/lan.sh on) and only for a private IPv4 address and a valid
// port, so a hand-edited or damaged value is left out instead of being offered to every phone. The address is plain http by owner
// decision (2026-10-26): the app uses it only after the public address fails. get-public-config never reads it: that answer is
// readable by anyone on the internet, and the facility's LAN address is for its own signed-in users.
export type LanEnv = { enabled?: string; address?: string; port?: string };

const OCTET = '(0|[1-9][0-9]{0,2})';
const ADDRESS = new RegExp(`^${OCTET}\\.${OCTET}\\.${OCTET}\\.${OCTET}$`);

export function lanOrigin(env: LanEnv): string | null {
  if (env.enabled !== 'true') return null;
  const match = ADDRESS.exec(env.address ?? '');
  if (!match) return null;
  const [a, b, c, d] = match.slice(1).map(Number);
  if ([a, b, c, d].some(part => part > 255)) return null;
  const isPrivate = a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
  if (!isPrivate) return null;
  const text = env.port || '8080';
  if (!/^[0-9]{4,5}$/.test(text) || Number(text) < 1024 || Number(text) > 65535) return null;
  return `http://${a}.${b}.${c}.${d}:${Number(text)}`;
}
