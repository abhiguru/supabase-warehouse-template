# Lost-response controls for an owned fictional fixture

Read UNATTENDED_FIXTURE.md first. This optional tool belongs to the original
guarded core fixture, never an installed warehouse. It is not loaded by ordinary
setup/start and cannot be used as production authentication or ingress. Do not
change tests/operator-fixture.mjs to make another state pass.

Before using it, record the exact source and any declared local overlays, retain
private evidence, verify local doctor, and start the normal fictional HTTPS
bridge on127.0.0.1:18443. The relay uses the same private TLS files and verifies
that bridge's certificate with its hostname; it does not disable TLS validation.
Confirm18643 and a new private control socket path are unused.

Run from the checkout which owns the fixture's Compose services, with its original
WAREHOUSE_STATE_DIR and pinned Node22 environment:

```bash
export WAREHOUSE_FIXTURE_TLS_DIR="$FIXTURE_PRIVATE/tls"
export WAREHOUSE_FIXTURE_FAULT_SOCKET="$FIXTURE_PRIVATE/fault-control.sock"
node scripts/fixture-fault-relay.mjs
```

The original guard checks fictional identity, dummy provider, state ownership and
running database ownership before either listener starts. TLS/control directories
must be owned0700 and regular TLS files owned0600. The control socket is0600;
occupied paths/listeners are refused. Keep output in private evidence. Stop the
owned process normally and verify listener/socket cleanup; never unlink a live
socket or globally stop Docker/ADB.

Each arm is one-shot and can match only POST save_grn or
create_dispatch_with_stock_check. Use either an exact fixture-fault-prefixed key,
an exact corrected warehouse-grn/warehouse-dispatch digest key, or a reserved
fictional document FXF followed by2..5digits. Document matching also requires an
actual UUID or corrected digest operation key. Ordinary documents, another RPC,
another key and real OTP requests cannot consume that arm. Pending/in-flight arms
cannot be overwritten; inspect status before recovery.

Write one JSON command to the protected Unix socket, followed by a newline:

```json
{"action":"arm","phase":"before-upstream","path":"/rest/v1/rpc/save_grn","record":"FXF01"}
```

For example, in a separate local terminal (no credential or OTP input):

```bash
python3 - <<'PY'
import json, os, socket
s = socket.socket(socket.AF_UNIX); s.settimeout(5)
s.connect(os.environ['WAREHOUSE_FIXTURE_FAULT_SOCKET'])
s.sendall(json.dumps({"action":"status"}).encode() + b'\n')
print(s.recv(2048).decode()); s.close()
PY
```

The two phases establish different observations:

| Phase | Transport behavior | Required independent postcondition |
| --- | --- | --- |
| before-upstream | Receives the complete matching request, then drops the client connection without forwarding | No matching receipt/dispatch, stock change or idempotency row; retry creates exactly one operation |
| after-upstream-success | Waits for a complete HTTP2xx RPC response with success:true, then drops it before returning bytes | Read the owned database to prove exactly one committed operation; retry must use the same key, return that result and leave stock/lines unchanged |

A rejected/malformed/failed/timed-out upstream is not an after-success fault.
The relay reports that distinction instead of pretending it interrupted a commit.
Requests/responses are bounded1MiB/2MiB and upstream work has a15second deadline.
The controller itself does not write business data or produce credentials.

For an owned emulator, temporarily reverse443 to18643 only for the selected
fictional write. Restore443 to the normal18443 bridge in a finally/cleanup step.
This relay deliberately rejects WebSocket upgrades; Realtime, images and PDFs
must use the normal route and their separate cases. Never change VM DNS, a phone,
Test1 ingress or a production connector for this exercise.

Before a write, assert its reserved document is absent and save a private baseline
of matching header/lines, affected stock and the operation key. After each fault,
capture control status and independent read-only database results before retrying.
After a lost response, do not edit the form or generate a new operation key while
calling it a retry. Match invoice postconditions to the actual RPC contract:
create_dispatch_with_stock_check p_generate_invoice returns calculation data
conditionally; it does not itself call save_invoice. Assert no persisted invoice
for these reserved partial dispatches, then verify saved invoices/PDFs separately. Following interruption, inspect whether the write committed;
the plan runner must never automatically repeat an unresolved write.

Current source regressions exercise socket loss, one-shot forwarding, target/key/
document guards, upstream rejection, size limits and absolute timeouts without a
warehouse. They establish the control's transport behavior only. Four current guarded API/database before/after cases PASS566, with final
read-only headers/lines/quantities/stock/cache/no-invoice reconciliation572.
API dispatch used generate_invoice:false. Native code2026093012/b03f197 before
(FXF201) and after-success (FXF202) same-form retries PASS582: expected native
network error, independently proved no-commit/commit before retry, native success,
one header/line/cache per dispatch, two units each, dedicated stock10→8→6.
Native requested generate_invoice:true; zero persisted invoices/errors matches
the calculation-only RPC path. Incorrect one-invoice verification FAIL583 is
retained with the corrected read-only recheck. No invoice policy/source was
changed. Normal443→18443 route restored and fault disarmed PASS584. Native receipt
faults, saved-invoice effects, current PDF viewing and the full plan remain
separate cases; compilation or proxy tests cannot close them.
