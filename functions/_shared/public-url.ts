export function publicBaseUrl(value: string | undefined): string {
  if (!value) throw new Error('SUPABASE_PUBLIC_URL is required');
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('SUPABASE_PUBLIC_URL must be an HTTP(S) origin without credentials');
  }
  return url.origin;
}
