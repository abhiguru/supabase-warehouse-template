# Custom Phone OTP Authentication

This template implements phone-based OTP authentication without GoTrue, using PostgreSQL RPC functions and custom JWT generation.

## Why Not GoTrue?

- **Simpler**: No separate auth service to manage
- **Phone-first**: Designed for phone OTP, not email/password
- **Fewer containers**: One less service to run and monitor
- **Full control**: Custom rate limiting, session management, audit logging

## Flow

### 1. Send OTP
```sql
SELECT send_otp('911234567890');
```
Returns: `{ "success": true, "message": "OTP sent", "expires_in": 300 }`

### 2. Verify OTP & Get Token
```sql
SELECT verify_otp_or_register('911234567890', '123456', 'John Doe');
```
Returns:
```json
{
  "success": true,
  "token": "eyJhbG...",
  "refresh_token": "...",
  "user": { "id": "...", "name": "John Doe", "role": "customer" }
}
```

### 3. Use Token
```bash
curl http://localhost:8000/rest/v1/customers \
  -H "Authorization: Bearer eyJhbG..." \
  -H "apikey: YOUR_ANON_KEY"
```

## Test Mode

When `SMS_PRODUCTION_MODE=false` (default):
- OTP is always `123456`
- No SMS is actually sent
- Perfect for development and CI

## Key Functions

| Function | Purpose |
|----------|---------|
| `send_otp(phone)` | Generate and send OTP |
| `verify_otp_or_register(phone, otp)` | Verify OTP, create user if new, return JWT |
| `check_otp_rate_limit(phone)` | Rate limiting (configurable) |
| `check_session_validity(token)` | Validate active session |
| `create_first_admin(phone)` | Bootstrap first admin user |
| `update_user_role(user_id, role)` | Change user role (admin only) |
| `cleanup_expired_otps()` | Cron job to clean old OTPs |

## Roles

| Role | Access |
|------|--------|
| `admin` | Full access to all data and operations |
| `supervisor` | Full access to all data, some admin restrictions |
| `customer` | Read own data only (RLS enforced) |

## JWT Structure

```json
{
  "sub": "user-uuid",
  "role": "authenticated",
  "iss": "supabase",
  "exp": 1234567890,
  "user_role": "admin",
  "phone": "911234567890"
}
```

## SMS Providers

Configured via `.env`:

### Twilio
```
SMS_PROVIDER=twilio
TWILIO_ACCOUNT_SID=ACxxxx
TWILIO_AUTH_TOKEN=xxxx
TWILIO_PHONE_NUMBER=+1xxxx
```

### MSG91 (India, DLT compliant)
```
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=xxxx
MSG91_TEMPLATE_ID=xxxx
MSG91_PE_ID=xxxx
MSG91_SENDER_ID=WHOUSE
```

## Security

- OTPs expire after 5 minutes
- Rate limited: 40/hour, 20/day per phone number
- Failed attempts logged in `auth_logs`
- Expired OTPs cleaned up by `pg_cron`
- JWT tokens signed with `JWT_SECRET` (HS256)
