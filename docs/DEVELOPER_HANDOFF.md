# Developer handoff — v0.2.1-demo

## Active source-demo continuation — 2026-09-18

This file retains the immutable `v0.2.1-demo` checkpoint below as history. For
the active handoff, create sibling clones named `rn-warehouse-template` and
`supabase-warehouse-template`, check out and fast-forward
`handoff/source-demo-20260917` in both, and record the resolved full SHAs. Before
setup, verify the active/documented CI workflow copies are byte-identical and
that both jobs pin the mobile checkout SHA.

Follow `CLEAN_INSTALL.md` with a unique Compose project and unused loopback
ports. Run setup, doctor, health, rerun, stop, and restart with the same project
name. Generate the sibling mobile environment through its script and use the
same localhost API origin. Do not copy configuration, credentials, or database
files from another checkout. Prove configuration and data preservation plus an
Android debug login/connectivity smoke before treating onboarding as
reproducible.

This branch is a source-demo candidate, not a production or all-platform
release. Physical camera/hardware, iOS, production SMS/TLS/operations,
distribution, printing, sensors, and unsupported integrations remain separate
gates. The branch becomes delivered only after both PRs merge and required CI
passes on the resulting default-branch commits.

The 2026-09-18 fresh-clone rehearsal passes generated configuration, migrations,
doctor/health, isolated API fixtures, setup rerun, owned stop/restart, preserved
data/configuration, and the companion Android debug build/login/native smoke.
Use the exact mobile SHA pinned in both workflow copies and repeat required checks
on the merged default-branch pair.

This pair is a local warehouse development demo, Android first. Production setup
remains blocked. Release notes identify the exact commit pair and verification:
[mobile](https://github.com/abhiguru/rn-warehouse-template/releases/tag/v0.2.1-demo),
[backend](https://github.com/abhiguru/supabase-warehouse-template/releases/tag/v0.2.1-demo).
The tags were published on 2026-09-14. See [release verification](RELEASE_CHECKLIST.md)
for the backend CI checkout failure and subsequent follow-up evidence.

## Prerequisites and paired checkout

Use Node.js 22.18+ with npm, Git, Docker with Compose v2, and OpenSSL. Android
native development needs a compatible JDK (17 or 21), SDK platform 36, build tools
36.0.0, platform tools, and an emulator or USB device. Expo SDK 54 / React Native
0.81.5 remain selected by the lockfile. Allow space for Docker images, npm,
the Android SDK/NDK, and Gradle caches. iOS requires macOS/Xcode and is untested.

```bash
git clone --branch v0.2.1-demo https://github.com/abhiguru/supabase-warehouse-template.git
git clone --branch v0.2.1-demo https://github.com/abhiguru/rn-warehouse-template.git
cd supabase-warehouse-template
npm ci
bash setup.sh --demo
npm run doctor
```

Setup exclusively creates `docker/.env` with mode 0600. Reruns preserve its bytes
and permissions. It starts the database, applies checksummed migrations and demo
authorization, then starts the API. Do not copy keys from another installation.
The scripts check both Compose project name and owning checkout before operating.

```bash
cd ../rn-warehouse-template
npm ci
node scripts/create-env.mjs
npm run doctor
adb reverse tcp:18000 tcp:18000
adb reverse tcp:8081 tcp:8081
npm run android
```

The app's `.env` must contain `EXPO_PUBLIC_CONFIG_API_URL=http://localhost:18000`.
Both backend public URL settings must use that exact origin. USB devices and
emulators use `adb reverse`; the supported demo does not use a LAN origin.
With several attached devices, select one using `adb -s SERIAL reverse ...`.
Run `npm start -- --localhost` for later Metro sessions. Doctor is read-only; it
checks prerequisites/configuration/connectivity without starting services or
printing credentials. It does not start ADB or prove device connectivity: inspect
`adb devices` and `adb reverse --list` yourself. `doctor -- --backend-only` checks
the mobile bootstrap without requiring the Android SDK.

## First login and warehouse walkthrough

Enter admin **0000000001**, then demo OTP **123456**. For the assigned customer,
use **0000000002** and the same code. No SMS is sent. Only fictional numbers
0000000001–0000000009 work in explicit demo mode. OTP limits still apply (five
requests/hour, twenty/day); repeated automated runs consume those allowances.

1. As admin, open the seeded customer and create a GRN with the example item,
   100 bags at 10 kg each, a receipt date, and a rack. Note the GRN number.
2. Dispatch 20 bags from that GRN. Stock should be 80 bags / 800 kg. Reopening
   stock and customer reports should show the committed movement.
3. Sign out, then sign in as the assigned customer. View that customer's stock,
   add an item to a cart, change its quantity, and remove it. Customers cannot
   create GRNs, dispatch stock, or access another customer's images.
4. Sign back in as admin. Configure a monthly item price using `price_type` and
   `unit_price`. Dispatch the remaining stock before generating an invoice
   preview; preview requires a fully dispatched, uninvoiced GRN. Review rates,
   duration, labour, tax and rounding before saving.
5. Download a GRN, dispatch, invoice or customer-stock PDF. Documents use generic
   starter layouts. GRN/dispatch images use register → upload → confirm;
   deletion revokes metadata access and removes stored bytes. A storage cleanup
   failure is reported, not treated as complete deletion.

`npm run test:api` in the backend creates fictional fixtures for these API flows.
The test uses a customer-specific monthly rate of 5, labour rate 2 and tax 5%.
For 100 units dispatched after 31 days in legacy duration mode, preview asserts
1.5 periods, storage 750, labour 200, subtotal 950, rounded tax 48 and total 998.
Existing invoice save accepts client-supplied totals and rounds total/tax upward
to whole units; it does not independently recalculate all supplied business values.
These are preserved demo rules. See the backend
[formula reference](https://github.com/abhiguru/supabase-warehouse-template/blob/main/docs/INVOICE_RULES.md)
for duration boundaries, row/header rounding and unsupported contracts.

## Architecture and contribution workflow

`app/` contains Expo Router screens. Mobile services call PostgREST RPCs and
private Storage; Redux holds UI state. Public bootstrap discovers the anon key.
Only SecureStore restores session identity. Public configuration is cached by
origin for one hour; full configuration uses origin/user/session for 60 seconds.
Logout/account changes invalidate pending work and authenticated configuration.
Server session checks, current roles and RLS remain authoritative.

The backend runs Kong, PostgREST, PostgreSQL, Storage, Edge functions and the PDF
renderer in a checkout-owned Compose project. Custom OTP sessions use opaque,
rotating refresh credentials; GoTrue is not the demo login path. PDF Edge
functions authorize the caller before rendering and private signed download.

For changes, branch from current main in both public repositories. Use `npm ci`;
commit lockfile changes deliberately. Mobile checks: `npm test`, `npm run typecheck`, `npm run lint`, `npm run test:setup`, `npx expo install --check`,
`npm audit`, and Android export/native validation when applicable. Backend
checks: `npm test`, `npm run test:migrations`, `npm run test:api`, and
`node scripts/check-mobile-contract.mjs ../rn-warehouse-template --live`.
Migration tests create/remove their own disposable database. Add a migration;
never edit an already applied migration or broaden grants to satisfy a screen.
Submit PRs and wait for required checks. Source-only demo releases retain the
separate production gate and preserve historical tags.

## Troubleshooting and shutdown

| Symptom | Action |
| --- | --- |
| Missing prerequisite | Run doctor; install prerequisites yourself, then retry. |
| Project belongs to another checkout | Export a unique `WAREHOUSE_PROJECT_NAME=warehouse-your-name` for every backend command. |
| Port conflict | Before starting a fresh checkout, select distinct unused API/HTTPS/Studio/DB/renderer ports in its generated env. Update both backend public URLs, the mobile origin and ADB reverse mapping. |
| Phone cannot fetch bootstrap | Verify USB authorization, selected device, reverse mappings, API health, and matching localhost origins. |
| Existing env rejected | Inspect only your checkout's settings; setup intentionally preserves them. Never overwrite another installation's credentials. |
| OTP throttled | Wait for the limit window; do not disable auth protections or reset a production database. |
| Session expired/offline | Restore connectivity and retry; definitive authorization rejection requires login. Logout clears local credentials even if server revocation cannot be reached. |
| Image cleanup failed | Metadata access is revoked, but a maintainer must inspect remaining bytes in this demo's private bucket before claiming complete removal. |
| Invoice preview unavailable | Fully dispatch the GRN, check its pricing configuration and ensure it is not already invoiced. |
| Decoder installation refused | Dependency version/content changed. Review the adapter and consumer tests; do not bypass postinstall or suppress the advisory. |

Stop Metro with Ctrl-C. In the backend checkout run `bash stop.sh`; restart with
`bash start.sh --demo`. Keep the same `WAREHOUSE_PROJECT_NAME` when customized.
Stop preserves database/files. Remove only the reverse mappings you created:
`adb reverse --remove tcp:18000` and `adb reverse --remove tcp:8081`.

## Unsupported and separately untested

Physical printing, sensors, Realtime, customer document uploads, production SMS,
barcode scanning and automatic offline/SQLite synchronization are unsupported.
Printing/sensor UI explains unavailability; hardware Edge endpoints return 503.
The imported dual-rate pricing overload is not the mobile contract and currently
fails its legacy table constraints; combined-rate semantics require a separate
review. Change-category filtering is unavailable; other change-log filters remain.
Payments/accounting integrations are not part of the documented demo workflow.

Physical-device camera/USB acceptance, iOS, production scale/security, native
telemetry delivery, retention enforcement, privacy declarations and maintainer
ownership/redistribution rights remain separate checks. See RELEASE_CHECKLIST.md
and NATIVE_ACCEPTANCE.md (mobile) for evidence; a successful bundle is not a device test.
