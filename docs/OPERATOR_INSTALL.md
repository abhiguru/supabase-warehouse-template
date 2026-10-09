# Operator installation

One warehouse per installation: a fresh Linux x86-64 host or VM owns its
database, document storage, credentials and canonical HTTPS origin. The
installer writes every private file to a state directory outside the Git
checkout and never touches another installation. This guide is current for
`main`. What is still open before production use is tracked in the
[acceptance ledger](PRODUCTION_DEPENDENCIES.md); nothing recorded elsewhere
validates a new installation.

Sections: [host prerequisites](#host-prerequisites),
[private inputs](#private-inputs), [setup](#setup),
[authentication and OTP limits](#authentication-and-otp-limits),
[Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress),
[external doctor](#external-doctor), [first-use checks](#first-use-checks),
[ordinary operation](#ordinary-operation),
[rotate signing keys](#rotate-signing-keys),
[backup and restore](#backup-and-restore),
[rerun and upgrade](#rerun-and-upgrade),
[Windows host with Linux VM](#windows-host-with-linux-vm),
[troubleshooting](#troubleshooting).

## Host prerequisites

- Linux x86-64; Ubuntu 24.04 is the tested baseline. ARM64 is not supported.
- Docker Engine with the Compose v2 plugin, enabled at boot.
- Node.js 22.18 or newer with npm, Git, OpenSSL, `curl` and util-linux (`flock`).
- A non-root user in the `docker` group. Do not run setup as root and do not
  make the Docker socket world-writable.
- At least 10 GiB free on a persistent filesystem for the initial installation,
  plus capacity for the warehouse's data; the doctor enforces the minimum.
- A **USB drive formatted exFAT for backups** (an existing drive is fine; it is
  not reformatted). A backup on the same disk as the data does not survive loss
  of that disk; see [USB backup drive](#usb-backup-drive).
- `cloudflared` for the tunnel (installed in the ingress section).

Record the host before changing it (`cat /etc/os-release`, `uname -m`,
`free -h`, `df -h`, `docker ps`) so that an existing runtime is never removed
by accident.

### Ubuntu 24.04 sequence

Ubuntu's packaged Node 18 is too old. Install a user-owned Node 22 without
replacing the OS package, substituting the current 22.x release and verifying
it against Node's published checksum file:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssl util-linux xz-utils dnsutils
NODE=v22.23.3
mkdir -p "$HOME/.local/opt" "$HOME/.cache/warehouse-node-download"
cd "$HOME/.cache/warehouse-node-download"
curl -fSLO "https://nodejs.org/dist/$NODE/node-$NODE-linux-x64.tar.xz"
curl -fSLO "https://nodejs.org/dist/$NODE/SHASUMS256.txt"
grep " node-$NODE-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c -
tar -xJf "node-$NODE-linux-x64.tar.xz" -C "$HOME/.local/opt"
export PATH="$HOME/.local/opt/node-$NODE-linux-x64/bin:$PATH"
node --version && npm --version
```

Repeat the `PATH` export in every shell that runs setup, doctor, start or stop,
and add it to `~/.profile` so new logins see it. The checksum file comes from
Node's HTTPS site; this is not a release-signature verification.

Install Docker from [Docker's Ubuntu repository](https://docs.docker.com/engine/install/ubuntu/).
Select an available Compose **v2** plugin build explicitly; the unversioned
package can install a newer major that these scripts have not been tested with.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' | sudo tee /etc/apt/sources.list.d/docker.sources
sudo apt-get update
apt-cache madison docker-compose-plugin        # pick a 2.x build for the next line
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin=2.40.3-1~ubuntu.24.04~noble
sudo systemctl enable --now docker
sudo usermod -aG docker "$(id -un)"
```

Open a new login session (or `sg docker`), repeat the Node `PATH` export and
confirm `docker version`, `docker compose version` and `docker ps` work
without sudo.

Clone the repository with `umask 022` so that container service users can read
the bootstrap files; keep `umask 077` for private state and provider files. A
checkout cloned under 077 produces mode-0600 initialization SQL, and PostgreSQL
then fails its first start with `Permission denied` while still reporting a
healthy process.

```bash
(umask 022; git clone https://github.com/abhiguru/supabase-warehouse-template.git backend)
cd backend
```

The operator scripts use only Node's built-in modules; `npm ci` is needed only
to run the test suite.

## Private inputs

**State directory.** An empty absolute path outside the checkout, not reached
through a symlink, on the persistent filesystem, mode 0700 and owned by the
installation user. The installer builds the state next to its final path
(`<state>.installing-<random>`) and renames it into place, so the **parent**
directory must belong to the installation user as well. Create both, the
second command without `sudo`:

```bash
sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /srv/warehouse
install -d -m 0700 /srv/warehouse/acme
```

If you create only the leaf with `sudo install -d … /srv/warehouse/acme`, the
parent `/srv/warehouse` is created root-owned and setup stops with
`EACCES: permission denied, mkdir '/srv/warehouse/acme.installing-…'`
(see Troubleshooting).

**MSG91 provider file.** A mode-0600 file outside the checkout with exactly
these five keys. Values are unquoted and contain no whitespace, quotes,
backticks, backslashes, `$` or `#`:

```dotenv
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=replace-with-owned-key
MSG91_TEMPLATE_ID=replace-with-approved-flow-id
MSG91_PE_ID=replace-with-owned-entity-id
MSG91_SENDER_ID=replace-with-owned-sender-id
```

`MSG91_TEMPLATE_ID` is the MSG91 **Flow ID** (24 lowercase hex characters),
not the DLT template ID. `MSG91_PE_ID` is numeric and `MSG91_SENDER_ID` is six
uppercase alphanumerics; the installer validates all three. The Flow's variable
must be named exactly `OTP`. Do not copy a complete legacy `.env` into this
file: `SMS_PRODUCTION_MODE` and any other key are rejected. The OTP worker
accepts a request only after MSG91 confirms it; an accepted API response still
does not prove handset delivery, so test with an owned phone. Real credentials
are mandatory: there is no fixed-OTP or local delivery mode. Keep the file out
of shell history and version control, and include it in your encrypted
off-host backups.

**First administrator.** The 12-digit phone number with the `91` prefix
(prepend `91` to ten Indian digits) and a display name. The administrator is
created locally and must complete a real SMS login before receiving a session.

## Setup

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
export COMPOSE_PARALLEL_LIMIT=1          # optional: gentler startup on small VMs
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://warehouse.example.com \
  --company 'Example Cold Storage' \
  --provider-env /secure/warehouse-msg91.env \
  --admin-phone 91XXXXXXXXXX \
  --admin-name 'Warehouse Administrator'
node scripts/doctor.mjs --local
```

`setup.sh` checks the host (`doctor --host-preflight`), generates a unique
Compose project name, signing keys and `config/compose.env` (mode 0600) in the
state directory, takes the per-state operator lock, verifies the configuration
and gateway port (`doctor --preflight`), starts only the database, applies the
migration ledger, configures auth, SMS and storage, bootstraps the
administrator, starts every service with `--wait` and runs the local doctor.
The gateway listens on `127.0.0.1:18000` only; database, Studio, CUPS and
monitoring are never published.

Running the same command again is safe: a rerun preserves identity, keys,
database and stored files (see [rerun and upgrade](#rerun-and-upgrade)). Setup
refuses an existing administrator with a different phone, a state path through
a symlink or inside the checkout, a running project owned by another checkout,
and another operator command holding the lock. Private configuration belongs
outside the checkout; no source edit is needed for the documented installation.

## Authentication and OTP limits

Login is phone OTP only, delivered through MSG91. Customers who sign up stay
pending until an administrator approves them from Enrollment Review; staff and
administrators are created by an administrator. There is no create-user
screen: the person signs in once, an administrator approves them, and then
sets their role under Settings → Users → edit. Every accepted code request
is a real SMS billed by MSG91 (there is no test or fixed-OTP mode), so budget
for it: a full acceptance run with three roles, a restore and a key rotation
used about 24 codes. Limits enforced by the database:

- OTPs expire after 5 minutes.
- Per phone: 5 per hour and 20 per day, with a 60 s resend cooldown. The hourly
  and daily counters are **fixed windows**, not sliding ones: a window opens at
  the first request after the previous window has expired and lasts one hour
  (one day). A phone whose requests straddle a window boundary can therefore
  receive up to about ten codes within sixty minutes. A request refused for the
  window limit answers HTTP 429 "Too many OTP requests. Try again later."; one
  refused for the cooldown answers 429 "Please wait before requesting another
  OTP.". The window limit is checked first, and neither sends an SMS.
- Per client IP: 30 per hour, keyed on Cloudflare's `CF-Connecting-IP`.
- Warehouse-wide cap: `otp_global_hourly_cap` in
  `warehouse_security.auth_config` (default 300 per hour). Raise it with
  `UPDATE warehouse_security.auth_config SET value='500' WHERE key='otp_global_hourly_cap'`.
- A resend does not void the earlier code: every delivered code stays valid
  until its own expiry, the 5 wrong-attempt cap is shared across them, and a
  successful verification consumes all of them.
- Expired OTPs are cleaned up by `pg_cron`; sessions are HS256 JWTs signed with
  the instance's `JWT_SECRET`.

Disabling a user (`update_user_status(false)`) revokes their sessions; enabling
them again re-approves a disabled or rejected profile.

**Replacing MSG91 credentials.** Write the new values to a mode-0600 provider
file and rerun the same setup command with `--provider-env` pointing at it.
The rerun replaces only the `SMS_PROVIDER` and four `MSG91_*` lines of
`config/compose.env` (atomically, mode preserved), reports "Updated MSG91
provider settings in existing operator state.", recreates the database
container with the new environment and synchronizes the protected
`public.sms_config` row. Identity, paths and signing keys are untouched; an
unchanged provider file leaves the configuration byte-identical. Send yourself
a code afterwards.

## Cloudflare Tunnel ingress

Cloudflare Tunnel is the only supported ingress. The `cloudflared` connector on
the host is the sole path from the internet to the gateway on
`127.0.0.1:18000`; Cloudflare terminates TLS for the canonical origin given as
`--api-url`, so no certificate is installed locally. Kong trusts
`CF-Connecting-IP` only from that loopback hop and keys its per-client rate
limits on it. Do not place another reverse proxy (Caddy, nginx, Traefik) in
front of the gateway: it would not set the header, clients could supply their
own address and every phone would share one rate-limit budget.

Reference files with placeholders:
[deploy/cloudflared-config.example.yml](../deploy/cloudflared-config.example.yml)
and [deploy/warehouse-tunnel.service.example](../deploy/warehouse-tunnel.service.example).

Install `cloudflared` from [Cloudflare's package repository](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/#1-download-and-install-cloudflared):

```bash
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
cloudflared --version
```

Decide the hostname and the tunnel before routing anything:

1. Use the complete API hostname (for example `warehouse-api.example.com`),
   the same value as `--api-url`. Check its DNS and confirm nothing else
   serves it.
2. Use a tunnel dedicated to this host.
   [Cloudflare sends requests to any replica of a shared tunnel](https://developers.cloudflare.com/tunnel/configuration/#replicas-and-high-availability),
   so an occupied tunnel does not isolate this installation.
3. Choose [dashboard-managed](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
   (create the tunnel and a public hostname route to `http://127.0.0.1:18000`
   in the dashboard, store the connector token in a mode-0600 file, run
   `cloudflared tunnel run --token-file <path>`) or
   [locally managed](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/)
   (`cloudflared tunnel login` writes `cert.pem`; create a new named tunnel
   with its own JSON credentials; route only the confirmed hostname).

For a locally managed tunnel, after moving `cert.pem` into a mode-0700 private
directory:

```bash
cloudflared tunnel --origincert /private/path/cert.pem list --output json > /private/path/tunnels-before.json   # confirm the new name is unused
cloudflared tunnel --origincert /private/path/cert.pem create --credentials-file /private/path/new-tunnel.json NEW_TUNNEL_NAME
cloudflared tunnel --origincert /private/path/cert.pem route dns NEW_TUNNEL_UUID warehouse-api.example.com
```

Run `route dns` without `--overwrite-dns`; if it reports a conflict, inspect
that record instead of overwriting it. Never reuse, delete or clean up a tunnel
or connector that belongs to another machine. Keep every token, JSON
credential and account certificate mode 0600 in that private directory and out
of logs and unit files.

Copy the example config to a private path (mode 0600) and replace the tunnel
UUID, credentials path and hostname. It routes the hostname to
`http://127.0.0.1:18000` with `httpHostHeader` set to the hostname and ends
with an `http_status:404` catch-all; change the port only if the private
`compose.env` sets a different `KONG_HTTP_PORT`. `http2-origin` stays off
because [HTTP/2 to an origin requires HTTPS](https://developers.cloudflare.com/tunnel/reference/origin-parameters/)
and this origin is private HTTP. Validate with
`cloudflared --config /private/path/config.yml tunnel ingress validate` and
confirm the hostname's DNS record points to `<tunnel-uuid>.cfargotunnel.com`.
For a dashboard-managed tunnel the hostname and origin live in the dashboard
and the YAML is not used.

Make the connector a system service so it survives reboots: copy the example
unit to `/etc/systemd/system/warehouse-<instance>-tunnel.service` with an unused
unit name, set the user, group and config (or `--token-file`) path, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now warehouse-acme-tunnel.service
systemctl is-active warehouse-acme-tunnel.service
```

If the LAN router cannot hairpin to the public hostname, configure local DNS
for the same name; the app must always use the same HTTPS origin.

## External doctor

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs
```

The external doctor repeats the local health check, then fetches the public
configuration through the canonical origin (no redirects allowed) and verifies
that the anon key, instance ID and canonical origin it returns are this
installation's. Repeat it from warehouse Wi-Fi and from cellular data.
`doctor --local` covers the loopback gateway only; `--host-preflight` and
`--preflight` are the checks setup runs before touching anything.

If the external doctor reports `fetch failed` right after you routed the
hostname, check name resolution before suspecting the tunnel. A lookup made
*before* the route existed (for example the `dig` that confirms the name is
free) leaves an NXDOMAIN in the host's resolver cache for the zone's negative
TTL, up to 30 minutes on a Cloudflare zone, while the public internet already
resolves the name. Compare `dig +short <hostname> @1.1.1.1` with
`dig +short <hostname>`; `resolvectl flush-caches` helps on systemd-resolved
hosts, but an upstream router may cache the answer too. Once the name resolves
on the host the doctor passes.

## First-use checks

Install the companion app
([rn-warehouse-template](https://github.com/abhiguru/rn-warehouse-template)),
select this origin and confirm the company name it discovers. Then, with
fictional data and owned phones:

1. Sign in as the administrator with a real SMS code.
2. Create two fictional customers (Settings → Customers) and an item with a
   price (Settings → Items, Item Pricing). Sign up a customer login from a
   second phone; its login stays pending until you approve it from Enrollment
   Review, and the assignment list there is empty until customers exist.
   Approve it with an assignment to the first customer, sign in, and confirm
   it sees only that customer's records.
3. Create a staff account. There is no create-user screen: the person signs
   in once, you approve them, then set the role under Settings → Users → edit.
   As staff, create a goods receipt for the customer who is **not** assigned
   to that person (the app requires a photo of the GRN book entry), a partial
   and a final dispatch (a photo is optional and can only be attached while
   the dispatch is being created, not afterwards), and save the invoice:
   totals are computed by the server and staff see no price list.
4. Download the GRN, dispatch, invoice and stock PDFs as an authorized user;
   confirm an anonymous or foreign request is denied.
5. Disable a user (Settings → Users → edit → Account Status) and confirm login
   is refused (the code can still be requested, verification is rejected),
   then re-enable and sign in again.
6. Take a backup and verify it (below).

One phone is enough to exercise every role if you sign out and in again for
each, but each role needs its own number that can receive an SMS. To reuse a
number for the staff role, change that login's role only after the customer
checks are finished.

[INVOICE_RULES.md](INVOICE_RULES.md) and [STAFF_GRN_POLICY.md](STAFF_GRN_POLICY.md)
describe the expected behaviour. The fictional billing example there (subtotal
950, tax 48, total 998) holds only for its fixture dates: received on 1 April,
dispatched on 2 May, 31 billable days, so 1.5 periods. If you receive and
dispatch on the same day one period applies, and 100 bags at price 5, labour 2
and tax 5 % give 700 + 35 = **735**. Record what you tested.

## Ordinary operation

Use the installed checkout, the recorded state directory and a shell with
Node 22 and effective Docker access. The Compose wrapper refuses a running
project owned by another checkout.

```bash
cd /path/to/installed/backend
export PATH="$HOME/.local/opt/node-v22.23.3-linux-x64/bin:$PATH"
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash start.sh
node scripts/doctor.mjs --local
node scripts/doctor.mjs
bash scripts/compose.sh ps
# Stop this instance while preserving its data:
bash stop.sh
```

`compose ps` shows every service `Up (healthy)` except `rest`, which defines no
healthcheck and appears as plain `Up`; the doctor, not the status column, is
the health verdict.

Start and stop the tunnel service separately through its systemd unit. Do not
run `down -v`, a broad Docker prune, or delete state as a restart procedure.

Every operator command (`setup.sh`, `start.sh`, `stop.sh`, `rotate-keys.sh`,
`db:backup`, `db:restore`, `backup-disk.sh sync`, `test:recovery`,
`retention:*`, `test:gateway-dns`)
takes an exclusive per-state lock on `config/operator.lock` before touching
Docker. A second command for the same state fails immediately with "Another
operator command ... is running for this state." Wait for the first to finish;
never delete the lock file to force a run.

## Rotate signing keys

Rotate when the JWT secret, anon key or service key may have been exposed, when
a device or backup holding them leaves your control, or on a planned schedule.
Rotation is one explicit command for the installed checkout and state:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash rotate-keys.sh --yes
```

Without `--yes` the command prints a usage message, changes nothing and exits
with status 1. With `--yes` it takes the operator lock, requires a healthy
database, and then:

1. stages a copy of `config/compose.env` with a new 96-hex `JWT_SECRET` and
   newly signed `ANON_KEY` and `SERVICE_ROLE_KEY` (only those three lines change);
2. in one database transaction under advisory lock 71042: stores the new secret
   in `warehouse_security.auth_config`, deletes every refresh session, voids
   pending OTP challenges, removes the self-hosted Realtime tenant row so the
   recreated service re-seeds it with the new secret, and updates the database
   `app.settings.jwt_secret` setting. The secret reaches `psql` only on standard
   input, never as an argument;
3. renames the staged file over `config/compose.env` (mode 0600);
4. recreates the running key consumers (`db kong rest realtime storage functions
   studio`, plus `supavisor` when the pooler profile is running) with
   `--force-recreate --wait`, and runs `node scripts/doctor.mjs --local`.

Consequences: every signed-in device is logged out and must complete OTP login
again; any copied anon key is invalid and `get-public-config` advertises the
new one; the service key changes. A failure before step 3 leaves the file and
database untouched. If the process is interrupted between steps 2 and 3, the
database already holds a secret the file does not; rerun
`bash rotate-keys.sh --yes`, which stages and applies a newer secret end to
end. Take a fresh `db:backup` after rotation: earlier backups restore the
previous keys together with the previous database state and remain internally
consistent, but they no longer match the running instance.

Two things to expect afterwards. `doctor --local` passes at the end of the
command, but an external `doctor` run immediately afterwards can fail once with
a local-service message while the recreated services settle behind the tunnel;
rerun it after about thirty seconds. And already-open apps are not sent to the
login screen: their next requests are rejected with HTTP 401, and the current
client shows load errors or empty lists instead of prompting. Ask every user to
sign out (Settings → Sign Out) and sign in again after a rotation.

## Backup and restore

`npm run db:backup -- /absolute/destination` writes a private
`warehouse-backup-v4` directory (default `$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>`).
It stops ingress and every write-facing service for the capture and restarts
only the services that were running. The directory contains:

| File | Content |
| --- | --- |
| `database.dump` | `pg_dump --format=custom` of the `postgres` database **with owners** (needed by the in-place restore). |
| `_supabase.dump` | `pg_dump --format=custom` of the `_supabase` database (pooler and analytics schemas). |
| `storage.tar.gz` | The object storage directory, sorted, with fixed owner and mtime. File contents and the catalog are captured; filesystem extended attributes are not, so restored objects are served with the metadata recorded in the catalog. |
| `storage_objects.txt` | The `storage.objects` catalog as `<bucket>/<name>/<version>`, byte-ordered. |
| `integrity.txt` | Output of `scripts/backup-integrity.sql`: migration fingerprint, row counts, representative grants. |
| `roles.txt` | Cluster role names, so runtime-created roles can be recreated before ownership replays. |
| `compose.env`, `instance.json` | Private configuration and public manifest at backup time. |
| `metadata.txt`, `SHA256SUMS` | Format, timestamp, source commit and checksums of every file above. |

The backup is **unencrypted** and contains every credential of the instance.
Keep it mode 0700/0600 on protected storage. `db:backup` warns when the
destination shares a filesystem with `data/`: a backup on the same disk does not
survive loss of that disk. Copy every retained backup to an operator-provided
encrypted off-host destination; the acceptance ledger keeps encrypted off-host
custody, schedule and retention open. The `db-config` Docker volume (PostgreSQL
custom configuration and the pgsodium root key) is not part of the backup and
is preserved by `stop.sh`; never use `down -v` on a production instance.
Optional CUPS and monitoring volumes are not in this core backup.

`npm run db:verify-restore -- /path/to/backup` accepts v1 to v4 backups. It
checks every checksum, rejects absolute paths, `..` segments and links in the
storage archive, proves that every catalogued object is a file in the archive
(extra files are reported as a warning), restores both dumps into a disposable
`--network none` container on tmpfs with `--exit-on-error`, replays the archived
ACLs, and compares the integrity report and the restored object catalog with
the backup. Run it against every retained backup; it never touches the installed
instance.

### USB backup drive

A backup on the same disk as `data/` is lost with it, which is why `db:backup`
warns. Pilot installs copy every backup to a **USB drive formatted exFAT**,
which the operator attaches; exFAT is readable by a Linux host and by the Linux
VM of a [Windows host](#windows-host-with-linux-vm), so a restore works on
either. The drive is never partitioned or formatted, and other files on it are
left alone; backups go under `warehouse-backups/<state name>/` as one `.tar`
archive (file modes kept inside) plus a `.tar.sha256` file per backup.

The operator's job is to **attach the drive**: plug it in (on VMware also
connect it to the VM under Removable Devices, and confirm with
`lsblk -o NAME,TRAN,FSTYPE,MOUNTPOINTS` that it shows `usb` and `exfat`), then
leave it until the copy finishes. The copy, verification and unmount are run
for the operator: today by the installer, with the procedure in
[DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md#usb-backup-drive) (fresh
`db:backup`, archive, read back from the drive, `db:verify-restore` on the
newest copy, unmount); an automatic run on attach is planned. Do not unplug
during a copy; a dropped USB connection leaves only a `.partial` file and the
next run starts that backup again.

The archives are **not encrypted** and contain `compose.env`, which holds every
credential of the instance. Keep the drive locked away, and if it is ever lost
run `./rotate-keys.sh --yes` and take a new backup. A drive kept on site is
local custody only; taking it (or a second drive in rotation) to another
location is what protects against loss of the host, theft or fire.

To restore on a fresh install, attach the drive, check the archive with
`sha256sum -c <name>.tar.sha256`, extract it into
`$WAREHOUSE_STATE_DIR/backups/`, run `db:verify-restore` on it and then follow
[In-place restore of the same instance](#in-place-restore-of-the-same-instance).

### Backup disk

Alternative to the USB drive for hosts with a spare internal disk; new installs
should use the [USB backup drive](#usb-backup-drive).
The protection here is a **second, empty disk** used only for backups.
`scripts/backup-disk.sh` prepares that disk and copies verified backups onto it;
`db:backup` itself is unchanged. A partition carved out of the system disk is
deliberately not offered, because it would not survive failure of that disk,
and the helper never shrinks, resizes or wipes anything.

A second disk is **local custody only**. A separate physical drive (or, on a
hypervisor, a disk on a different datastore) protects against failure of the
data disk. It does not protect against loss of the host or datastore, theft,
fire, or ransomware that reaches the guest; only an encrypted off-host copy
does, and the acceptance ledger keeps that open.

1. Attach an empty disk (VMware: VM settings, add a hard disk, preferably on a
   different datastore or drive; cloud: create and attach a volume; hardware:
   install a drive), then rescan or reboot. It must be blank: no partitions, no
   filesystem or other signature, not mounted.
2. Look first. These commands are read-only and run as the installation user:

   ```bash
   cd /path/to/installed/backend
   export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
   bash scripts/backup-disk.sh status
   bash scripts/backup-disk.sh plan                      # lists eligible disks
   bash scripts/backup-disk.sh plan --device /dev/sdb    # shows exactly what apply would do
   ```

   `plan` prints the apply command with the confirmation value taken from the
   disk itself (its serial number, or its exact size when it reports none).
   With no eligible second disk it stops with "No second disk found".
3. Prepare the disk. This is the only destructive command and the only one that
   needs root. It never escalates by itself; run it through `sudo` from the
   installation user so the disk is owned by that user and not by root:

   ```bash
   sudo bash scripts/backup-disk.sh apply --device /dev/sdb --yes --confirm-serial SERIAL
   ```

   It refuses the system disk and any disk that holds the operator data; any
   disk with a partition, filesystem, LVM, RAID, swap or encryption signature,
   or even an empty partition table; mounted, removable or read-only disks; and
   disks smaller than 10 GiB or twice the current data and backups. It creates
   one GPT partition with an ext4 filesystem labelled `warehouse-backup`,
   mounts it at `/srv/warehouse-backups` (owned by you, mode 0700), writes
   `.warehouse-backup-disk` there and appends one `UUID=… nofail` line to
   `/etc/fstab`, keeping a dated copy of the file. It re-checks the disk
   immediately before writing. Running it again on the prepared disk changes
   nothing. If it stops part way it says where and wipes nothing automatically;
   run `status` and clean up by hand only if you are sure.
4. Copy and verify, as the installation user, after every backup (including
   the one you take after a key rotation, which is the one that matches the
   running keys):

   ```bash
   npm run db:backup
   bash scripts/backup-disk.sh sync
   ```

   `sync` takes the operator lock and refuses unless `/srv/warehouse-backups`
   is a real mount of a different device than `data/` (an unmounted directory
   would quietly fill the system disk instead). It copies each backup to
   `/srv/warehouse-backups/<state name>/`, checks `SHA256SUMS` on the copy and
   runs `db:verify-restore` against it (`--skip-verify-restore` omits that
   step). It never overwrites or deletes anything: a corrupt existing copy is
   reported and left alone, and retention is manual.

The copies contain `compose.env`, which holds every credential of the instance,
so the disk itself must be physically controlled. `nofail` lets the host boot if
the disk is missing; `status` then reports it as not mounted and `sync` refuses
to write into the empty mount point.

### In-place restore of the same instance

`npm run db:restore -- --yes /path/to/backup` replaces the installed database
and stored objects with a v4 backup **of the same instance**. Restoring onto a
replacement host is not covered by this guide yet; the acceptance ledger keeps
it open.

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:verify-restore -- /path/to/backup
bash stop.sh
npm run db:restore -- --yes /path/to/backup   # add --restore-config if keys were rotated after the backup
bash start.sh
node scripts/doctor.mjs --local
```

A restore returns the instance to the moment of the backup: everything recorded
after it is gone. To rehearse a restore without losing current data, take a
fresh `db:backup` immediately beforehand and restore that one.

The restore refuses, without touching anything, unless all of the following hold:
`--yes` is given; no other operator command holds the state lock; `compose ps -q`
is empty (run `stop.sh` first); the backup is `warehouse-backup-v4`; the backup's
`instance.json` equals `public/instance.json`; the backup's `compose.env` equals
`config/compose.env`, or `--restore-config` is given and the backup names the
same project and state paths; and `db:verify-restore` passes for the backup.

It then moves `data/db` and `data/storage` to `data/db.pre-restore-<utc>` and
`data/storage.pre-restore-<utc>`, recreates both with mode 0700, extracts the
storage archive, optionally replaces `config/compose.env` (keeping
`config/compose.env.pre-restore-<utc>`), initializes a fresh cluster with
`compose up -d --wait db`, recreates missing roles from `roles.txt` as `NOLOGIN`,
recreates the `postgres` database from `template1` (the same template the
verifier restores into), replays `database.dump` by section with
`--exit-on-error` and the archived owners (event triggers are replayed last,
owned by the restoring superuser, because PostgreSQL requires a superuser owner
and the archived owner is not one in this image), repairs the pg_graphql
wrapper and replays ACLs exactly as the verifier does, recreates `_supabase`
the same way and restores `_supabase.dump`, re-asserts the database JWT
settings from `compose.env`, diffs `scripts/backup-integrity.sql` against the
backup's `integrity.txt`, runs `scripts/migrate.sh --operator` (a no-op unless
this checkout added migrations after the backup), starts every service with
`--wait` and runs `doctor --local`. Role passwords always come from the active
`compose.env`; the backup never contains them. Pass `--restore-config` only when
the keys in the backup are the ones the restored data was signed with, that is,
when `rotate-keys.sh` ran after the backup and the restored sessions must match
the old keys.

**Rollback.** The pre-restore directories are kept until the operator removes
them. If the restore fails or the restored instance is rejected:

```bash
bash stop.sh
rm -rf "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/storage"   # sudo may be required: PostgreSQL files belong to the container's postgres user
mv "$WAREHOUSE_STATE_DIR/data/db.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/data/db"
mv "$WAREHOUSE_STATE_DIR/data/storage.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/data/storage"
mv "$WAREHOUSE_STATE_DIR/config/compose.env.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/config/compose.env"   # only after --restore-config
bash start.sh
```

A failed restore prints this sequence with the actual paths. Remove the kept
directories only after the restored instance is accepted. They contain files
owned by the containers' users (PostgreSQL's data, and objects written by the
storage container), so removing them needs root; use the two exact paths the
restore printed, never a wildcard:

```bash
sudo rm -rf "$WAREHOUSE_STATE_DIR/data/db.pre-restore-<utc>" "$WAREHOUSE_STATE_DIR/data/storage.pre-restore-<utc>"
ls "$WAREHOUSE_STATE_DIR/data"   # only db and storage remain
```

## Rerun and upgrade

A rerun is the same `setup.sh --operator ...` command with the same inputs
against the same state directory. It regenerates nothing that already exists:
identity, signing keys, database, stored files, the administrator and the
provider lines are preserved (a different `--provider-env` file replaces only
the MSG91 lines). Run it a second time right after installation and compare
`public/instance.json` and the administrator record before and after.

To upgrade to a newer `main`:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup                      # prints the backup directory
npm run db:verify-restore -- "$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>"
bash scripts/backup-disk.sh sync       # only if you use a backup disk
git pull --ff-only
bash setup.sh --operator ...           # the same inputs as the installation
node scripts/doctor.mjs --local && node scripts/doctor.mjs
```

The rerun applies only the migrations the ledger has not seen (append-only and
checksum-verified; a changed applied file is refused) and recreates the
services whose definition changed. Read `CHANGELOG.md` for the release first:
a release that changes the mobile contract needs the matching app build. If
the upgraded instance is rejected, stop it and restore the pre-upgrade backup
with the in-place restore above.

## Windows host with Linux VM

Install the same Linux stack inside an x86-64 VM and keep its state on a durable
VM disk. For a Hyper-V host, configure automatic start and a graceful stop from
an elevated PowerShell session, substituting the actual VM name:

```powershell
Set-VM -Name WarehouseVM -AutomaticStartAction Start -AutomaticStopAction ShutDown
```

Expose only the tunnel connector from the VM. Reboot the Windows host without
logging in, then verify that the VM, Docker services, the tunnel service and
both doctor modes recover. A Windows USB printer queue shared to CUPS through
Samba is a separate physical acceptance path; check it after the same
unattended reboot. The start and stop settings are documented by
[Microsoft's Set-VM reference](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vm).
For VMware or another hypervisor use its own startup/shutdown procedure; a
successful guest reboot does not prove host autostart or USB reattachment.

## Troubleshooting

Service-level diagnostics (containers, logs, Kong, PostgREST, Gotenberg and
CUPS checks) are in [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Installation
problems seen so far and their causes:

- **`Another operator command ... is running for this state`** — a previous
  setup, start, backup or restore is still running, or was interrupted while
  holding `config/operator.lock`. Wait or inspect `ps`; never delete the lock
  file.
- **PostgreSQL restarts with `Permission denied` on first start** — the
  checkout was cloned under `umask 077`. Re-clone with `umask 022` into a new
  directory and use a fresh empty state; keep the failed state for diagnosis.
- **`Operator installation requires Linux x86-64` or `Missing prerequisite`** —
  `scripts/check-readiness.sh` refuses other architectures and missing
  `docker`, `node`, `npm`, `openssl` or `flock`; `doctor` additionally requires
  Node 22.18+, Compose v2 and a reachable Docker daemon.
- **`node: command not found` in a new terminal or a service** — the user-owned
  Node is only on `PATH` where it was exported; repeat the export and keep it
  in `~/.profile`.
- **`State directory must be mode 0700` / `must not use a symlink` / `outside
  this checkout`** — the doctor's path rules; create the directory as shown in
  [private inputs](#private-inputs).
- **Public-configuration reads take seconds; gateway logs show
  `rest.localdomain` SERVFAIL** — the host's DHCP search domain leaked into
  the gateway's resolver. `docker/docker-compose.yml` pins `dns_search: "."`
  for Kong; keep it, and do not change host DNS or extend client timeouts.
- **`EACCES: permission denied, mkdir '…/<name>.installing-…'` during setup** —
  the parent of the state directory (for example `/srv/warehouse`) is not owned
  by the installation user, typically because `sudo install -d` created it with
  the leaf. Run `sudo chown "$(id -un):$(id -gn)" /srv/warehouse`, keep it mode
  0755, and rerun the same setup command.
- **External doctor fails while `--local` passes** — the tunnel service is
  inactive, the DNS record does not point to `<tunnel-uuid>.cfargotunnel.com`,
  the route targets the wrong loopback port, the origin redirects, or the host
  cached an NXDOMAIN from a lookup made before the route existed (compare
  `dig +short <hostname> @1.1.1.1` with `dig +short <hostname>`; wait for the
  negative TTL or flush the resolver cache). Check `systemctl status` of the
  unit and `cloudflared ... tunnel ingress validate`. Right after a key rotation
  one failure is normal; rerun after about thirty seconds.
- **`backup-disk.sh`: `No second disk found`** — nothing but the system disk is
  attached. Attach an empty disk (see [Backup disk](#backup-disk)), rescan or
  reboot, and run `plan` again. The helper never offers a partition of the
  system disk.
- **`backup-disk.sh`: the disk `already carries a … signature` or `has a
  partition table`** — the helper only uses blank disks and never wipes. Inspect
  with `lsblk -f`; if you are certain the disk holds nothing you need, clear it
  yourself (for example `sudo wipefs -a /dev/sdX`) and run `plan` again.
- **`backup-disk.sh sync` or `status` says the mount point is not mounted, is
  missing its marker, or sits on the system disk** — the disk did not mount at
  boot (the fstab entry uses `nofail`). Run `bash scripts/backup-disk.sh status`,
  then `sudo mount /srv/warehouse-backups`. Never copy backups into an unmounted
  mount point: they would land on the system disk.
- **`apply stopped during: …`** — a step of `backup-disk.sh apply` failed after
  it had started writing. Nothing is undone or wiped automatically. Run
  `status` to see how far it got (a disk labelled `warehouse-backup` but not
  mounted is "partitioned but not finished") and finish or clean up by hand.
- **`An admin already exists with a different phone`** — the state directory
  belongs to another installation; use an empty one.
- **OTP accepted by the API but not received** — verify the Flow ID (not the
  DLT template ID), the `OTP` variable name and the sender/entity approval in
  the MSG91 console. The per-phone, per-IP and warehouse-wide caps above return
  an explicit refusal, not silence.
- **Compose reports a 5.x version** — the unversioned plugin package installed
  a newer major; install an available 2.x build as shown in the host sequence.
