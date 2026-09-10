import { serve } from 'https://deno.land/std@0.192.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { corsHeaders, handleCors } from '../_shared/cors.ts';
import { publicBaseUrl } from '../_shared/public-url.ts';

serve(async (req: Request) => {
  const cors = handleCors(req);
  if (cors) return cors;
  if (req.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: corsHeaders });
  try {
    const baseUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    const environment = Deno.env.get('APP_ENV') || 'development';
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    if (!anonKey) throw new Error('Missing anon key');
    const client = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: config, error } = await client.from('api_configurations')
      .select('app_version,maintenance_mode').eq('environment', environment).eq('is_active', true).single();
    if (error || !config) throw new Error('Configuration not seeded');
    const flags = await client.from('feature_flags').select('name,enabled');
    if (flags.error) throw new Error('Features unavailable');
    return new Response(JSON.stringify({ success: true, data: {
      supabaseUrl: baseUrl, anonKey, environment, version: config.app_version,
      maintenanceMode: config.maintenance_mode,
      urls: { publicConfig: `${baseUrl}/functions/v1/get-public-config`, fullConfig: `${baseUrl}/functions/v1/get-config` },
      featureFlags: Object.fromEntries((flags.data || []).map(flag => [flag.name, flag.enabled])),
    }, timestamp: new Date().toISOString() }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  } catch {
    return new Response(JSON.stringify({ success: false, error: 'Backend configuration unavailable; finish migrations and seed first' }), {
      status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  }
});
