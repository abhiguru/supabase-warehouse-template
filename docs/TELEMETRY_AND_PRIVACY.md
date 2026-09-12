# Telemetry, Privacy and Data Redaction Policy

## Overview

The mobile application includes optional centralized crash reporting via Sentry / GlitchTip (`@sentry/react-native`). GlitchTip is an open-source, Sentry-compatible error tracking service.

This document outlines the privacy design, client-side redaction rules, opt-in mechanism, and server-side data retention requirements.

---

## 1. Opt-In Configuration and Activation

Telemetry is strictly opt-in and disabled by default:

- **Empty DSN by Default**: In `.env.example`, `EXPO_PUBLIC_SENTRY_DSN` is blank. If unconfigured, Sentry is never initialized.
- **Development Mode Isolation**: Sentry is deactivated during local development (`enabled: !__DEV__ && !!SENTRY_DSN`), ensuring local debugging data never leaves the developer's machine.
- **Performance Tracing Disabled**: `tracesSampleRate: 0` disables performance sampling, preventing unnecessary network transmissions and runtime overhead.
- **No Default PII**: `sendDefaultPii: false` instructs the native SDK not to collect device-level identifiers, Wi-Fi networks, or IP addresses.
- **Breadcrumb Buffer Limit**: `maxBreadcrumbs: 50` caps the in-memory history to prevent excessive context accumulation.

---

## 2. Client-Side Redaction Pipeline

Before any packet is emitted over the network, two mandatory client-side gates execute in `src/config/sentryConfig.ts`:

### A. Real-Time Breadcrumb Filter (`beforeBreadcrumb`)

As user actions and network events occur, breadcrumbs are sanitized before being stored:

- **HTTP URLs**: Query parameters containing `token`, `access_token`, `refresh_token`, `apikey`, `api_key`, `code`, `secret`, `auth`, `password`, `key`, `credential`, or `otp` are replaced with `[REDACTED]`. Any parameter value containing a JWT format is redacted to `[REDACTED_JWT]`.
- **HTTP Headers**: Headers including `Authorization`, `apikey`, `x-supabase-auth`, `Cookie`, `Set-Cookie`, `Proxy-Authorization`, and `X-Api-Key` are stripped and replaced with `[REDACTED]`.
- **Breadcrumb Messages & Data**: All strings and structured objects are recursively inspected and redacted for sensitive patterns.

### B. Event Transmission Filter (`beforeSend`)

When an unhandled exception or captured error occurs:

- **User Object**: `phone`, `email`, and `ip_address` are explicitly replaced with `[REDACTED]`. Only opaque user UUIDs (`id`) and coarse application roles (`role`) are retained.
- **Request Payloads**: Request URL, query strings, headers, and request body objects undergo deep recursive sanitization.
- **Extra Context**: Context dictionaries passed to `captureException` are scanned; keys matching sensitive credential names and values matching regex patterns are sanitized.
- **Tags & Metadata**: Custom tags matching sensitive identifiers are redacted.

### C. Redaction Pattern Registry

| Pattern Category | Target Examples                                | Replacement               |
| ---------------- | ---------------------------------------------- | ------------------------- |
| JWT Tokens       | `eyJhbGciOi...`                                | `[REDACTED_JWT]`          |
| Bearer Tokens    | `Bearer eyJ...` / `Bearer abc...`              | `Bearer [REDACTED_TOKEN]` |
| Phone Numbers    | `+91 9876543210`, `9876543210`, `555-123-4567` | `[REDACTED_PHONE]`        |
| OTP Codes        | `otp: 123456`, `pin: 9876`                     | `otp: [REDACTED_OTP]`     |
| Email Addresses  | `user@example.com`                             | `[REDACTED_EMAIL]`        |
| API Keys         | `sbp_...`, `sk_...`, `pk_...`                  | `[REDACTED_API_KEY]`      |

---

## 3. Server-Side Retention and Cleanup

For deployers hosting GlitchTip or utilizing Sentry Cloud:

1. **Retention Window**: Configure event retention to **30 to 90 days maximum**. Stale error events should be automatically purged by scheduled database maintenance (`glitchtip cleanup` or Sentry TTL workers).
2. **Server-Side Data Scrubbers**: Enable GlitchTip/Sentry server-side data scrubbing rules as a secondary defense layer for IP masking and header scrubbing.
3. **Restricted Access**: Access to the error tracking dashboard should be restricted to authorized operational staff via role-based access control and MFA.
4. **No Marketing / Analytics Use**: Error telemetry events must never be exported, joined with customer analytics datasets, or used for behavioural profiling.
