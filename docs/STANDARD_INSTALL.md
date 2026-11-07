# Standard install: one facility on Ubuntu 24.04

**Last tested:** not yet. This line names the release and date of the last run on a fresh Ubuntu 24.04 virtual machine, and is
filled in after that run ([RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)).

This is the short path for a technician: one facility, one dedicated Ubuntu 24.04 x86-64 machine, Cloudflare Tunnel, MSG91 sign-in
codes, Slack alerts, USB backups and the warehouse network fallback. It ends with the administrator signed in on a phone. It explains
nothing it does not need; the long guide, [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md), is the reference and is linked at each step.
Several facilities on one host, Windows (WSL2), sign-in through an association, the pooler, sensors and printing are not here:
see the reference.

Read "Before you start" in the [README](../README.md#before-you-start) first and have everything in it. Replace the values in
`UPPER_CASE` or `acme` and `warehouse.example.com` with the facility's own. Run every command as the installation user (a normal
user with `sudo`), never as root, unless the step says `sudo`.

**If the SMS registration (DLT) is not approved yet, stop after step 3 and come back.** Setup needs the approved MSG91 values; there
is no way around that.

## 1. Prepare Ubuntu

**Type** (the first block needs `sudo`):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssl util-linux xz-utils dnsutils tmux rsync
sudo timedatectl set-timezone Asia/Kolkata     # the facility's time zone
sudo timedatectl set-ntp true
NODE=v22.23.3                                   # the current 22.x release from nodejs.org
mkdir -p "$HOME/.local/opt" "$HOME/.cache/warehouse-node-download"
cd "$HOME/.cache/warehouse-node-download"
curl -fSLO "https://nodejs.org/dist/$NODE/node-$NODE-linux-x64.tar.xz"
curl -fSLO "https://nodejs.org/dist/$NODE/SHASUMS256.txt"
grep " node-$NODE-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c -
tar -xJf "node-$NODE-linux-x64.tar.xz" -C "$HOME/.local/opt"
echo "export PATH=\"\$HOME/.local/opt/node-$NODE-linux-x64/bin:\$PATH\"" >> ~/.profile
export PATH="$HOME/.local/opt/node-$NODE-linux-x64/bin:$PATH"
cd ~
```

Docker Engine from Docker's own repository (not Docker Desktop, not rootless Docker, not Ubuntu's `docker.io`):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' | sudo tee /etc/apt/sources.list.d/docker.sources
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$(id -un)"
```

Log out and log in again (or run `sg docker`), then:

```bash
node --version && docker version && docker compose version && docker ps
docker info --format '{{.OperatingSystem}} {{.SecurityOptions}}'
timedatectl
```

**You should see:** `node --version` prints v22.18 or newer; `docker ps` lists nothing but no error and no `sudo`; the
`docker info` line does not contain `Docker Desktop` or `rootless`; `timedatectl` shows `System clock synchronized: yes` and
your time zone.

**If it fails**
- `permission denied` on the Docker socket: you have not logged in again since `usermod`; log out and in.
- `node: command not found`: the `PATH` line is missing in this shell; repeat the `export` (every new login gets it from `~/.profile`).
- `docker info` shows Docker Desktop or rootless: stop here. The warehouse network fallback (step 7) needs Docker's normal network
  setup so that it sees each phone's own address; use a plain Docker Engine install on this machine.
- Under 4 vCPU, 8 GiB or 60 GB: setup only warns, but the database and backups are slow; see "Host prerequisites" in the
  [reference](OPERATOR_INSTALL.md#host-prerequisites).

## 2. Put the private files in place

All of these live outside the downloaded code, in a folder only you can read. Never paste a key or webhook into a command line.

**Type**

```bash
install -d -m 0700 "$HOME/warehouse-private"
cd "$HOME/warehouse-private"
(umask 077
cat > msg91.env <<'EOF'
SMS_PROVIDER=msg91
MSG91_AUTH_KEY=REPLACE_WITH_AUTH_KEY
MSG91_TEMPLATE_ID=REPLACE_WITH_FLOW_ID
MSG91_PE_ID=REPLACE_WITH_ENTITY_ID
MSG91_SENDER_ID=REPLACE_WITH_SENDER_ID
EOF
nano msg91.env                  # replace the four values; no spaces, quotes or $ #
echo 'https://hooks.slack.com/services/REPLACE_WITH_YOUR_WEBHOOK' > slack-webhook.txt
nano slack-webhook.txt          # the alert webhook, one line
)
# optional, one line each (skip a file you do not have):
#   (umask 077; echo 'https://hc-ping.com/REPLACE' > heartbeat-url.txt)    # outside heartbeat service
#   a letterhead banner: a JPEG or PNG of at most 2 MiB, copied to letterhead.png
ls -l
cd ~
```

The MSG91 values: the auth key, the Flow ID (24 lowercase hex characters, not the DLT template ID), the numeric entity ID and the
six-character sender ID ([Registering SMS with DLT](OPERATOR_INSTALL.md#registering-sms-with-dlt), [MSG91 provider file](OPERATOR_INSTALL.md#private-inputs)).
The Slack webhook is an incoming webhook of a Slack app ([MONITORING.md](MONITORING.md#alert-delivery)).

**You should see:** `ls -l` lists `msg91.env` and `slack-webhook.txt` (and any optional file) with `-rw-------` and your user name.

**If it fails**
- A file shows `-rw-r--r--`: `chmod 600 FILE`. Setup refuses private files that other users can read.
- Setup later says the provider file has a bad value: it names the key; the values may not contain whitespace, quotes, backticks,
  backslashes, `$` or `#`.

## 3. Download the newest release

**Type**

```bash
cd ~
(umask 022; git clone https://github.com/abhiguru/supabase-warehouse-template.git backend)
cd backend
(umask 022; git checkout --detach "$(git tag --list 'v[0-9]*' --sort=-v:refname | grep -v -- '-' | head -n 1)")
git describe --tags
```

`umask 022` matters: a checkout made under a stricter umask makes the database fail its first start.

**You should see:** `git describe --tags` prints a tag such as `v0.7.0` (the newest release, no `-rc` in it).

**If it fails**
- `git tag` prints nothing: the clone has no release tags; check the network and the address, then clone again.
- You were on `main` by mistake: `main` is development, not a release. Check out the tag as above.

## 4. Run setup

**Type** (sets the SMS limits too: 60 sends an hour and 300 a day for the whole facility; change the figures if the members need more)

```bash
cd ~/backend
sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /srv/warehouse
install -d -m 0700 /srv/warehouse/acme
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://warehouse.example.com \
  --company 'Example Cold Storage' \
  --provider-env "$HOME/warehouse-private/msg91.env" \
  --admin-phone 91XXXXXXXXXX \
  --admin-name 'Administrator Name' \
  --alert-webhook-file "$HOME/warehouse-private/slack-webhook.txt" \
  --heartbeat-url-file "$HOME/warehouse-private/heartbeat-url.txt" \
  --letterhead-file off \
  --sms-hourly-ceiling 60 \
  --sms-daily-ceiling 300
```

Leave out `--heartbeat-url-file` if you have none (the doctor then warns). Use `--letterhead-file "$HOME/warehouse-private/letterhead.png"`
instead of `off` for a letterhead. `--api-url` is the facility's permanent address and cannot be renamed later. It is the HTTPS
address only (no path, no port), and it must be the hostname you will route in step 6. Do not look the name up with `dig` or
`ping` before step 6.

It takes several minutes (it builds images and starts every service).

**You should see:** the last lines include `Operator services are healthy on the local gateway.`

**If it fails**
- The message names the problem and the option; fix it and run the same command again (a rerun is safe).
- `EACCES` on the state directory: the parent `/srv/warehouse` must belong to you (the `sudo install` line above).
- `Existing canonical origin differs`: a different `--api-url` than the first run; use the first one.
- Anything else: [TROUBLESHOOTING.md](TROUBLESHOOTING.md#installation-and-setup) and [Setup](OPERATOR_INSTALL.md#setup).

## 5. Check the local health

**Type**

```bash
cd ~/backend
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs --local
```

**You should see:** `Local operator services and gateway are healthy.` (an extra `Note:` line about a newer release is information
only; warnings above it are read in step 9's checks). A phone cannot reach the machine yet.

**If it fails**
- The message names the failing service; [Services won't start](TROUBLESHOOTING.md#services-wont-start) lists causes.
- A warning about the missing off-host copy is expected until step 8.

## 6. Connect the Cloudflare Tunnel

The hostname's domain must already be on your Cloudflare account. The setup of step 4 has already limited the SMS sends, which has to
be true before the address is public.

**Type** (`create` prints a login link: open it on any computer, sign in to Cloudflare and choose the domain that contains the hostname; the command waits)

```bash
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
cd ~/backend
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash scripts/tunnel.sh create
sudo bash scripts/tunnel.sh install-service --state "$WAREHOUSE_STATE_DIR"
bash scripts/tunnel.sh status
node scripts/doctor.mjs
```

**You should see:** `install-service` ends with `warehouse-<name>-tunnel.service is running from /srv/warehouse/acme/config/tunnel.`;
`tunnel.sh status` shows the service state `active`; `doctor` ends with `Local services and external HTTPS discovery are healthy.`

**If it fails**
- `create` refuses because `~/.cloudflared/cert.pem` exists: it is a leftover account certificate; `shred -u ~/.cloudflared/cert.pem` and run again.
- `create` stops with a DNS conflict, or creates `<hostname>.<other domain>`: you chose the wrong domain or the hostname already has a
  record; it names what to delete in the Cloudflare dashboard. Never overwrite another record.
- `doctor` says `fetch failed` right after the route exists, or answers `HTTP 403` or HTML: wait a few minutes first; then see
  [Tunnel and public address](TROUBLESHOOTING.md#tunnel-and-public-address) and
  [Cloudflare zone settings](OPERATOR_INSTALL.md#cloudflare-zone-settings) (Bot Fight Mode and "I'm Under Attack" break the app).
- More: [Cloudflare Tunnel ingress](OPERATOR_INSTALL.md#cloudflare-tunnel-ingress).

## 7. Turn on the warehouse network fallback

When the internet line is down, phones on the warehouse Wi-Fi use this machine's own address over plain http. Read what it exposes in
the [reference](OPERATOR_INSTALL.md#lan-fallback-plain-http-on-the-warehouse-network) before you decide; the Wi-Fi password must not be given
to visitors. The machine must be on the warehouse network with a private address.

**Type**

```bash
cd ~/backend
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash scripts/lan.sh on auto
bash scripts/lan.sh status
```

Then reserve this machine's address in the router (a DHCP reservation) and do not forward port 8080 on the router.

**You should see:** a line `LAN address for the app: http://192.168.x.x:8080` (your own address and the port printed), and
`lan.sh status` showing the same address and the container running.

**If it fails**
- It refuses an address that is not private, a port that something else holds, or says the host has no private address: the machine is
  not on the warehouse network.
- The router later gives the machine another address: run `bash scripts/lan.sh on auto` again
  ([the app says the LAN address is unreachable](TROUBLESHOOTING.md#the-app-says-the-lan-address-is-unreachable)).

## 8. Set up the USB backup drive and make the backup key copy

The install is **not finished until the backup key copy is made**, by a second person who keeps it away from this machine and from the
drive (a password manager, or paper kept elsewhere). If that person is not there, you can make the copy later with the same command, but
the encrypted backups cannot be written and the drive cannot be enrolled until you do.

**Type** (in a terminal on the machine itself or an interactive SSH session, not a one-shot command)

```bash
cd ~/backend
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash scripts/backup-key-escrow.sh show
```

Copy the key it prints and type it back when asked; then run `clear`. Then attach the USB drive (formatted exFAT) and find it:

```bash
lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS      # the partition must show usb and exfat, such as sdb1
sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR" --enroll /dev/sdb1
```

Unplug the drive and plug it in again (setup does not copy to a drive that is already attached), wait until it disappears from the
file manager or `lsblk` shows no mount point, then:

```bash
bash scripts/backup-usb.sh status
```

**You should see:** after the key is typed back correctly the command writes the confirmation record and tells you to clear the
terminal; `backup-usb.sh status` shows the enrolled drive and a last successful copy; the drive holds
`warehouse-backups/<name>/warehouse-<time>.tar.enc`.

**If it fails**
- `setup --enroll` refuses: the key copy is not confirmed; repeat `backup-key-escrow.sh show`.
- `drive too small: needs X, has Y`: use a larger drive (it needs about three archives plus about 5 GiB of saved images).
- Nothing was copied: the drive was already attached when setup ran; unplug and attach it again. Details and the
  run's own output: `journalctl -u 'warehouse-usb-backup@*' -n 50`, and [Backup, USB drive and restore](TROUBLESHOOTING.md#backup-usb-drive-and-restore).
- More: [USB backup drive](OPERATOR_INSTALL.md#usb-backup-drive) and [Backup key](OPERATOR_INSTALL.md#backup-key).

## 9. Install monitoring and the daily backup

**Type** (needs `sudo`; it must be run by the installation user itself, and names the state because `sudo` drops the environment)

```bash
cd ~/backend
sudo bash scripts/watch-timer.sh install --state /srv/warehouse/acme
bash scripts/watch-timer.sh status
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs
```

The daily backup runs at 02:30 in the machine's time zone (set in step 1).

**You should see:** `watch-timer.sh status` says `Timer: ... is installed for /srv/warehouse/acme.` and a daily timer with its time;
`doctor` ends with `... external HTTPS discovery are healthy.` and no warning about the timer, the off-host copy or the backup key.

**If it fails**
- It refuses because you ran `sudo` from another account: run it as the installation user ([Host prerequisites](OPERATOR_INSTALL.md#host-prerequisites)).
- `doctor` warns about the heartbeat: you left out `--heartbeat-url-file`; run step 4 again with it, or record the decision
  ([External heartbeat](MONITORING.md#external-heartbeat-the-dead-man-switch)).
- No Slack message after a while: see [MONITORING.md](MONITORING.md).

## 10. Install the app and sign in

**Type** (on the administrator's phone, Android 12 or newer, 4 GB of memory)

Install the app as the app repository's README describes ([Install the app](https://github.com/abhiguru/rn-warehouse-template#install-the-app)),
open it, tap **Choose your warehouse server**, enter `https://warehouse.example.com` (the `--api-url` of step 4), then sign in with the
administrator's mobile number and the SMS code that arrives.

**You should see:** the app shows the company name you gave (`Example Cold Storage`) and, after the code, the administrator's home screen.

**If it fails**
- The app cannot find the server: open the address in the phone's browser; if that fails, repeat step 6's `doctor`.
- No SMS: [SMS codes not arriving](TROUBLESHOOTING.md#sms-codes-not-arriving) (the DLT template and the Flow variable `OTP` are the usual cause).
- The code request is refused with 429: the SMS limit of step 4 was reached; wait or see
  [SMS spending ceiling](OPERATOR_INSTALL.md#authentication-and-otp-limits).

## 11. First-use checks, then done

Run the [First-use checks](OPERATOR_INSTALL.md#first-use-checks) with fictional data and owned phones. On the administrator's phone,
open Help, then Connection, stand on the warehouse Wi-Fi and tap **Check now**: it should show **Reachable** (the fallback address from
step 7).

**The owner now has:** a facility at `https://warehouse.example.com`, the administrator signed in, alerts and a daily backup, a USB
copy of the backups, and a confirmed copy of the backup key.

**Tell staff:** install the same app, choose the same address, sign in with their own mobile number; an administrator approves them in
the app. During an internet outage the app works on the warehouse Wi-Fi, but a phone that is not signed in cannot sign in.

## After the install

- **Upgrades:** `bash upgrade.sh vX.Y.Z` from the checkout, with `WAREHOUSE_STATE_DIR` set ([Rerun and upgrade](OPERATOR_INSTALL.md#rerun-and-upgrade)).
- **Backups:** plug the enrolled drive in; check with `bash scripts/backup-usb.sh status`
  ([USB backup drive](OPERATOR_INSTALL.md#usb-backup-drive)). Everything about restore is in [Backup and restore](OPERATOR_INSTALL.md#backup-and-restore).
- **Help:** [SUPPORT.md](../SUPPORT.md) (say your release, `git describe --tags`, and attach the output of `node scripts/doctor.mjs`).
