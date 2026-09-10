# Second-pass readiness review — 2026-09-10

## Decision: not ready for a working end-to-end release

The v0.1.0 repositories contain a mobile application and an incomplete backend
template, not a complete sanitized export of the original backend. Do not use
this schema for a production installation or advertise a ten-minute working demo.
Setup/start are deliberately gated before any environment or Docker mutation.
This review did not change the original repositories, servers, or credentials.

## Reproduced blockers

| Check | Result |
| --- | --- |
| Empty Supabase Postgres 15.8.1.060 schema restore | Fails: `type public.user_role does not exist` at `user_profiles` |
| Literal mobile RPC coverage | 70 missing out of 76 called |
| Literal mobile table coverage | Missing `dispatch_trl`, `goodsreceived_trl`, `grn_images`, `order_items` |
| Mobile Edge Function coverage | Seven PDF/preprinted-print functions missing |
| GitHub Actions | Definitions exist but are not installed as active workflows |
| End-to-end login/GRN/dispatch/invoice | Blocked by the missing backend; not tested successfully |

Reproduce using `npm run test:migrations` and
`node scripts/check-mobile-contract.mjs ../rn-warehouse-template` after `npm ci`
in the mobile checkout. [API_CONTRACT.md](API_CONTRACT.md) lists the missing names.
Presence is only a first check: signatures, return shapes, dynamic calls, and
database authorization must also be verified.

Further static schema problems include unterminated `$function$` definitions,
policies that reference absent helpers, absent `utils` functions and `http`/JWT
dependencies, indexes/policies referencing nonexistent trailer tables, and seed
columns that do not match the tables (`jwt_config.key/value`, `items.category/unit`).
The JWT secret generated into `.env` is not synchronized into `jwt_config`.
Adding the missing enum alone will not repair the export.

## Changes made in the second pass

- New configuration uses exclusive creation, private permissions, matching
  signed anon/service tokens, and no secret output. Reruns preserve every byte.
- Removed production-style container names, fixed IP addresses/subnet, and the
  missing Vector config dependency. Source functions/Kong config mount directly.
  Core ports are distinct and loopback-only; Compose wrapper checks ownership.
- Setup/start refuse an incomplete release. SQL execution now fails fast;
  migrations and their applied-file ledger entries are transactional. Health
  checks return nonzero on failure and probe the intended project's network.
- Edge handlers verify signatures, algorithm, issuer, expiry, and token kind
  before trusting claims. Authenticated config uses active custom-auth profiles,
  not the disabled GoTrue service. Public bootstrap remains separately public.
- Public URLs come from explicit configuration instead of always returning
  localhost. Configuration errors return failures, not fake successful defaults.
- Sample PDF requires staff access and escapes user text. IPP imports Buffer
  explicitly and validates printer names. Physical printing remains untested.

Local checks passing: Node configuration/JWT/profile tests, shell syntax, and
Compose rendering. The migration/contract checks correctly fail on the blockers
above. Unit tests are not an independent security audit or a full-stack test.

## Required before removing the release gate

1. Rebuild a **complete, schema-only, sanitized backend export** from the original
   source/schema. Include enums, schemas/extensions, sequences, all domain and
   assignment tables, functions, views, triggers, constraints, RLS, grants, and
   Storage bucket definitions/policies. No customer rows, auth rows, OTPs, backups,
   tokens, production URLs, private keys, remote history, or signing assets.
2. Apply it with `ON_ERROR_STOP` to a genuinely empty isolated database. Fix seed
   schemas, make seeds repeatable, add migration checksum/concurrency protection,
   and synchronize freshly generated server JWT configuration without modifying
   any existing deployment's credentials. Prove reruns retain configuration/data.
3. Add a safe operator-only first-admin procedure and fictional demo customers,
   items, prices, and assignments. Do not expose `create_first_admin` anonymously.
4. Implement and test every required mobile RPC/Edge Function, parameter, and
   response shape. Run login, wrong/replayed/expired OTP, logout, restart, expired
   access-token refresh, disabled-user, and customer-assignment flows. The current
   OTP code's production fallback to `123456`, permanent test-phone bypass,
   attempt limits, concurrent verification, and refresh/session handling must be
   replaced/reviewed before production use. Missing SMS config must fail closed.
5. Replace blanket function/table grants with explicit least-privilege grants.
   Audit SECURITY DEFINER functions and safe search paths. Prove anonymous users
   cannot read/write business/config data or create admins; customers cannot
   access another customer's data or change their own role/active/assignments;
   inactive users cannot retain access. Test as real database roles, including
   reads/writes through RPC and Storage, not just policy-text matching.
6. On fresh data, test customer creation, GRN + image upload, stock balances,
   dispatch without overselling, invoice calculations, payments, orders, reports,
   image deletion, and PDF output. Explicitly gate optional sensor/printing
   features until they have implementations and device tests.
7. Review custom auth's compatibility with Storage and Realtime. The current
   Compose tuning uses `wal_level=replica`; Realtime requires separate validation
   and appropriate logical replication configuration. Do not claim it works.
8. Audit Docker image dependencies, TLS/CORS, rate limits, PDF renderer network
   access, log redaction, backup/restore, and optional privileged host/USB mounts.
   Never expose Studio, Postgres, monitoring, or test OTP mode publicly. Optional
   profiles and all older operational docs need a fresh validation pass.
9. Address the mobile dependency audit and perform native Android/iOS builds and
   device flows. Install CI with workflow permission, keep failing gates enabled,
   and run a full secret/history scan plus rights/asset review before the next
   release. Make the release reflect what is actually verified.

## External documentation used

Isolation follows [Compose project naming](https://docs.docker.com/compose/how-tos/project-name/)
and [service DNS networking](https://docs.docker.com/compose/how-tos/networking/).
JWT validation follows the signature-verification requirement described in
[Supabase JWT documentation](https://supabase.com/docs/guides/auth/jwts).

Completing this checklist is a backend-export/integration task, not credential
rotation. Existing private deployments can stay unchanged throughout.
