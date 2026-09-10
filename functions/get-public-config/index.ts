// Edge Function: get-public-config
// Provides PUBLIC configuration (anon key) without authentication
// Solves the "chicken and egg" problem where expired keys can't fetch new keys

import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Max-Age': '86400',
};

const getEnvironmentConfig = (req: Request): string => {
  const appDomain = Deno.env.get('APP_DOMAIN') || '';
  const xForwardedHost = req.headers.get('x-forwarded-host');
  const host = req.headers.get('host');
  const hostname = xForwardedHost || host || '';

  if (appDomain && hostname.includes(appDomain)) return 'production';
  if (hostname.includes('staging')) return 'staging';
  return 'development';
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? 'http://kong:8000';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

    const supabaseClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { autoRefreshToken: false, persistSession: false }
    });

    const environment = getEnvironmentConfig(req);
    const appDomain = Deno.env.get('APP_DOMAIN') || 'localhost';

    const { data: apiConfig } = await supabaseClient
      .from('api_configurations')
      .select('app_version, maintenance_mode')
      .eq('is_active', true)
      .eq('environment', environment)
      .single();

    const { data: flagsData } = await supabaseClient
      .from('feature_flags')
      .select('name, enabled');

    const featureFlags: Record<string, boolean> = {};
    if (flagsData) {
      for (const flag of flagsData) {
        featureFlags[flag.name] = flag.enabled;
      }
    }

    const baseUrl = environment === 'production'
      ? `https://${appDomain}`
      : environment === 'staging'
      ? `https://staging.${appDomain}`
      : 'http://localhost:8000';

    return new Response(
      JSON.stringify({
        success: true,
        data: {
          supabaseUrl: baseUrl,
          anonKey: supabaseAnonKey,
          environment,
          version: apiConfig?.app_version || '1.0.0',
          maintenanceMode: apiConfig?.maintenance_mode || false,
          urls: {
            publicConfig: `${baseUrl}/functions/v1/get-public-config`,
            fullConfig: `${baseUrl}/functions/v1/get-config`,
          },
          featureFlags,
        },
        timestamp: new Date().toISOString(),
      }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
          'Cache-Control': 'public, max-age=3600, stale-while-revalidate=86400',
        }
      }
    );

  } catch (error) {
    console.error('Error in get-public-config function:', error);
    const fallbackUrl = 'http://localhost:8000';
    return new Response(
      JSON.stringify({
        success: true,
        data: {
          supabaseUrl: fallbackUrl,
          anonKey: Deno.env.get('SUPABASE_ANON_KEY') ?? '',
          environment: 'development',
          version: '1.0.0',
          maintenanceMode: false,
          urls: {
            publicConfig: `${fallbackUrl}/functions/v1/get-public-config`,
            fullConfig: `${fallbackUrl}/functions/v1/get-config`,
          },
          featureFlags: {},
        },
        timestamp: new Date().toISOString(),
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=300' }
      }
    );
  }
});
