# Source-demo acceptance

Status: completed for the Android-first source demo on **2026-09-18**.
`v0.2.2-demo` is the forthcoming immutable source-only prerelease checkpoint
until its tag-validation workflow passes and the GitHub prerelease is published.

The accepted backend/application behavior was exercised as a compatible pair.
The final tag targets and cross-repository commit pair are recorded in the two
GitHub release notes because a commit cannot contain its own final SHA.

## Verified scope

- Fresh public sibling clones installed locked dependencies without private
  files. Repository scripts generated mode-0600 configuration and preserved it
  byte-for-byte across setup rerun and owned stop/restart.
- A checkout-owned, loopback-only Compose project applied migrations 00000–00010,
  passed health/doctor checks, skipped every migration on rerun, and retained
  fixture counts and deterministic redacted digests after restart.
- Static and live compatibility checks found 93 RPC names, 127 typed mobile calls,
  zero missing names, and zero mismatches. The isolated API suite passed custom
  login, RLS/role boundaries, GRN, dispatch and exact stock mutation, images,
  orders, invoices, reporting, refresh/logout, and four PDF flows.
- An API-36 Android debug build passed bootstrap, demo login, authenticated cold
  restoration, native picker image upload/display/delete, representative PDF
  sharing, and protected/malformed navigation checks against the paired backend.
- The delivered pre-release baseline passed backend CI run
  [35269882640](https://github.com/abhiguru/supabase-warehouse-template/actions/runs/35269882640)
  and mobile CI run
  [35269266129](https://github.com/abhiguru/rn-warehouse-template/actions/runs/35269266129).
  Release-preparation changes are documentation and release-gate changes and must
  pass their own PR, default-branch, and exact-tag workflows before publication.

## Supported onboarding

Use matching `v0.2.2-demo` tags in this repository and
[`rn-warehouse-template`](https://github.com/abhiguru/rn-warehouse-template)
after publication. Before publication, use matching current `main` branches.
Keep the repositories as siblings, follow `docs/CLEAN_INSTALL.md`, and verify the
two byte-identical CI workflow copies pin the mobile commit checked out.

## Separate gates

Physical camera and other Android hardware, iOS, production SMS/TLS/operations,
app-store or signed-binary distribution, printing, sensors, Realtime, payments,
and unsupported integrations remain separate gates. The source-demo acceptance
does not claim production readiness or all-platform acceptance.
