# Guarded fixture preservation and ordinary final-test authentication

The backend final workflow now obtains each fictional session through normal
OTP preparation, mocked provider completion and ordinary verification. It waits
for the existing cooldown and consumes normal quotas. It does not directly call
the internal session issuer, reset counters, use fixed OTPs or change timestamps.
Admin/customer A/customer B use at most3/4/4 challenges across core, Realtime and
final workflows. Final-test admin/A sessions are normally logged out; disabling
B follows its dependent cases and removes B sessions through the administrator
API. Earlier unrelated sessions and business records are preserved.

The optional private final-test binding contains mode
`ordinary-final-backend-fixture`, backendCheckout, backendState, instanceId,
fixtureGuardSHA256 and evidenceRoot. The driver imports that exact unchanged
fixture guard, validates the real identity and private owned evidence directory,
and cannot replace frozen backend inputs. Ordinary same-checkout runs need no
extra argument. For VM acceptance use the private binding so newly created image
bytes and metadata are saved before the intentional deletion lifecycle test.
Upload/download bytes must equal the actual1024-byte fixture input. No upload
secret or signed URL is serialized. Authentication and image lifecycle changes
remain explicitly dated test evidence, not production account acceptance.

`scripts/fixture-preservation-snapshot.mjs PRIVATE_CONFIG OUTPUT_JSON` is a
read-only observer. Its private binding has mode `read-only-preservation`,
backendCheckout/backendState/instanceId/fixtureGuardSHA256/evidenceRoot. It uses
the original guard and repeatable-read read-only SQL; credential/session/OTP
rows are hashed inside PostgreSQL and never exported in plaintext. Actual stored
files are bounded and hashed, without following symlinks. Outputs are private,
created once, and contain hashes/counts/fictional file paths only.

Compare configuration/identity, all table counts and stable hashes and all actual
file hashes across repeated setup. Preserve full hashes too. Existing setup
updates only the SMS configuration timestamp even when credentials are equal;
`public.sms_config.updated_at` is the sole declared stable-hash exception, never
an allowance for credential or business changes. Record any other difference
as failure and reconcile before retry. Do not infer a repeat-setup PASS from an
observer-only check.

Actual populated-fixture observer validation:85 tables/17 files read twice,
identical snapshots, no writes. Private proof under VM campaign
`backend-reproduction0110-01/observer-populated-primary-proof01.json`.
The fresh079ab4a VM setup/local doctor/unchanged guard now PASSed on its final
allowed corrected attempt. Workflow, repeat-setup and fixture HTTPS acceptance
still require their own execution and evidence. Both prior install failures,
exact preserved images and owned-cache reclamation remain recorded.
