import { restClient } from '../_shared/supabase-rest.ts';
import { securityHeaders } from '../_shared/security-headers.ts';
import { validateUserAccess, createAuthErrorResponse } from '../_shared/auth-helpers.ts';
import { publicBaseUrl } from '../_shared/public-url.ts';

Deno.serve(async (req: Request) => {
  if (req.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: securityHeaders });
  try {
    // Session tokens are verified locally (validateUserAccess); there is no GoTrue service.
    const profile = await validateUserAccess(req);
    const baseUrl = publicBaseUrl(Deno.env.get('SUPABASE_PUBLIC_URL'));
    const environment = Deno.env.get('APP_ENV') || 'development';
    const client = restClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const [configResult, flagsResult, smsResult, settingsResult] = await Promise.all([
      client.from('api_configurations').select('app_version,build_date,maintenance_mode').eq('environment', environment).eq('is_active', true).single(),
      client.from('feature_flags').select('name,enabled,user_roles').eq('enabled', true),
      client.from('sms_config').select('production_mode,provider').order('id', { ascending: false }).limit(1).single(),
      client.from('system_settings').select('key,value'),
    ]);
    if ([configResult, flagsResult, smsResult, settingsResult].some(result => result.error)) throw new Error('Configuration unavailable');
    const settings = Object.fromEntries((settingsResult.data || []).map(row => [row.key, row.value]));
    const number = (key: string, fallback: number) => Number(settings[key]) || fallback;
    const config = configResult.data!;
    return new Response(JSON.stringify({ success: true, data: {
      apiKeys: { supabase: { url: baseUrl, anonKey: Deno.env.get('SUPABASE_ANON_KEY') } },
      features: {
        testMode: !smsResult.data!.production_mode, maintenanceMode: config.maintenance_mode, otpEnabled: true,
        smsProvider: smsResult.data!.provider, maxFileUploadSize: number('max_file_size', 52428800),
        allowedFileTypes: ['image/jpeg', 'image/png', 'image/webp', 'application/pdf'],
        enabledFeatures: (flagsResult.data || []).filter(flag => flag.user_roles === null || flag.user_roles.includes(profile.role)).map(flag => flag.name),
      },
      environment: { name: environment, version: config.app_version, buildDate: config.build_date, region: settings.region || 'local' },
      urls: { api: `${baseUrl}/rest/v1`, storage: `${baseUrl}/storage/v1`, realtime: `${baseUrl.replace(/^http/, 'ws')}/realtime/v1`, auth: `${baseUrl}/rest/v1/rpc` },
      limits: {
        otpHourlyLimit: number('otp_hourly_limit', 5), otpDailyLimit: number('otp_daily_limit', 20),
        sessionTimeout: number('session_timeout', 3600), refreshTokenExpiry: number('refresh_token_expiry', 604800),
        apiRateLimitPerMinute: number('api_rate_limit_per_minute', 100), apiRateLimitPerHour: number('api_rate_limit_per_hour', 1000),
      },
      support: { email: settings.support_email || '', phone: settings.support_phone || '', appName: settings.app_name || 'Warehouse Manager' },
    }, timestamp: new Date().toISOString() }), {
      headers: { ...securityHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
    });
  } catch (error) { return createAuthErrorResponse(error, securityHeaders); }
});
