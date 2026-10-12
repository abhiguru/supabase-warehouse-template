// True for an absolute https:// address without credentials. The central
// sign-in settings (issuer, key address) are used only when they pass this.
export function httpsAddress(value: string | undefined): boolean {
  if (!value) return false;
  try {
    const url = new URL(value);
    return value.startsWith('https://') && url.protocol === 'https:' && !!url.hostname && !url.username && !url.password;
  } catch { return false; }
}

// What get-public-config advertises as centralLogin: the issuer when
// functions/central-exchange would be able to accept a token here, else null.
// That needs an operator production instance, an https issuer, and the
// issuer's keys either from a file of the installation or from an https address.
export function advertisedCentralIssuer(settings: {
  authMode?: string; appEnv?: string; issuer?: string; jwksUrl?: string; jwksFile?: string;
}): string | null {
  if (settings.authMode !== 'operator' || settings.appEnv !== 'production') return null;
  if (!httpsAddress(settings.issuer)) return null;
  if (!settings.jwksFile && !httpsAddress(settings.jwksUrl)) return null;
  return settings.issuer!;
}
