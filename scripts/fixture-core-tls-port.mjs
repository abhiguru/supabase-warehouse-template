export function coreFixtureTlsPort(value) {
  if (value === undefined) return 18443;
  if (value === '18443' || value === 18443) return 18443;
  if (value === '19543' || value === 19543) return 19543;
  throw new Error('Only declared fictional core TLS ports are supported');
}
