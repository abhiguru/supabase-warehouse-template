// Headers every response of the edge functions carries. CORS is not here: the gateway (docker/nginx/api-locations.conf, the /functions/v1 route)
// answers the browser preflight itself and adds the allowed origin to every response, so the functions set no Access-Control-* header.
export const securityHeaders = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'X-XSS-Protection': '1; mode=block',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
};
