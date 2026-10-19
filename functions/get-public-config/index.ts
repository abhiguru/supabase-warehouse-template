import { restClient } from '../_shared/supabase-rest.ts';
import { corsHeaders, handleCors } from '../_shared/cors.ts';
import { publicBaseUrl } from '../_shared/public-url.ts';
import { advertisedCentralLogin } from '../_shared/https-address.ts';

type InstanceManifest = {
  schemaVersion: number;
  instanceId: string;
  displayName: string;
  companyName: string;
  canonicalOrigin: string;
  capabilities: Record<string, boolean>;
  supportedApiVersions: string[];
  minimumClientVersion: string;
};

async function readInstanceManifest(origin: string): Promise<InstanceManifest> {
  const value = Deno.env.get('INSTANCE_MANIFEST_JSON');
  if (!value) throw new Error('Instance manifest missing');
  const manifest = JSON.parse(value) as InstanceManifest;
  if (manifest.schemaVersion !== 1 ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(manifest.instanceId) ||
      !manifest.displayName?.trim() || !manifest.companyName?.trim() ||
      manifest.canonicalOrigin !== origin ||
      !Array.isArray(manifest.supportedApiVersions) || !manifest.supportedApiVersions.includes('1') ||
      !/^\d+\.\d+\.\d+$/.test(manifest.minimumClientVersion) ||
      !manifest.capabilities || typeof manifest.capabilities !== 'object' ||
      Object.values(manifest.capabilities).some(value => typeof value !== 'boolean')) {
    throw new Error('Invalid instance manifest');
  }
  return manifest;
}

Deno.serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;
  if (req.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: corsHeaders });
  try {
    const baseUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    const instance = await readInstanceManifest(baseUrl);
    const environment = Deno.env.get('APP_ENV') || 'development';
    // Central sign-in is offered only where functions/central-exchange could accept a token.
    // localCode: this facility also asks for its own SMS code at every sign-in (CENTRAL_LOCAL_CODE=on).
    const centralLogin = advertisedCentralLogin({
      authMode: Deno.env.get('AUTH_MODE'), appEnv: environment, issuer: Deno.env.get('CENTRAL_ISSUER'),
      jwksUrl: Deno.env.get('CENTRAL_JWKS_URL'), jwksFile: Deno.env.get('CENTRAL_JWKS_FILE'),
      localCode: Deno.env.get('CENTRAL_LOCAL_CODE'),
    });
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    if (!anonKey) throw new Error('Missing anon key');
    const client = restClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: config, error } = await client.from('api_configurations')
      .select('app_version,maintenance_mode').eq('environment', environment).eq('is_active', true).single();
    if (error || !config) throw new Error('Configuration not seeded');
    const flags = await client.from('feature_flags').select('name,enabled');
    if (flags.error) throw new Error('Features unavailable');
    return new Response(JSON.stringify({ success: true, data: {
      supabaseUrl: baseUrl, anonKey, environment, version: config.app_version,
      instanceId: instance.instanceId, displayName: instance.displayName,
      companyName: instance.companyName, canonicalOrigin: instance.canonicalOrigin,
      capabilities: instance.capabilities, supportedApiVersions: instance.supportedApiVersions,
      minimumClientVersion: instance.minimumClientVersion,
      maintenanceMode: config.maintenance_mode,
      centralLogin,
      urls: { publicConfig: `${baseUrl}/functions/v1/get-public-config`, fullConfig: `${baseUrl}/functions/v1/get-config` },
      featureFlags: Object.fromEntries((flags.data || []).map(flag => [flag.name, flag.enabled])),
    }, timestamp: new Date().toISOString() }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  } catch (error) {
    console.error('Public configuration failed:', error instanceof Error ? error.message : 'unknown error');
    return new Response(JSON.stringify({ success: false, error: 'Backend configuration unavailable; finish migrations and seed first' }), {
      status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  }
});
