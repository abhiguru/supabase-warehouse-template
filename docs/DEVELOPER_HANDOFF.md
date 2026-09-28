# Independent operator developer handoff

Use [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md) for the fresh Linux x86-64 host or
Windows/Linux VM installation. Current setup accepts `--operator` only. Keep
credentials and persistent state outside the checkout; obtain real MSG91 and
HTTPS settings for the selected warehouse before its integration test.
Read [OPERATOR_SETUP_NOTES.md](OPERATOR_SETUP_NOTES.md) for the dated VM findings,
resolved setup shortcomings, safe operator-question sequence and remaining edge
cases. The installation guide incorporates the prerequisites and configuration
traps discovered during that pilot.

[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md#independent-operator-installation-work)
is the authoritative work and acceptance ledger. It distinguishes implemented
software, automated verification, unfinished software, and external or physical
acceptance. Green CI does not close the production handoff.

The operator changes are under [backend PR #68](https://github.com/abhiguru/supabase-warehouse-template/pull/68)
and [mobile PR #33](https://github.com/abhiguru/rn-warehouse-template/pull/33).
Use the exact companion commit pinned in the active backend CI workflow when
reproducing a tested pair. Record both checked-out commits and the native build
ID in the VM acceptance record. These draft PRs require review before merging.

For the new VM, first run local setup and doctor, then verify HTTPS discovery
from warehouse Wi-Fi and cellular data. Verify real SMS login for the locally
bootstrapped administrator, pending customer enrollment and approval, and the
business flows. Reboot without an interactive login and verify reconnection.
Run the backup and isolated restore drill before loading real warehouse data;
replacement-host restoration remains a separate acceptance test.
The [2026-09-27 replacement-host restore drill](REPLACEMENT_HOST_RESTORE_DRILL.md)
records a successful isolated logical restore on a fresh VM, its failed attempts,
and the remaining off-host recovery and cutover gates. The original pilot stayed
live; that drill is not production recovery approval.
The [2026-09-28 v4 installer drill](REPLACEMENT_HOST_RESTORE_INSTALLER.md)
adds tested cluster-global replay, staged promotion, the pre-existing private
PDF, local access checks and owned restart recovery on the previously used
replacement VM. Its candidate branch still needs review and a clean-host test;
the original remains the only live connector.

Printing and sensor capabilities stay disabled until their software and hardware
acceptance is recorded in the ledger. The existing image security findings remain
**won't fix in current scope**; they are not patched, passed, or an unconditional
production security approval.

[Historical source-demo handoff](SOURCE_DEMO_DEVELOPER_HANDOFF.md) preserves the
original exact commits and device evidence. Its installation commands apply only
to the historical code. Preserve the immutable `v0.2.2-demo` tag.
