// Edge Function: get-config
// Provides dynamic API configuration to authenticated clients

import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
};

const getEnvironmentConfig = (req: Request): string => {
  const appDomain = Deno.env.get('APP_DOMAIN') || '';
  const xForwardedHost = req.headers.get('x-forwarded-host');
  const host = req.headers.get('host');
  const hostname = xForwardedHost || host || '';

  if (appDomain && hostname.includes(appDomain)) {
    return 'production';
  } else if (hostname.includes('staging')) {
    return 'staging';
  }
  return 'development';
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    const apiKey = req.headers.get('apikey');

    if (!authHeader && !apiKey) {
      return new Response(
        JSON.stringify({ success: false, error: 'Missing authorization header', timestamp: new Date().toISOString() }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? 'http://kong:8000';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

    const supabaseClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { autoRefreshToken: false, persistSession: false }
    });

    let userRole = 'anon';

    if (authHeader) {
      const token = authHeader.replace('Bearer ', '');
      try {
        const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
        if (authError || !user) {
          return new Response(
            JSON.stringify({ success: false, error: 'Invalid or expired authentication token', timestamp: new Date().toISOString() }),
            { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        const { data: profile } = await supabaseClient
          .from('user_profiles')
          .select('id, auth_user_id, name, role, active')
          .eq('auth_user_id', user.id)
          .single();

        if (!profile || !profile.active) {
          return new Response(
            JSON.stringify({ success: false, error: 'User profile not found or inactive', timestamp: new Date().toISOString() }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        userRole = profile.role || 'customer';
      } catch (e) {
        return new Response(
          JSON.stringify({ success: false, error: 'Authentication failed', timestamp: new Date().toISOString() }),
          { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    const environment = getEnvironmentConfig(req);

    const { data: apiConfig } = await supabaseClient
      .from('api_configurations')
      .select('*')
      .eq('is_active', true)
      .eq('environment', environment)
      .single();

    const { data: features } = await supabaseClient
      .from('feature_flags')
      .select('name, description')
      .eq('enabled', true)
      .or(`user_roles.cs.{${userRole}}`, 'user_roles.is.null');

    const { data: smsConfig } = await supabaseClient
      .from('sms_config')
      .select('production_mode, provider')
      .single();

    const { data: systemSettings } = await supabaseClient
      .from('system_settings')
      .select('key, value');

    const getSetting = (key: string, defaultValue: string = ''): string => {
      return systemSettings?.find(s => s.key === key)?.value || defaultValue;
    };

    const appDomain = Deno.env.get('APP_DOMAIN') || 'localhost';
    const baseUrl = environment === 'production'
      ? `https://${appDomain}`
      : environment === 'staging'
      ? `https://staging.${appDomain}`
      : 'http://localhost:8000';

    const configResponse = {
      success: true,
      data: {
        apiKeys: {
          supabase: { url: baseUrl, anonKey: supabaseAnonKey },
        },
        features: {
          testMode: !smsConfig?.production_mode,
          maintenanceMode: apiConfig?.maintenance_mode || false,
          otpEnabled: true,
          smsProvider: smsConfig?.provider || 'twilio',
          maxFileUploadSize: parseInt(getSetting('max_file_size', '52428800')),
          enabledFeatures: features?.map(f => f.name) || [],
        },
        environment: {
          name: environment,
          version: apiConfig?.app_version || '1.0.0',
          region: getSetting('region', 'local'),
        },
        urls: {
          api: `${baseUrl}/rest/v1`,
          storage: `${baseUrl}/storage/v1`,
          realtime: `${baseUrl.replace('http', 'ws')}/realtime/v1`,
        },
        limits: {
          otpHourlyLimit: parseInt(getSetting('otp_hourly_limit', '40')),
          otpDailyLimit: parseInt(getSetting('otp_daily_limit', '20')),
          sessionTimeout: parseInt(getSetting('session_timeout', '3600')),
          apiRateLimitPerMinute: parseInt(getSetting('api_rate_limit_per_minute', '100')),
        },
        support: {
          email: getSetting('support_email', 'support@example.com'),
          phone: getSetting('support_phone', '+1234567890'),
          appName: getSetting('app_name', 'My Warehouse'),
        },
      },
      timestamp: new Date().toISOString(),
    };

    return new Response(JSON.stringify(configResponse), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json',
        'Cache-Control': userRole === 'anon' ? 'public, max-age=300' : 'private, max-age=60',
      }
    });

  } catch (error) {
    console.error('Error in get-config function:', error);
    return new Response(
      JSON.stringify({ success: false, error: 'Internal server error', timestamp: new Date().toISOString() }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
