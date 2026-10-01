# Isolated unattended fixture sequence

This optional sequence was exercised on Ubuntu 24.04.3 x86_64, Node 22.23.3,
npm 10.9.9, Docker 29.8.1 and Compose 2.40.3 on 2026-09-30. Read
OPERATOR_INSTALL.md first. It creates fictional data and must run separately
from any installed warehouse. The production pilot and recovery host are excluded.
Recovery, printing, sensors and external delivery are not part of this sequence.
Authenticated cross-origin acceptance uses the separate [switching fixture](SWITCHING_FIXTURE.md);
its original core-fixture guards are not replaced or relaxed.

Interrupted-write acceptance needs the optional guarded
[lost-response rehearsal](FIXTURE_FAULT_REHEARSAL.md), independent database
postconditions and native retry evidence. Link-offline tests do not establish
whether a write committed before its response was lost.

Use a clean checkout of reviewed backend
`7e3f66a34bb729d80e25c6a4a0975f072c05d03a` (review PR #79), fetched from
`codex/fresh-vm-operator-install`. Record the full checked-out commit and any
local configuration overlay. This source includes Kong-only root DNS search to
avoid an inherited VM LAN suffix; do not add hidden DNS/source edits. Clone public source with umask 022. Use absolute,
unused paths outside Git for state and private evidence. The fixture guard
requires the state basename `core-backend-test-` followed by digits, owned by
the current user, mode 0700, without symlinks. Never rename another instance to
satisfy it. Do not disable the guards.

Clone and pin the fixture source without changing the installed checkout:

```bash
export FIXTURE_CHECKOUT="$HOME/warehouse-fixture-backend-2026093004"
test ! -e "$FIXTURE_CHECKOUT"
umask 022
git clone --branch codex/fresh-vm-operator-install \
  https://github.com/abhiguru/supabase-warehouse-template.git "$FIXTURE_CHECKOUT"
cd "$FIXTURE_CHECKOUT"
git checkout --detach 7e3f66a34bb729d80e25c6a4a0975f072c05d03a
git rev-parse HEAD
git status --short
```

Use the pinned Node installation in each new terminal before any fixture command:

```bash
export PATH="$HOME/.local/opt/node-v22.23.3-linux-x64/bin:$PATH"
node --version
npm --version
```

If using `sg docker -c`, ensure that same PATH reaches its command shell. An
older system Node must fail the version guard; do not bypass it.

The commands below assume the prerequisite sequence has passed and the shell
has effective Docker access. Choose a new suffix rather than reusing the example
when its state already exists. Choose an unused loopback gateway port; this run
used 18080 while the installed Test Warehouse 1 retained 18000.

```bash
export WAREHOUSE_STATE_DIR="$HOME/warehouse-state/core-backend-test-2026093004"
export FIXTURE_PRIVATE="$HOME/warehouse-fixture-private-2026093004"
test ! -e "$WAREHOUSE_STATE_DIR"
test ! -e "$FIXTURE_PRIVATE"
umask 077
mkdir -m 700 "$FIXTURE_PRIVATE"
cat > "$FIXTURE_PRIVATE/provider.env" <<'ENV'
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=isolated-no-delivery-key
MSG91_TEMPLATE_ID=000000000000000000000001
MSG91_PE_ID=0000000000000000001
MSG91_SENDER_ID=CITEST
ENV
chmod 600 "$FIXTURE_PRIVATE/provider.env"
ss -ltn
docker network inspect $(docker network ls -q) > "$FIXTURE_PRIVATE/networks.json"
```

Configuration and locked dependencies may be prepared while an earlier disposable
suite runs. Before starting any service or applying the network overlay, stop
only that earlier fixture and confirm port 18080 is unoccupied. For the gateway-IP tests,
inspect the saved network list for an overlap with **10.233.245.0/24**. Treat null
IPAM.Config as an empty list. Stop if it overlaps; do not change another network
or invent a subnet while claiming the same gateway regression coverage. In this
dedicated checkout only, append the CI overlay to docker/docker-compose.override.yml:

```yaml
networks:
  default:
    ipam:
      config:
        - subnet: 10.233.245.0/24
```

Do not append a second networks key to an already modified checkout. Preserve
the overlay in the installed-modifications record. Generate private configuration
before starting services, then change only this fresh fixture's gateway port:

```bash
umask 022
npm ci
node scripts/configure.mjs --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://backend-core.example.test --company 'Fictional Core Warehouse' \
  --provider-env "$FIXTURE_PRIVATE/provider.env"
umask 077
python3 - <<'PY'
import os, re
from pathlib import Path
p = Path(os.environ['WAREHOUSE_STATE_DIR']) / 'config/compose.env'
s, count = re.subn(r'^KONG_HTTP_PORT=18000$', 'KONG_HTTP_PORT=18080', p.read_text(), flags=re.M)
assert count == 1, 'Unexpected fresh configuration; inspect privately before proceeding'
p.write_text(s)
assert p.stat().st_mode & 0o077 == 0
PY
bash setup.sh --operator --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://backend-core.example.test --company 'Fictional Core Warehouse' \
  --provider-env "$FIXTURE_PRIVATE/provider.env" \
  --admin-phone 919888888871 --admin-name 'Core Demo Administrator'
```

Keep command output in private logs. Record each exit code independently; an
audit failure must not be concealed by a later successful command. Run in order:

```bash
npm test
npm run test:migrations
npm run check:container-dependencies
node scripts/doctor.mjs --local
node tests/operator-api-core.mjs
node tests/operator-realtime-core.mjs
node tests/operator-api-final.mjs
npm run test:studio
npm run test:gateway
npm run test:gateway-dns
npm run retention:preview
```

Current1October clean7e result618:75 unit tests, migrations, setup/doctor, core
API, customer A/B Realtime, final accounts/images, Studio, gateway CORS/size,
upstream-IP replacement, retention preview and live mobile contract PASS.
Same-input setup/catalog/actual stored-file hash preservation628 also PASS.
The earlier48-unit result remains historical in OPERATOR_SETUP_NOTES.md. Container audit FAIL remains open. This run did not
execute recovery, backup/restore, monitoring delivery, pooler or printer suites.
The earlier independent clean reproduction and same-input preservation checks
are recorded in OPERATOR_SETUP_NOTES.md. Tests mutate their own fixture data;
do not rerun against an installed warehouse to avoid preparing another fixture.

## Checking a new mobile source against this running fixture

Use the backend checkout that owns the fixture together with its original
WAREHOUSE_STATE_DIR. A separate review checkout must not borrow the state to
manage Compose or read its live catalog. With the new mobile path selected:

```bash
# Run inside this fixture's backend checkout; retain its state environment.
node scripts/check-mobile-contract.mjs /absolute/path/to/mobile-checkout \
  --live --output "$FIXTURE_PRIVATE/mobile-contract.json"
```

A refused ownership-checked catalog request is a FAIL to preserve, not permission
to bypass the guard. Fix the checkout/state pairing. This checks call names,
arguments, overloads, return types and grants; native/API behavior needs its own
evidence. The resumed e54c826 source passed this check from the owning fixture
checkout after the first wrong-checkout attempt failed.

## Optional native fixture delivery bridge

Keep the above fixture running for the mobile emulator sequence. Install OpenSSL
if absent. Check loopback port 18443 is unused. Generate a short-lived certificate
and private key in a new owned 0700 directory, never inside Git:

```bash
mkdir -m 700 "$FIXTURE_PRIVATE/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$FIXTURE_PRIVATE/tls/fixture-key.pem" \
  -out "$FIXTURE_PRIVATE/tls/fixture-ca.pem" \
  -subj '/CN=backend-core.example.test' \
  -addext 'subjectAltName=DNS:backend-core.example.test' \
  -addext 'basicConstraints=critical,CA:TRUE'
chmod 600 "$FIXTURE_PRIVATE/tls/fixture-key.pem" "$FIXTURE_PRIVATE/tls/fixture-ca.pem"
export WAREHOUSE_FIXTURE_TLS_DIR="$FIXTURE_PRIVATE/tls"
export WAREHOUSE_FIXTURE_SOCKET="$FIXTURE_PRIVATE/fixture-otp.sock"
node scripts/emulator-fixture-bridge.mjs
```

For short interactive diagnostics, use an owned foreground terminal and stop it
with Ctrl+C. For unattended work use the supervised procedure below. It
refuses an occupied socket, nonfixture state or unsafe private-directory/key
ownership. HTTPS binds only 127.0.0.1:18443 and forwards only to this fixture.
HTTP and WebSocket absolute, scheme-relative and external backslash targets are
rejected. Requests for the four documented fictional fixture phones create a
fresh cryptographic challenge through the existing service-only functions.
Ordinary verification still uses the backend's authentication implementation.
No provider call is made; no code appears in HTTP responses or bridge logs.

Only an owned local test driver may read the 0600 Unix socket in its 0700 parent:
send one JSON line with a fictional phone field, and receive the pending code
in memory. Never print it, put it in a command argument, save it, or expose that
socket/listener through a tunnel. Submit the code locally to the selected
**disposable emulator** via subprocess stdin. No fixed OTP, production bypass
or real SMS is involved. Guard rejection, TLS discovery, request/cooldown,
response secrecy, IPC permissions and forwarding-boundary probes passed;
these are harness checks, not native end-to-end acceptance.

The mobile review branch's OPERATOR_INSTALL_NOTES.md describes the dedicated
fixture APK, certificate overlay and emulator networking. Record that generated
native overlay separately from source HEAD. A CA expires after one day; create
new private material and rebuild the fixture APK when needed, rather than
disabling TLS verification.

## Supervise every dependency before an unattended run

An actual eight-hour attempt stopped in block 05 when all three terminal-backed
bridge/relay listeners disappeared, while Docker and the emulator continued.
The exact process termination cause is unestablished. Supervising only the
runner was insufficient. Use reviewed backend source
7e3f66a34bb729d80e25c6a4a0975f072c05d03a for the owning fixture checkouts and
tools. It adds bounded HTTP/upstream response handling, bounded WebSocket
upgrade handling and nonsecret request metadata. Original guards and fixture
authentication remain intact. Previously reproduced clean installation evidence
on 2584496 remains historical; the new transport checks are separately recorded.

Finish SWITCHING_FIXTURE.md setup and the fault-relay prerequisites first. Keep
both fictional databases running. Stop existing owned bridge/relay processes and
verify their ports and IPC paths are free. Never overwrite a listener/socket.
The explicit stale-socket procedure below applies only after proving the
recorded process is gone and connection is refused.

Set these paths to the exact instances and private TLS/socket directories already
recorded. Replace illustrative suffixes if different. Save the core state path
before the switching guide changes WAREHOUSE_STATE_DIR. Never select Test1:

```bash
export OWNED_CORE_CHECKOUT="$FIXTURE_CHECKOUT"
export OWNED_CORE_STATE="$HOME/warehouse-state/core-backend-test-2026093004"
export OWNED_SWITCH_CHECKOUT="$SWITCH_CHECKOUT"
export OWNED_SWITCH_STATE="$HOME/warehouse-state/cross-instance-test-2026093001"
export CORE_TLS_DIR="$FIXTURE_PRIVATE/tls"
export SWITCH_TLS_DIR="$SWITCH_PRIVATE/tls"
export CORE_SOCKET="$FIXTURE_PRIVATE/fixture-otp.sock"
export SWITCH_SOCKET="$SWITCH_PRIVATE/switch-otp.sock"
export FAULT_SOCKET="$FIXTURE_PRIVATE/fixture-fault-control.sock"
export FIXTURE_RUN_ID=network-diagnostic-20261001
umask 077
test ! -e "$FIXTURE_PRIVATE/service-logs"
mkdir -m 700 "$FIXTURE_PRIVATE/service-logs"
python3 - <<'PY_UNITS'
import json, os, pathlib, shutil
os.umask(0o077)
env = os.environ
services = []
for kind, checkout, state, tls, sock in [
    ('core', 'OWNED_CORE_CHECKOUT', 'OWNED_CORE_STATE', 'CORE_TLS_DIR', 'CORE_SOCKET'),
    ('switch', 'OWNED_SWITCH_CHECKOUT', 'OWNED_SWITCH_STATE', 'SWITCH_TLS_DIR', 'SWITCH_SOCKET'),
    ('fault', 'OWNED_CORE_CHECKOUT', 'OWNED_CORE_STATE', 'CORE_TLS_DIR', 'FAULT_SOCKET')]:
    services.append(dict(kind=kind, checkout=env[checkout], state=env[state],
                         tlsDir=env[tls], socketPath=env[sock]))
config = dict(scope='isolated-fictional-fixture', runId=env['FIXTURE_RUN_ID'],
              node=os.path.realpath(shutil.which('node')),
              logDir=env['FIXTURE_PRIVATE'] + '/service-logs', services=services)
with (pathlib.Path(env['FIXTURE_PRIVATE']) / 'infrastructure.json').open('x') as f:
    json.dump(config, f, indent=2)
PY_UNITS
node "$FIXTURE_CHECKOUT/scripts/fixture-service-supervisor.mjs" \
  "$FIXTURE_PRIVATE/infrastructure.json" start
node "$FIXTURE_CHECKOUT/scripts/fixture-service-supervisor.mjs" \
  "$FIXTURE_PRIVATE/infrastructure.json" status
```

Use effective Docker access and the documented Node22 PATH. The helper imports
each owning checkout's unchanged guard, refuses occupied ports/IPC paths/units/
logs, verifies unit syntax and waits for listeners. It creates owned mode0600
files under ~/.config/systemd/user without enabling them at boot. Each unit has
Restart=no, UMask=0077, KillMode=control-group and a12-hour maximum. Logs append
privately; bridge metadata excludes OTPs, queries, headers and bodies. Capture
exact unit names in the mobile config's managedUnits and keep them running for
the entire plan. Explicitly disarm a newly started relay and verify DISARMED
before normal reads. Never silently restart a dependency during a test.

A successful `systemctl start` means the process was launched; it does not
mean Node has created its IPC socket. After initial start or an explicit
pre-plan restart, run this bounded readiness check before sending control
commands or freezing the plan. It checks only the three configured owned
services, refuses a stopped/restarted service or unsafe socket, and disarms the
relay after all listeners and IPC paths are ready. It neither restarts services
nor sends an OTP. Keep the unchanged owning guards and full mobile preflight.

```bash
export FIXTURE_INFRASTRUCTURE="$FIXTURE_PRIVATE/infrastructure.json"
python3 - <<'PY_READY'
import json, os, pathlib, socket, stat, subprocess, time
cfg = json.loads(pathlib.Path(os.environ['FIXTURE_INFRASTRUCTURE']).read_text())
assert cfg['scope'] == 'isolated-fictional-fixture'
ports = {'core': 18443, 'switch': 18444, 'fault': 18643}
deadline = time.monotonic() + 30
while True:
    ready = True
    for service in cfg['services']:
        unit = 'warehouse-fixture-' + service['kind'] + '-' + cfg['runId'] + '.service'
        result = subprocess.run(['systemctl', '--user', 'show', unit,
            '--property=ActiveState,SubState,MainPID,Restart,NRestarts,KillMode'],
            capture_output=True, text=True, timeout=5, check=True)
        props = dict(line.split('=', 1) for line in result.stdout.splitlines())
        assert props['ActiveState'] == 'active' and props['SubState'] == 'running'
        assert int(props['MainPID']) > 0 and props['Restart'] == 'no'
        assert props['NRestarts'] == '0' and props['KillMode'] == 'control-group'
        path = pathlib.Path(service['socketPath'])
        try:
            st = path.lstat()
            assert stat.S_ISSOCK(st.st_mode) and st.st_uid == os.getuid()
            assert st.st_mode & 0o077 == 0
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(1); client.connect(str(path))
            with socket.create_connection(('127.0.0.1', ports[service['kind']]), 1):
                pass
        except (FileNotFoundError, ConnectionRefusedError, socket.timeout):
            ready = False
    if ready:
        break
    assert time.monotonic() < deadline, 'Readiness deadline exceeded; preserve logs, stop pipeline'
    time.sleep(0.2)
fault = next(s['socketPath'] for s in cfg['services'] if s['kind'] == 'fault')
with socket.socket(socket.AF_UNIX) as client:
    client.settimeout(5); client.connect(fault)
    client.sendall(b'{"action":"disarm"}\n')
    response = b''
    while not response.endswith(b'\n'):
        part = client.recv(4096)
        assert part and len(response) < 8192
        response += part
    assert json.loads(response)['state'] == 'DISARMED'
print('PASS owned helpers, private IPC and listeners ready; relay DISARMED')
PY_READY
```

Ordinary stop/start works on these persistent, unenabled units:

```bash
systemctl --user stop "warehouse-fixture-core-$FIXTURE_RUN_ID.service"
systemctl --user start "warehouse-fixture-core-$FIXTURE_RUN_ID.service"
systemctl --user show "warehouse-fixture-core-$FIXTURE_RUN_ID.service" \
  --property=ActiveState,SubState,MainPID,NRestarts,Result
```

Use the corresponding switch/fault names when needed. Stop the test runner
before intentionally interrupting a dependency. On startup failure preserve
its printed phase, generated unit, private log and service journal. Correct the
reviewed generator and use new unit/log identities for a new attempt. The first
transient-unit stop/start failed because systemd discarded the stopped unit;
a first persistent attempt failed WorkingDirectory quoting. Both attempts are
retained. Real systemd syntax verification now runs before start.

After tests, stop the bridge first. Confirm its process and loopback18443
listener have stopped and its private IPC socket is gone before the next start.
Interrupting a wrapped terminal session can leave an owned stale socket; the
next bridge correctly refuses to replace it. If the recorded process is stopped
but the socket remains, this explicit cleanup refuses live listeners, other
owners, symlinks, unsafe permissions and a changed inode:

```bash
python3 - <<'PY_SOCKET'
import errno, os, socket, stat
from pathlib import Path
p = Path(os.environ['WAREHOUSE_FIXTURE_SOCKET'])
assert p.is_absolute() and p.resolve() == p and p.name == 'fixture-otp.sock'
parent = p.parent.stat()
assert parent.st_uid == os.getuid() and parent.st_mode & 0o077 == 0
if not p.exists():
    print('Fixture socket already absent')
    raise SystemExit(0)
s = p.lstat()
assert stat.S_ISSOCK(s.st_mode) and s.st_uid == os.getuid()
assert s.st_mode & 0o777 == 0o600
for family, address in [(socket.AF_INET, ('127.0.0.1', 18443)),
                        (socket.AF_UNIX, str(p))]:
    with socket.socket(family, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        try:
            client.connect(address)
        except OSError as error:
            assert error.errno == errno.ECONNREFUSED, 'Listener stop is not proven'
        else:
            raise RuntimeError('Listener is active; preserve socket and inspect process')
assert p.lstat().st_ino == s.st_ino
p.unlink()
print('Removed the verified owned stale fixture socket')
PY_SOCKET
```

Then stop only this checkout's fixture services:

```bash
bash scripts/compose.sh --profile '*' down
```

Do not use `down -v`, delete state, prune Docker globally or stop the installed
warehouse. Retain failed attempts, private logs and state for review. A passed
fixture case closes only its stated fictional scope.


## Current clean permission regression repeat

Reviewedd068d77 adds CustomerA/B known-staff-cache-key rejection to the core
acceptance script. It preserves the original guard and existing authorizer.
The same four HTTP probes already returned403 on fixture03 (private575);
execute the changed complete core script only on a newly owned disposable state.
A separate clean fixture05 attempt uses loopback18580/subnet10.233.246.0/24,
with fresh identity/JWT/password/database/storage and canonical fictional origin.
Its source/setup/core results are recorded in OPERATOR_SETUP_NOTES.md. These
parallel-fixture choices are declared overlays, not reuse of another state or
permission to run the gateway-IP regression expecting the original.245 subnet.
A second backend at the same fictional origin does not establish different-origin
mobile switching; that needs separate private TLS/routing and authenticated
artifact-scoped evidence.

## Read-only native overnight observations

After the separate native receipt/dispatch fault cases are reconciled, the mobile
UNATTENDED_RUN.md defines the current optional nine-block/eight-hour read plan.
New `scripts/fixture-soak-database.mjs` uses an explicitly read-only repeatable-read
transaction and the unchanged original core validator from the explicitly selected
WAREHOUSE_FIXTURE_CHECKOUT. Its private baseline compares reserved receipt
stocks/counts/saved invoice and records native administrator refresh-session
metadata without printing credentials. A review checkout does not own the running
fixture: the first relative-guard invocation correctly refused it, and that failed
attempt remains recorded. Explicitly select the owning checkout; never loosen the
validator or invoke these against an installed warehouse.

`scripts/fixture-soak-http.mjs` observes only that fixture's Kong logs since a
bounded timestamp. Raw lines (which may contain query credentials) remain in
memory; stdout contains only the two fixed RPC paths, status/counts. It requires
actual Orders RPC200, refuses observed5xx and reports401 separately. A cached
native screen alone cannot satisfy this check. Parser regressions and64 backend
unit checks PASS612; actual owned observations/business baseline comparisons PASS.
These tools do not alter warehouse records or establish production load capacity.
The native loop uses fresh explicit reads and background/cold persistence, checks
ANR/crash, and reconciles business state/session renewal without a new login.
The first run started2026-10-01T00:30:19IST and FAILED in block05 after all
three terminal-backed helpers disappeared. Four blocks passed; later blocks and
final reconciliation were NOT RUN. The failed ledger/44bindings and local backup
are retained. The corrected supervised new-state/new-TLS run remains pending
its new APK native gates. No blind resume or completed-write replay.
