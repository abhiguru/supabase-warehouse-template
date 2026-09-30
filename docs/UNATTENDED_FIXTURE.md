# Isolated unattended fixture sequence

This optional sequence was exercised on Ubuntu 24.04.3 x86_64, Node 22.23.3,
npm 10.9.9, Docker 29.8.1 and Compose 2.40.3 on 2026-09-30. Read
OPERATOR_INSTALL.md first. It creates fictional data and must run separately
from any installed warehouse. The production pilot and recovery host are excluded.
Recovery, printing, sensors and external delivery are not part of this sequence.

Use a clean checkout of reviewed backend
`ee5b4936e2aa644667fe617f79e2a48b2eb67bbb` (review PR #79), fetched from
`codex/fresh-vm-operator-install`. Record the full checked-out commit and any
local configuration overlay. Clone public source with umask 022. Use absolute,
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
git checkout --detach ee5b4936e2aa644667fe617f79e2a48b2eb67bbb
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

Current result: 48 unit tests, migrations, setup/doctor, core API, customer A/B
Realtime, final accounts/images, Studio, gateway CORS/size, upstream-IP replacement
and retention preview PASS. Container audit FAIL remains open. This run did not
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

Run the bridge in an owned foreground terminal and stop it with Ctrl+C. It
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

After tests, stop the bridge first, then only this checkout's fixture services:

```bash
bash scripts/compose.sh --profile '*' down
```

Do not use `down -v`, delete state, prune Docker globally or stop the installed
warehouse. Retain failed attempts, private logs and state for review. A passed
fixture case closes only its stated fictional scope.
