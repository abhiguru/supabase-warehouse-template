# A second isolated fixture for authenticated server switching

Current status: backend setup/local doctor/independent pinned TLS/mock verifier
authentication PASS. Both installed fixture gateways now explicitly include the
reviewed Kong root DNS search correction7e3f66a34bb729d80e25c6a4a0975f072c05d03a;
private identity/config/guard hashes were preserved601. Code3013 clean native
authenticated round trip PASS602 and corrected GRN artifact code3014 passed the
full clean round trip610: fresh native verifier logins, secondary identity/profile/
empty caches/cold persistence, primary identity/data/cold persistence, without
Retry/ADB restart/ANR dismissal/human input. Earlier discovery timeout and Retry
recovery remain separate historical results596. Unsaved-form clearing and
same-origin identity replacement remain separate NOT TESTED cases. Overnight
plan is still being prepared; physical/provider evidence is not transferred.
Do not use the pilot or Test1 as a second fixture.

The original separate installation pinned
`a9a49863600dbb33935b49a721f3d406ede9302f`, later applying the exact declared258
Kong correction. New checkouts below pin258, which contains both changes.
Mobile42a5559b4abcad3ddd7601b2e4885e3c29101c76 includes independent CA tooling and
the cleared-number correction. The original core validator remains unchanged;
the separate strict switching validator requires its own exact fictional identity,
dummy provider, private state and running Compose ownership. Never run core
business scripts against this differently owned instance.

## Create the separate backend before changing emulator routing

Use new unused paths. Export the documented Node22 PATH in each terminal, and
ensure effective Docker access. These example suffixes are occupied on this VM;
another attempt must choose a fresh suffix and record it.

```bash
export PATH="$HOME/.local/opt/node-v22.23.3-linux-x64/bin:$PATH"
export SWITCH_CHECKOUT="$HOME/warehouse-switch-backend-2026093001"
export SWITCH_PRIVATE="$HOME/warehouse-switch-private-2026093001"
export WAREHOUSE_STATE_DIR="$HOME/warehouse-state/cross-instance-test-2026093001"
test ! -e "$SWITCH_CHECKOUT"
test ! -e "$SWITCH_PRIVATE"
test ! -e "$WAREHOUSE_STATE_DIR"
umask 077
mkdir -m 700 "$SWITCH_PRIVATE"
# Precreate each raw evidence log as0600 before using public-sourceumask022.
umask 022
git clone --branch codex/fresh-vm-operator-install \
  https://github.com/abhiguru/supabase-warehouse-template.git "$SWITCH_CHECKOUT"
cd "$SWITCH_CHECKOUT"
git checkout --detach 7e3f66a34bb729d80e25c6a4a0975f072c05d03a
npm ci
```

Use the same five-line dummy provider file from UNATTENDED_FIXTURE.md, newly
created0600 in SWITCH_PRIVATE. Do not copy another instance's credentials/state.
Inspect ss -ltn and Docker IPAM (null Config is empty). Require unused18590,
18444, VM loopback443, the chosen socket/unit name and subnet10.233.247.0/24.
Do not stop another owner or change occupied DNS. These .example.test names are
local emulator fixtures; no public DNS/tunnel is configured.

```bash
umask 077
cat > "$SWITCH_PRIVATE/provider.env" <<'PROVIDER'
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=isolated-no-delivery-key
MSG91_TEMPLATE_ID=000000000000000000000001
MSG91_PE_ID=0000000000000000001
MSG91_SENDER_ID=CITEST
PROVIDER
chmod 600 "$SWITCH_PRIVATE/provider.env"
node scripts/configure.mjs --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://backend-switch.example.test \
  --company 'Fictional Switching Warehouse' \
  --provider-env "$SWITCH_PRIVATE/provider.env"
python3 - <<'PORT'
import os, re
from pathlib import Path
p = Path(os.environ['WAREHOUSE_STATE_DIR']) / 'config/compose.env'
s, n = re.subn(r'^KONG_HTTP_PORT=18000$', 'KONG_HTTP_PORT=18590', p.read_text(), flags=re.M)
assert n == 1
p.write_text(s)
assert p.stat().st_mode & 0o077 == 0
PORT
```

In this fresh checkout only, add the following root networks block to
docker/docker-compose.override.yml, after checking that no root networks key
already exists. Record this local overlay separately from source HEAD.

```yaml
networks:
  default:
    ipam:
      config:
        - subnet: 10.233.247.0/24
```

Then run supported setup with fictional administrator919888888881 and display
name Switch Demo Administrator. Keep the documented WAREHOUSE_STATE_DIR export
for every subsequent process; a CLI --state-dir in an earlier process does not
set another process's environment.

```bash
bash setup.sh --operator --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://backend-switch.example.test \
  --company 'Fictional Switching Warehouse' \
  --provider-env "$SWITCH_PRIVATE/provider.env" \
  --admin-phone 919888888881 --admin-name 'Switch Demo Administrator'
node scripts/doctor.mjs --local
```

Use sg docker -c with the exported Node PATH where needed. Compare instance IDs
and private hashes against the primary: identity, PostgreSQL/JWT credentials,
database and storage must be independent. Do not print credential values.

## Independent TLS and mock delivery

Generate once in a new0700 TLS directory; never regenerate after a metadata-only
failure without preserving/reconciling the existing material.

```bash
mkdir -m 700 "$SWITCH_PRIVATE/tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 \
  -keyout "$SWITCH_PRIVATE/tls/fixture-key.pem" \
  -out "$SWITCH_PRIVATE/tls/fixture-ca.pem" \
  -subj '/CN=backend-switch.example.test' \
  -addext 'subjectAltName=DNS:backend-switch.example.test' \
  -addext 'basicConstraints=critical,CA:TRUE'
chmod 600 "$SWITCH_PRIVATE/tls/fixture-key.pem" "$SWITCH_PRIVATE/tls/fixture-ca.pem"
export WAREHOUSE_SWITCH_FIXTURE_TLS_DIR="$SWITCH_PRIVATE/tls"
export WAREHOUSE_SWITCH_FIXTURE_SOCKET="$SWITCH_PRIVATE/switch-otp.sock"
node scripts/switch-fixture-bridge.mjs
```

The bridge binds only127.0.0.1:18444. Only fictional phones ending881..884 in
its explicit allowlist can request a fresh cryptographic challenge. The primary
fixture phone is refused. Real backend OTP verification remains active; plaintext
codes stay in bridge memory/private0600 IPC and never HTTP/logs. No SMS worker or
provider is called. Stop the owned bridge normally and verify socket/listener
cleanup; never unlink a live socket.

## Route both canonical HTTPS origins without changing their identities

Backend configure intentionally rejects nondefault URL ports and replacement
origins. Preserve that rule. Primary emulator hostname remains127.0.0.1 with its
owned443→18443 ADB reverse. The second hostname uses the emulator's documented
[host loopback alias10.0.2.2](https://developer.android.com/studio/run/emulator-networking-address).
On this Ubuntu24.04 VM, privileged ports start at1024. After checking that
127.0.0.1:443 and both named units are absent, create a dedicated transient socket:

```bash
sudo -n systemd-run --unit=warehouse-switch-fixture-loopback \
  --description='Owned fictional switching fixture loopback TLS passthrough' \
  --socket-property=ListenStream=127.0.0.1:443 --socket-property=Accept=no \
  --property="User=$(id -un)" --property=NoNewPrivileges=yes \
  --property=ProtectSystem=strict --property=ProtectHome=yes --property=PrivateTmp=yes \
  /usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:18444
```

It passes encrypted TCP to the second bridge without reading/reusing TLS keys.
It binds loopback only, not VM LAN interfaces. It is not a timer and does not
persist across reboot. Ordinary stop:

```bash
sudo -n systemctl stop warehouse-switch-fixture-loopback.socket \
  warehouse-switch-fixture-loopback.service
```

Only in the explicitly owned disposable emulator, use the existing protected
hosts bind workflow from mobile OPERATOR_INSTALL_NOTES.md to retain these entries:

```text
127.0.0.1 backend-core.example.test
10.0.2.2 backend-switch.example.test
```

Preserve SELinux Enforcing and both private fixture identities. Do not edit VM
hosts/DNS, a physical phone, Test1's ingress or any production connector.

## Exact mobile artifact and native evidence

Historical code3012 trusted only the primary certificate. Its small artifact
blocker was fixed by clean build/audit/install of code3013, SHA256
`e809e0fc875788f4af0794da13e28d966e5a804f54e940421a9a4330d79d47b7`, from
sourcec4cb8d2 with the two independently owned public certificates. Use this
workflow to build a new dedicated fixture APK with both public certificates. Do not weaken TLS or attribute3012 evidence
to the new APK. The optional mobile tooling requires independent public keys and
exactly restricted domains; normal warehouse APKs and existing trust policies
are refused. From a new clean pinnedc4cb8d2 checkout, use the standard prerequisites,
identity and standalone x86_64 workflow, with these additions before prebuild:

```bash
export WAREHOUSE_ANDROID_PACKAGE=in.gurucold.warehouse.fixture
export WAREHOUSE_ANDROID_VERSION_CODE=2026093013
export WAREHOUSE_FIXTURE_CA=/private/primary/fixture-ca.pem
export WAREHOUSE_SWITCH_FIXTURE_CA="$SWITCH_PRIVATE/tls/fixture-ca.pem"
export WAREHOUSE_FIXTURE_MIN_VALID_HOURS=12
node scripts/prepare-emulator-fixture.mjs --check-certificate
# After Expo prebuild, before Gradle:
node scripts/prepare-emulator-fixture.mjs
```

The horizon must cover setup/run/margin for BOTH certificates. Audit signature,
package/version, both compiled exact-domain policies and certificate bytes using
actual optimized APK resource mappings. Keep keys, sessions, device serials and
raw evidence outside Git. Record new source pair, overlays, SHA256 and installed
APK readback. Then verify native manual selection, displayed different identity,
real verifier with mock delivery on each instance, session/cache/form clearing
and return to the primary; neither unauthenticated discovery nor shared origin
establishes authenticated switching. Current native partial results and the
failed first return probe are recorded above; no full clean switching acceptance
is claimed. Read mobile UNATTENDED_RUN.md for the bounded API30 snapshot
procedure: stock UIAutomator can fail global-idle capture during the OTP
countdown. Snapshot tooling does not change the app or verifier.
