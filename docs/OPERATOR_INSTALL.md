# Operator installation

One warehouse per installation: a fresh Linux x86-64 host or VM owns its
database, document storage, credentials and canonical HTTPS origin. The
installer writes every private file to a state directory outside the Git
checkout and never touches another installation. This guide is current for
`main`; an installation runs a release tag, not `main` ([Rerun and upgrade](#rerun-and-upgrade)), so read the copy of this guide that
belongs to the tag you install (`git show vX.Y.Z:docs/OPERATOR_INSTALL.md`, or the file in the checkout after you have checked the tag
out). What is still open before production use is listed in
[PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md). When something goes wrong,
see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

Sections: [host prerequisites](#host-prerequisites),
[private inputs](#private-inputs), [setup](#setup),
[several facilities on one host](#several-facilities-on-one-host),
[authentication and OTP limits](#authentication-and-otp-limits),
[central sign-in](#central-sign-in),
[Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress),
[LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network),
[external doctor](#external-doctor), [first-use checks](#first-use-checks),
[ordinary operation](#ordinary-operation), [retention](#retention),
[rotate signing keys](#rotate-signing-keys),
[backup and restore](#backup-and-restore),
[rerun and upgrade](#rerun-and-upgrade),
[baseline reload](#baseline-reload) (what the refusals that name it mean),
[major PostgreSQL upgrade](#major-postgresql-upgrade) (a new PostgreSQL major is a manual move),
[Windows host (Ubuntu in WSL2)](#windows-host-ubuntu-in-wsl2).

## Host prerequisites

- Linux x86-64 with Docker Engine and the Compose plugin, enabled at boot; Ubuntu 24.04 is the tested baseline. ARM64 is
  not supported. The requirement is a Compose plugin whose `docker compose up` accepts
  `--wait-timeout`: setup, start and the backup scripts wait for services with it, and `doctor` stops with a message
  if the plugin does not know the flag. No version number is required. The central identity service states the same
  requirement, so one host can run both services. Tested with:
  - Docker Compose v2.40.3 with Docker Engine 29.9.1 (the review host; verified for
    this service and for the facility backend);
  - Docker Compose v5.6.0 with Docker Engine 29.9.1 (the development host; verified
    for this service and for the facility backend).
- Network access to `storage.googleapis.com` while the pdf-renderer image is built (it downloads Chrome headless shell).
- Node.js 22.18 or newer with npm, Git, OpenSSL, `curl` and util-linux (`flock`), and `dig` (package `dnsutils`).
- `rsync` and GNU `tar` (Ubuntu and Debian have `tar`; `rsync` is a package of its own): backups copy the stored photos with `rsync`
  and keep their extended attributes (the content type of each file), and `tar --xattrs` unpacks a backup archive. `setup.sh` and
  `db:restore-host` stop with the install command (`sudo apt-get install rsync`) when either is missing or when the `rsync` was built
  without extended attributes; `start.sh` and the other `doctor` runs only warn, so a host that has not installed `rsync` yet still
  starts its services (backups and restores then fail until it is installed).
- `tmux` (or another way to keep a process running after you log out) for the Expo development server of the app, if you
  run one on this host. The backend itself needs it for nothing.
- A non-root user in the `docker` group. Do not run setup as root or make the Docker socket world-writable.
- At least 10 GiB free on a persistent filesystem for the installation, plus capacity for the data. `setup.sh` refuses
  to start below 10 GiB. `start.sh` and `doctor` only warn below 10 GiB and refuse below 2 GiB, so a disk that has filled
  up since the install does not keep the facility down after a power cut ([Disk full](TROUBLESHOOTING.md#disk-full)).
  Size the disk for the data with the rule in [Disk space](#disk-space).
- Recommended for a real facility: a **USB drive formatted exFAT for backups** (an existing drive is fine; it is not
  reformatted) and `sudo` once to set up the automatic copy ([USB backup drive](#usb-backup-drive)). Setup does not need
  it; without one, `doctor` warns and the backups stay on the host, so copy them off the host yourself.
- `cloudflared` for the tunnel ([Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)).

Record the host before changing it (`cat /etc/os-release`, `uname -m`, `free -h`, `df -h`, `docker ps`) so that an existing
runtime is never removed by accident.

### Disk space

Size the disk under `$WAREHOUSE_STATE_DIR` for **at least 3 × the photos + 3 × the database + the Docker images + 20 %**, where the
photos are `data/storage`, the database is `data/db`, and the images are what Docker keeps for this installation (`docker system df`; the
copy that `build-images.sh` saves in `<state>/images` is about 2.5 GiB more, and the same again on a USB drive while it is replaced). The three copies are these: the live files; what the
backups hold besides them (**one full copy of the photos of their own**: a backup never links to the live files, only the nights'
backups link to each other, so an unchanged photo is stored once for all the nights, plus every photo that was changed or deleted since
the oldest night kept, plus one dump of the database for each night kept); and the second copy that the in-place restore writes next to
the data it keeps aside, which is the way back from an upgrade. `scripts/restore.sh` refuses to start unless the free space in `data/`
holds the stored files of the backup again plus 1 GiB, and the database is then replayed from the dump. Measure before you decide:

```bash
du -sh "$WAREHOUSE_STATE_DIR/data/db" "$WAREHOUSE_STATE_DIR/data/storage" "$WAREHOUSE_STATE_DIR/backups"; df -h "$WAREHOUSE_STATE_DIR"; docker system df
```

Two things tell you before it is too late. `bash upgrade.sh` refuses, before it changes anything, when the free space is below the stored
files of the newest verified backup plus the size of its database dump plus 1 GiB (its own way back would not fit; this is a minimum, the
photos added since and new images come on top), and the monitoring checker raises `restore_space_low` under the same rule every run, and
repeats it once a day ([MONITORING.md](MONITORING.md)). The photos grow with the facility: look again each year.

### Host time zone

Set the host's time zone before installing the monitoring timer. The time of the daily backup (`--daily-at`, default 02:30)
and the "Monitoring is alive" message after 09:00 are **host local time**, and a server image is usually set to UTC: the
backup would then start at 08:00 in India, in the middle of the working morning, with the API stopped while it runs.

```bash
timedatectl                                  # Time zone, and "System clock synchronized: yes"
timedatectl list-timezones | grep -i kolkata
sudo timedatectl set-timezone Asia/Kolkata   # the facility's zone
sudo timedatectl set-ntp true                # keep the clock right (central sign-in refuses a clock over 30 s off)
```

The timers follow the host zone without being installed again (`bash scripts/watch-timer.sh status` prints the zone). Check
the daily time after any change of zone, and tell the app's users nothing: only the backup time, the Slack lines and the
checker's dates move.

### Ubuntu 24.04 sequence

Ubuntu's packaged Node 18 is too old. Install a user-owned Node 22 without replacing the OS package (substitute the
current 22.x release; the checksum file comes from Node's HTTPS site, which is not a release-signature verification):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git openssl util-linux xz-utils dnsutils tmux rsync
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

Repeat the `PATH` export in every shell that runs setup, doctor, start or stop, and add it to `~/.profile`.

Install Docker from [Docker's Ubuntu repository](https://docs.docker.com/engine/install/ubuntu/). Any Compose plugin whose
`up` accepts `--wait-timeout` works; the commands below install the build the review verified. That build can leave the
repository's index later: if `apt-get install` cannot find `docker-compose-plugin=2.40.3-…`, take a current build from the
`apt-cache madison` list instead of stopping.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc\n' | sudo tee /etc/apt/sources.list.d/docker.sources
sudo apt-get update
apt-cache madison docker-compose-plugin        # lists the available builds
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin=2.40.3-1~ubuntu.24.04~noble
sudo systemctl enable --now docker
sudo usermod -aG docker "$(id -un)"
```

Open a new login session (or `sg docker`), repeat the Node `PATH` export and confirm `docker version`,
`docker compose version` and `docker ps` work without sudo.

Clone the repository with `umask 022` so that container service users can read the bootstrap files; keep `umask 077` for
private state and provider files. A checkout cloned under 077 makes PostgreSQL fail its first start with
`Permission denied` while still reporting a healthy process.

```bash
(umask 022; git clone https://github.com/abhiguru/supabase-warehouse-template.git backend)
cd backend
(umask 022; git checkout --detach vX.Y.Z)    # the newest release tag, from the GitHub releases page; main is development, not a release
```

The operator scripts use only Node's built-in modules; `npm ci` is needed only to run the test suite.

## Private inputs

**Gather these before running setup.** Each is explained below or in the section linked.

| Input | Setup option | Notes |
|---|---|---|
| State directory (and its parent) | `--state-dir` (required) | Absolute path outside the checkout, mode 0700, owned by the installation user; see **State directory** below. |
| Public API address | `--api-url` | HTTPS hostname of this facility (no path or port), such as `https://warehouse.example.com`. Required on a first install; the hostname must be routed by the tunnel below. |
| App origin | `--app-url` (optional) | HTTPS origin (no path or port) stored as the trusted browser origin. Leave it out and it is the `--api-url` origin. |
| Company name | `--company` | Display name of the facility, up to 120 characters. Required on a first install. |
| Cloudflare Tunnel | `scripts/tunnel.sh adopt` (needs the state, so after setup) | A **new** tunnel for this host with a route for the `--api-url` hostname: its `config.yml` with the credentials JSON, or a dashboard token file. Not a config copied from another machine. See [Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress). |
| MSG91 provider file | `--provider-env` | Mode-0600 file with five keys; see **MSG91 provider file** below. Required on a first install. |
| First administrator | `--admin-phone`, `--admin-name` (both required) | `91` and ten digits, and a display name; see **First administrator** below. |
| Slack webhook file | `--alert-webhook-file` | Private file with the facility's incoming-webhook URL. `off` only for a non-production install; without the option a terminal is asked and no terminal means setup refuses. See [Setup](#setup). |
| Central sign-in (members only) | `--central-issuer` with `--central-jwks-url` or `--central-jwks-file` | The issuer and the public key set (an address or a file) that the association gives you; see [Central sign-in](#central-sign-in). Leave out for SMS sign-in only. |
| PDF letterhead | `--letterhead-file` | A JPEG or PNG banner (at most 2 MiB) that the GRN, dispatch, invoice and customer stock PDFs print at the top, or `off` for plain PDFs. On a first install setup asks for it on a terminal (Enter means plain PDFs) and, with no terminal and without the option, refuses; a rerun without the option asks nothing and keeps what is there. See [Letterhead image](#letterhead-image-optional). |

**State directory.** An empty absolute path outside the checkout, not reached through a symlink, on the persistent
filesystem, mode 0700 and owned by the installation user. The installer builds the state next to its final path
(`<state>.installing-<random>`) and renames it into place, so the **parent** directory must belong to the installation user
as well. Create both, the second command without `sudo`:

```bash
sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" /srv/warehouse
install -d -m 0700 /srv/warehouse/acme
```

If you create only the leaf with `sudo install -d … /srv/warehouse/acme`, the parent is created root-owned and setup stops
with `EACCES` ([TROUBLESHOOTING.md](TROUBLESHOOTING.md#installation-and-setup)).

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

`MSG91_TEMPLATE_ID` is the MSG91 **Flow ID** (24 lowercase hex characters), not the DLT template ID. `MSG91_PE_ID` is
numeric and `MSG91_SENDER_ID` is six uppercase alphanumerics; the installer validates all three. The Flow's variable must
be named exactly `OTP`. Do not copy a complete `.env` into this file: `SMS_PRODUCTION_MODE` and any other key are
rejected. The OTP worker accepts a request only after MSG91 confirms it, but an accepted API response does not prove
handset delivery, so test with an owned phone. Real credentials are mandatory: there is no fixed-OTP or local delivery
mode. Keep the file out of shell history and version control, and include it in your encrypted off-host backups.

**What setup keeps for you.** This backend stores the sign-in codes itself, as an HMAC
(the `otp_verifications` table, checked by `operator_verify_otp`), and setup writes the `public.sms_config` row from the
provider file: do not create either by hand. `rotate-keys.sh` takes
only `--yes` and rotates the signing keys ([Rotate signing keys](#rotate-signing-keys)); it does not set up SMS.

**Test installations (CI, review fixtures).** An installation that is not a real facility never gets a real MSG91 key,
because every accepted code request is a real SMS. It uses the sentinel `MSG91_AUTH_KEY=isolated-no-delivery-key` (any
value that starts with `isolated-`) and an address under the reserved `.test`
domain, for example `https://backend-core.example.test`. The installer and the doctor accept the sentinel only for such an
address, and never accept the template text of this file's example (`your-…`, `changeme…`, `fake_…`). The OTP function
sends nothing to MSG91 when the key or the Flow ID is empty, template text or the sentinel (the same rule,
`scripts/provider-placeholder.mjs`). Do not rely on that alone: start a fixture's `functions` container
without a route to the internet (for example on an `internal: true` Compose network, or with a firewall rule for its
address) and prove it with a request from inside that must fail. Tests that need the provider's answer inject their own `fetch`.

A test installation also passes `--alert-webhook-file off` (no Slack channel exists for it; alerts stay on the host) and
`--letterhead-file off` (plain PDFs).
A real facility gives its own Slack webhook, see [Setup](#setup).

**First administrator.** The 12-digit phone number with the `91` prefix
(prepend `91` to ten Indian digits) and a display name. The administrator is
created locally and must complete a real SMS login before receiving a session.

## Setup

**Decide the public hostname before the first run.** `--api-url` becomes the installation's identity: a later run with another
`--api-url` stops with "Existing canonical origin differs; refusing to replace instance identity", and this guide has no rename
procedure. A real hostname also needs real provider values (see the test-installation rule below). Do not look the name up on
the LAN resolver before it is routed: a cached "does not exist" answer can keep it unresolvable for half an hour
([TROUBLESHOOTING.md](TROUBLESHOOTING.md#tunnel-and-public-address)).

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
export COMPOSE_PARALLEL_LIMIT=1          # optional: gentler startup on small VMs
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --api-url https://warehouse.example.com \
  --company 'Example Cold Storage' \
  --provider-env /secure/warehouse-msg91.env \
  --admin-phone 91XXXXXXXXXX \
  --admin-name 'Warehouse Administrator' \
  --alert-webhook-file /secure/warehouse-slack-webhook.txt \
  --letterhead-file /secure/letterhead.png        # or: --letterhead-file off (plain PDFs)
node scripts/doctor.mjs --local
```

`setup.sh` checks the host (`doctor --host-preflight`), generates a unique Compose project name, signing keys and
`config/compose.env` (mode 0600) in the state directory, takes the per-state operator lock, verifies the configuration and
gateway port (`doctor --preflight`), checks that Docker can create the internal renderer network (it stops before changing
anything when no address pool is free), starts only the database, applies the migration ledger, configures auth, SMS and
storage, bootstraps the administrator, starts every service with `--wait` and runs the local doctor. The gateway listens
on `127.0.0.1:18000` only; the database, CUPS and the sensor bridge are never published.

Optional services are Compose profiles that setup does not start: `printing`, `pooler`, `sensors` and `lan` (the [LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network), switched with `bash scripts/lan.sh on|off|status`; once it is on, setup and start bring it up too, apart from the services they wait for, so that a fault of the fallback is a warning and never stops them). The pooler is off by default and is switched with `bash scripts/pooler.sh on|off|status`, not with `--profile` (see [Pooler (optional)](#pooler-optional)); `sensors` is the Tapo sensor
bridge; set up as in [SENSORS.md](SENSORS.md#run-it-as-a-profile-of-the-installation), then
`node scripts/set-capability.mjs sensors on` and a new `db:backup`).

**Monitoring is not a Compose profile.** One small program, the checker (`scripts/watch.mjs`), runs from a systemd
timer every 5 minutes, tells the facility's Slack channel when something is wrong, and once a day makes and verifies a
backup and applies retention ([MONITORING.md](MONITORING.md)). Installing a unit needs root, which setup never uses, so
when it finishes it prints the command to run from the installation user's account (the same pattern as the tunnel
service and the USB backup drive):

```bash
sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"
```

Run it after every install, after a move of the checkout, and after `db:restore-host`; `start.sh` prints it when the timer
is missing, and `npm run doctor` warns when the timer is not active or the checker has not run in 15 minutes. The timer is
installed even with `--alert-webhook-file off`: the checks and the daily backup still run, only the Slack posts are off.

Alerts go to the facility's own Slack channel, so setup needs its incoming-webhook URL (the owner creates it in
Slack: Apps, Incoming Webhooks). Give `--alert-webhook-file /absolute/path` (a private file, mode 0600, one line), or
let setup ask for it on a terminal; without a terminal and without the option setup refuses.
`--alert-webhook-file off` is for a non-production install. The prompt, the test message, the stored file, the daily
"Monitoring is alive" message and muting before a planned stop are in [MONITORING.md](MONITORING.md).

The PDF letterhead is asked the same way: give `--letterhead-file /absolute/path` (a JPEG or PNG of at most 2 MiB) or
`--letterhead-file off` for plain PDFs, or let setup ask on a terminal (the path, or Enter for plain PDFs). Without a
terminal and without the option a first install refuses, so whoever runs setup for the installer has to ask them first
(see [Letterhead image](#letterhead-image-optional)).

Running the same command again is safe: a rerun preserves identity, keys, database and stored files
([rerun and upgrade](#rerun-and-upgrade)). Setup refuses an active administrator with a different phone, a state path
through a symlink or inside the checkout, a running project owned by another checkout, and another operator command
holding the lock. Private configuration belongs outside the checkout; no source edit is needed.

### Letterhead image (optional)

The GRN, dispatch, invoice and customer stock PDFs can print the facility's letterhead (logo, name and address as a picture) at the
top of the first page. The report PDFs are not changed. The choice is the installer's, so a first install always asks for it:

- **With the option.** `--letterhead-file /absolute/path/letterhead.png` uses that image; `--letterhead-file off` makes the PDFs plain.
  Nothing is asked.
- **On a terminal, without the option.** Setup asks for the path of a JPEG or PNG image (at most 2 MiB), or Enter for plain PDFs. A
  file that cannot be used is explained and asked for again, three tries in all; then setup refuses. `--letterhead-file ask` asks
  on a rerun as well.
- **No terminal (a script, or an agent running setup), without the option, on a first install.** Setup refuses before it changes
  anything: `Refusing: choose the PDF letterhead. Give --letterhead-file /absolute/path/letterhead.png (a JPEG or PNG of at most 2 MiB) ...,
  or --letterhead-file off for plain PDFs. Nothing was changed.` Ask the installer which they want and run it again with the option.
- **A rerun without the option** asks nothing and keeps what is there, so an unattended upgrade needs no change.

```bash
bash setup.sh --operator --state-dir "$WAREHOUSE_STATE_DIR" --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
  --letterhead-file /secure/letterhead.png
```

- **Format.** A JPEG or a PNG of at most 2 MiB; setup reads the file's first bytes, not its name, and refuses anything else (GIF, WebP,
  SVG, PDF, a renamed text file), a relative path or a larger file, and copies nothing. The image is scaled to the printable width of
  the A4 page (the page minus its side margins), so a wide, short banner works best: **2480 pixels wide** is the width of A4 at 300 dpi
  and is more than enough; a photograph of letterhead paper wastes the page. Save a photo-like picture as JPEG and a logo with flat
  colour as PNG to stay under 2 MiB.
- **Where it goes.** Setup copies it to `public/letterhead.jpg` or `public/letterhead.png` in the state (mode 0644) and records the name
  in `config/compose.env` as `LETTERHEAD_FILE`. Replacing the image needs no restart: the functions container reads the file when a PDF
  is made and notices a changed file.
- **Change or remove it.** Rerun `setup.sh --operator` with your usual inputs plus `--letterhead-file <new image>`, or
  `--letterhead-file off` for plain PDFs again. A rerun without the option keeps what is there. Switching between JPEG and PNG
  removes the old file.
- **Never a failed PDF.** If the file is missing, unreadable, too large or not an image, the PDF is made without it and the functions
  log one line (`letterhead: ...`). `npm run doctor` prints a warning, and the checker (`scripts/watch.mjs`) raises an alert
  "Letterhead image is missing or unusable", with the rerun command, while `LETTERHEAD_FILE` names a file that cannot be used.
- **Backups.** A backup carries the image (`letterhead.jpg` or `letterhead.png`, signed with the rest), `db:verify-restore` checks it,
  and `db:restore-host` puts it back. A backup made before this option has none and restores to plain PDFs.

### Document numbers

GRN, dispatch and invoice numbers follow a rule of the facility, and **with the rule's check on, a typed number that does not follow the rule is refused when the document is
saved** ("This number does not follow this facility's numbering (A####)"). Choose the rules at install, or later; an administrator can also change
them in the app (Document numbers, under Warehouse tools). Each rerun without the options keeps what is stored.

| Option | A rule is written as | Example numbers |
|---|---|---|
| `--grn-numbering`, `--dispatch-numbering` | `letters[,first=A][,digits=4][,per-letter=1000][,check=on\|off]` | A0001 ... A1000, B0001 ... With `first=W` or `first=X`: W, X, Y, Z, A, B ... (FAS's order) |
| | `year[,prefix=GRN/][,digits=4][,start=1][,check=on\|off]` | GRN/26-27/0001, starting again on every 1 April |
| | `sequence[,prefix=I][,digits=4][,start=1][,check=on\|off]` | I0001, I0002 ...; with `sequence,start=1001` no prefix: 1001, 1002 (a paper book kept going) |
| | `free` | any text of up to 20 characters, typed by hand (14/B/2027); nothing is suggested |
| `--invoice-numbering` | `year` or `sequence[,start=N]` | whole numbers: `year` starts again at 1 every 1 April (today), `sequence` keeps counting across years |

```bash
bash setup.sh --operator <your usual options> --grn-numbering 'year,prefix=GRN/' --dispatch-numbering 'sequence,prefix=I' --invoice-numbering year
```

- **The defaults:** GRN `letters` starting at A (A0001 ... A1000, B0001 ...), dispatch `sequence,prefix=I` (I0001, I0002 ...), invoice `year`, and every check on. `node scripts/doctor.mjs` prints the rules in force ("Document numbers: GRN A#### (letters), ...").
- **The check.** Each GRN and dispatch rule has a check: on, a number outside the rule is refused; off, it is saved (a number that is taken is still refused, as is one over 20 characters)
  and the rule still suggests the next number. A document type whose check is off (see fas-sync below) makes `doctor` warn "Dispatch numbers are not checked:
  N existing numbers do not follow I####" while numbers that do not follow the rule exist. Switch it on by giving the rule you want with `check=on`, for example
  `--dispatch-numbering sequence,prefix=I,digits=4,start=1,check=on` (the warning prints the exact option for the stored rule); numbers that do not follow it keep their numbers, and setup says
  how many they are. `check=off` switches it off. Giving a rule without `check` leaves the check as it is stored; `free` rules and invoices have no check to switch (an invoice number is always a whole number).
- **Limits.** A number has at most 20 characters and at most 7 digits after its prefix; the prefix is up to 10 capital letters, digits, `/` and `-`. Setup refuses an unknown scheme,
  other prefix characters, a number of digits outside 1 to 7, a number that cannot fit the 20 characters, and `letters` or `free` for invoices, before it changes anything.
- **A rule where documents exist.** Allowed. Existing numbers never change; setup prints "Next GRN: GRN/26-27/0001; 950 GRNs keep their numbers.". The lists sort the numbers of the earlier form first, then by
  the text before the trailing digits, then the digits as a number. Every change is kept, with who made it and the count, in `warehouse_security.document_numbering_history`.
- **What a rule accepts.** `letters`: any capital letter and at least `digits` digits (so FAS's X0001 ... Z1001 fit whatever the first letter; it decides only what is suggested. The suggestion follows the letters in use: the order of the letters always starts after the longest run of unused letters
  (of two runs of the same length, the one nearer the rule's first letter), so a facility whose books run W, X, Y, Z, A is offered A0258 after A0257 whatever its first letter. Only when all 26 letters are used is the series
  full: "All GRN numbers A0001-Z1000 are used", and the person types a number or an administrator changes the rule). `year`: the prefix, two consecutive years and the digits. `sequence`: the prefix and at least `digits` digits.
- **If the numbers you type do not fit.** Keep the check off, or choose a rule they fit. `free` accepts anything of up to 20 characters but suggests nothing. With the check on, a number outside the rule is not saved, whoever sends it.
- **A stray letter.** The GRN suggestion follows the letters in use; a mistyped GRN number such as Q0001 for A0001 can leave a letter beside the series that takes the suggestion over when it is between B and K (in a series that runs W to A; a stray at L does it only when
  the rule's first letter is W, because two runs of unused letters are then equally long). `doctor` lists "GRN letters in use outside the main series W–A: ..." (the main series is the run that holds the most numbers) so that the number
  can be corrected, and warns when the highest letter follows a letter in use that is not full (B0001 beside A0500), which is the one stray that steers the suggestion without standing apart.
- **fas-sync and other import tools.** A number the tool pushes that does not follow the rule is refused while the check is on: a GRN such as X1234A (a letter, digits and a letter after them) does not follow the letter rule.
  Before the first import, give setup `--grn-numbering letters,first=X,check=off` (`first=W` where the books hold both W and X numbers) and `--dispatch-numbering sequence,prefix=I,check=off`,
  and switch the checks on later with the same rule and `check=on`.
  It pushes FAS's GRN numbers (a capital letter and digits) and dispatch numbers as they are. At a facility whose GRN rule is `letters` those of a capital letter and digits are saved whatever the first letter. FAS's dispatch numbers (G1234,
  H0012A, CLR0007) do not follow `sequence,prefix=I`: while the dispatch check is off they are saved; with the check on, or with a GRN rule that does not match, the push of that document is
  refused with the sentence above. Do not use `free` to let them through: a `free` rule suggests no number, and fas-sync reads the suggestion (`get_next_grn_number`, `get_next_dispatch_number`) before and after every push. The suggestion is
  the rule's whether the check is on or off.
- **Slips.** Numbers of up to 20 characters are possible; the pre-printed GRN and dispatch slips print the number in a field made for 8, so check a long number on paper once before you use one.

## Several facilities on one host

One installation serves one facility: its own state directory, its own Compose
project (`warehouse-<instance id>`) and its own Cloudflare Tunnel. To run a
second facility on the same host, give it a separate state directory and its
own loopback gateway port with `--gateway-port` (1024 to 65535; the default is
18000):

```bash
bash setup.sh --operator --state-dir /srv/warehouse/second \
  --api-url https://backend-two.example.test --company 'Second Facility' \
  --provider-env /srv/warehouse/second-provider.env \
  --admin-phone 91XXXXXXXXXX --admin-name 'Second Administrator' \
  --alert-webhook-file /secure/second-slack-webhook.txt --letterhead-file off \
  --gateway-port 18001
```

- Setup test-binds `127.0.0.1:<port>` first and refuses a port that is in use. The port is saved as `GATEWAY_HTTP_PORT` in
  the state's `config/compose.env`; `doctor` and the smoke scripts read it from there.
- A rerun without `--gateway-port` keeps the saved port. A rerun with another port replaces only that line, and only while
  the installation's containers are stopped (`bash stop.sh`, then setup again).
- Each tunnel's ingress must point at its own port: change the `service:` line of that facility's `cloudflared`
  configuration to `http://127.0.0.1:<port>` and restart that tunnel
  ([Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)). Setup prints this reminder when it sets a port.
- **Give every facility a state directory with a different last part** (here `second`, not `state`).
  `scripts/tunnel.sh install-service` names the tunnel's systemd unit
  `warehouse-<last part of the state path>-tunnel.service`, so two facilities whose state paths end the same would share a
  unit name, and installing the second would replace the first one's unit.
- **The automatic USB backup serves one installation per host:** `/etc/warehouse-usb-backup.conf` holds one state path, and
  `backup-usb.sh setup` for a second state refuses with "already set up". Back the second facility up with
  `npm run db:backup -- /absolute/destination` (with that facility's `WAREHOUSE_STATE_DIR`) to a drive or directory of its
  own, and keep each facility's backup key separate.
- The host's Docker daemon and its resources are shared. Never point two installations at the same state directory or port.

## Authentication and OTP limits

Login is phone OTP only, delivered through MSG91. Customers who sign up stay
pending until an administrator approves them from Enrollment Review; staff and
administrators are created by an administrator. There is no create-user
screen: the person signs in once, an administrator approves them, and then
sets their role under Settings → Users → edit. Every accepted code request
is a real SMS billed by MSG91 (there is no test or fixed-OTP mode), so budget
for it. Limits enforced by the database:

- OTPs expire after 5 minutes.
- A code is stored only as a keyed hash, HMAC-SHA256 over `phone:code:request id`
  keyed with the instance's JWT secret (the `jwt_secret` entry of
  `warehouse_security.auth_config`), never as the code itself and never as a bare
  SHA-256 of it. A signing-key rotation changes that secret
  ([Rotate signing keys](#rotate-signing-keys)), so codes issued before it stop
  verifying and the user asks for a new one.
- A resend does not void the earlier code: every delivered code stays valid
  until its own expiry, and a successful verification consumes all of them.
- Expired OTP rows are not removed on a database timer, and not when a new code is issued. The 7-day `ephemeral_auth` retention
  rule deletes expired OTP rows older than 7 days (see [Retention](#retention)). That pass runs once a day from the daily timer
  (`watch.mjs daily`) when the timers are installed; without them, run `npm run retention:apply` yourself. Sessions are HS256 JWTs signed with the instance's `JWT_SECRET`.

Anyone can ask for a code for any number. The limits therefore have a fixed
order of priority: first, a code cannot be guessed more than five times;
second, one phone is not sent more than 30 SMS in 24 hours; third, inside
those two bounds, a stranger cannot keep a real user from signing in on a
network that user has signed in from before. A phone is **known** when it has
an approved, active profile; a **source** is the caller's address
(Cloudflare's `CF-Connecting-IP`); a source is **trusted** for a known phone
when a sign-in for that phone was completed from it in the last 90 days (the
last five such sources are kept).

| Limit | Value | Applies to | When it is reached |
| --- | --- | --- | --- |
| Per phone, all sends | `otp_phone_daily_cap`, default 30 in any 24 hours, every source and lane together | every phone | 429 "Too many OTP requests. Try again later." |
| Open lane | 5 per hour per phone, and the daily cap less the trusted reserve (30 − 10 = 20) in any 24 hours, shared by all sources that are not trusted | every request that is not from a trusted source | same 429 |
| Trusted lane | 5 per hour per phone and trusted source, up to the per-phone cap of 30; `otp_trusted_daily_reserve` (default 10) of the 30 cannot be used by other sources | known phones, from a trusted source | same 429 |
| Resend cooldown | 60 s per phone and source | every request | 429 "Please wait before requesting another OTP." with `retry_after_seconds` |
| Per source, sends | `otp_source_hourly_sends`, default 30 per hour over all phones; `otp_trusted_source_hourly_sends` (default 120) for the addresses you list in `otp_trusted_source_list` ([below](#the-facilitys-own-wi-fi-address)) | every request with a source | 429 "Too many OTP requests. Try again later." |
| Warehouse cap | `otp_global_hourly_cap`, default 300 per hour; text `0` is the no-send switch (below) | every request | same 429 |
| Provider requests | `otp_daily_provider_attempt_cap`, **off until you set it**: the most requests made to MSG91 in any 24 hours, a retry counted as a second request, a refused or timed-out one counted too | every request | same 429, and no SMS is sent |
| Unknown-number share | `otp_unknown_hourly_cap`, default 60 per hour, part of the warehouse cap | phones that are not known | same 429; known phones are still served |
| Wrong codes | 5 per issued code in all, from every source together; sources other than the one that requested the code share 2 of the 5 | every verification | 400 "Invalid or expired OTP" |
| Per source, failed verifications | `otp_source_hourly_failures`, default 20 per hour over all phones | every verification with a source | 429 "Too many OTP requests. Try again later." |
| New access requests | 3 per source and `enrollment_daily_cap` (default 30) for the warehouse, per 24 hours | a verified number that has no profile yet | No SMS is sent for a number that would exceed it (429 "Too many OTP requests..."); a verification that exceeds it answers 429 "Too many new access requests. Try again tomorrow." |

What this means in practice:

- The hourly open-lane counter is a **fixed window**: a window opens at the first
  request after the previous one has expired and lasts one hour, so a phone whose
  requests straddle a boundary can receive up to ten open-lane codes within sixty
  minutes. The 24 hour counts are sliding: each code stops counting 24 hours
  after it was requested. The limits are checked before the cooldown, and a
  refused request sends no SMS.
- No phone is sent more than 30 codes in any 24 hours, whoever asks. Of these,
  sources that are not trusted can cause at most 20.
- Someone who requests codes for the administrator's number uses up the open
  lane: 5 an hour, 20 in 24 hours. **While that goes on, the administrator can
  still get a code on a network they have signed in from before** (trusted
  lane, at least 10 in 24 hours that nobody else can use), **but may get none
  from a brand-new network** (a new SIM, a changed carrier address, another
  Wi-Fi) until the attack stops, the window passes, or the operator clears the
  phone's counters (next paragraph). The trusted sources of one phone share the
  reserve between them.
- Someone who guesses codes for another person's number can use up two of the
  five attempts of each code. The person who requested the code keeps at least
  three, as long as they verify from the address they requested it from. A
  phone that changes network between request and verification counts as
  another source and has the two shared attempts; requesting a new code on the
  new network gives the full five again.
- A caller who shares the user's public address (same Wi-Fi, or the same
  mobile-carrier gateway) is the same source and can use up that user's
  attempts, cooldown and trusted allowance, and a flood from many addresses can
  fill the warehouse cap. If either happens, add a Cloudflare WAF rate rule on
  `/functions/v1/operator-otp/request` and `/verify`. A facility whose staff
  all sit behind one public address (the yard Wi-Fi) shares the per-source
  limits too: list that address ([below](#the-facilitys-own-wi-fi-address)).

**Clearing one phone's counters.** When a user cannot get a code because
someone else has used up the limits of their number, run on the server (the
number is the user's 10-digit mobile):

```bash
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres \
  -c "SELECT warehouse_security.reset_otp_limits('9XXXXXXXXX')"
```

It prints how many counted codes it cleared and the user can request a code at
once; only `supabase_admin` may run it, no app role can. It clears the
per-phone counts only (not the per-source or warehouse limits, and not the
60 s cooldown), leaves codes already sent valid and keeps the phone's trusted
sources. If the requests continue, the limits fill again within the hour: put
the WAF rule in place first, then clear. Each clearing allows up to 30 further
SMS to that number. An address that has reached its per-source limit is not
cleared by this: its hour ends by itself (the count of an address restarts one
hour after its first request), or raise `otp_source_hourly_sends` or
[list the address](#the-facilitys-own-wi-fi-address).

- A send that MSG91 did not accept (outage, rejection) is not counted against
  the phone or the warehouse cap, so a provider outage does not lock users out.
  Two outcomes stay counted: a number MSG91 calls invalid, and a **timeout**
  (`provider_ambiguous`), because MSG91 may have accepted and billed the request
  before the answer was lost. The per-source count is kept either way.
- **Spend ceiling.** Those allowances count codes, not what MSG91 bills: a
  refunded send may still have cost a request, and one code can cost two
  requests (the function repeats a request once when MSG91 answers 429, 502, 503
  or 504 with an explicit error; it never repeats after a timeout). The database
  therefore also counts every request made to MSG91 for every code, whatever the
  outcome, in `warehouse_security.otp_provider_attempts` (kept two days, never
  refunded). To cap them, set `otp_daily_provider_attempt_cap` to the number of
  requests you are willing to pay for in 24 hours; when it is reached the
  request answers 429 and nothing is sent until older requests leave the 24-hour
  window or you raise it. It does not exist until you create it, and a value that
  is not a whole number means no ceiling:

  ```sql
  -- as supabase_admin: set, or change, the ceiling
  INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_daily_provider_attempt_cap','2000')
    ON CONFLICT(key) DO UPDATE SET value=excluded.value;
  -- read the ceiling back
  SELECT value FROM warehouse_security.auth_config WHERE key='otp_daily_provider_attempt_cap';
  -- requests made in the last 24 hours
  SELECT COALESCE(sum(attempts),0) FROM warehouse_security.otp_provider_attempts WHERE created_at>now()-interval '24 hours';
  -- remove the ceiling
  DELETE FROM warehouse_security.auth_config WHERE key='otp_daily_provider_attempt_cap';
  ```
- **No-send switch.** A cap of text `0` is accepted and blocks every send: set
  `otp_global_hourly_cap` to `0` to stop all SMS at once (every request answers
  429 and no code is created), then back to its value (default `300`) to resume.
  `otp_daily_provider_attempt_cap` set to `0` does the same.
- **What the facility keeps of MSG91's answer** (the contract the central
  identity service mirrors). A success answer carries MSG91's request ID in its
  `message`. The facility trims it, accepts 1 to 255 characters of
  `A-Z a-z 0-9 . _ : -`, and stores it in `otp_verifications.msg91_request_id`
  with `msg91_status` `success`. It lives in that sign-in row and goes with it
  (the cleanup bullet above; `retention:apply` removes it 7 days after the code
  expired). It is never returned to a client or written to a log, and nothing
  else of MSG91's answer is stored or logged. A success **without** such an ID (no message, a blank or non-text one, one over
  255 characters, other text) is still a success: the code is
  treated as sent and stays valid, no second SMS is sent, the status is
  `success_no_id` and the function logs the fixed line
  `operator-otp: MSG91 accepted a send without a request ID`. An answer whose
  `type` and `status` disagree (one says success, the other error) is not an
  acceptance: with HTTP 200 it is refused as `provider_invalid_response`, with a
  failing status as `provider_unavailable`, and it is not repeated.
  To count the sends without an ID in the last two days:

  ```sql
  SELECT count(*) FROM warehouse_security.otp_provider_attempts WHERE status='success_no_id';
  ```
- While the unknown-number share of the warehouse cap is used up, a known and
  an unknown number get different answers, so a caller can tell during that
  time whether a number is registered. A used-up open lane answers the same
  for both.
- The name typed by a new user is shown in Enrollment Review. Letters of any
  script, digits, spaces and `. , ' & ( ) / -` are kept, cut to 30 characters;
  a name with anything else (markup, a link) is stored as "New customer".

Change a cap with, for example,
`UPDATE warehouse_security.auth_config SET value='500' WHERE key='otp_global_hourly_cap'`
(as `supabase_admin`). The unknown-number share can never exceed the warehouse
cap. The trusted reserve can never exceed the per-phone cap; a reserve equal
to the cap closes the open lane, so only trusted sources get codes.

**Sessions.** The access token lives one hour (`JWT_EXP`); the app renews it
with a refresh token that is replaced at every renewal. A session lasts while
the person keeps using the app: each renewal moves its end to 30 days after the
renewal (`session_idle_seconds`, default 2592000, kept between 1 hour and 365
days), but never later than 90 days after the sign-in (`session_max_seconds`,
default 7776000, never below the idle time and at most 1095 days; a value that
is not a whole number means the default). So someone who opens the app at least
once a month is asked for an SMS code about every three months, and a lapse of
the SMS service (MSG91 balance, DLT header, KYC) does not sign the staff out
within a week. Someone who does not use the app for the idle
time signs in again with a code. Only an active, approved profile is extended;
any other active profile keeps the fixed 7 days of a new session. Change a value as
`supabase_admin` (`UPDATE warehouse_security.auth_config SET value='1209600'
WHERE key='session_idle_seconds'`); it applies at the next renewal, and a
session already past a lowered absolute limit is ended then (the app signs the
person in again). To go back to a fixed week, set both keys to `604800`. Setup
creates the keys once and does not reset a value you set. If the app repeats a
renewal within 60 seconds because the answer
was lost on a slow network, it receives the same new token again
(`refresh_grace_seconds` in `warehouse_security.auth_config`, 0 to 300). A
replaced refresh token that is presented later, or one from an earlier
generation, means two devices hold tokens of one session: the session is ended
for both and the user signs in again. The database log then carries
`Refresh token reuse: session ... revoked`. The database remembers each replaced
token for as long as the session can last (until 90 days after sign-in at the
longest, `session_max_seconds`), so a stolen token that was replaced is still
recognised when the real holder presents it weeks later, as long as the session
lives. The price is a few small rows per renewal, which go with the session.

**A lost or stolen phone.** A session lasts weeks, so do not wait for it to
end: switch the person off. An administrator (a supervisor can do it for anyone
who is not an administrator) opens Settings → Users → edit → Account Status and
switches the user off. That deletes every session of the person at once
(`update_user_status(false)`), so the phone is signed out on its next request,
whichever way the person signed in. When the person has a new phone, switch them
on again; they sign in there with a code. Nobody can switch off their own
account, and the last administrator cannot be switched off. So if the lost phone
is an administrator's own and no other administrator can do it, run
`bash rotate-keys.sh --yes` ([Rotate signing keys](#rotate-signing-keys)): it
deletes every session of the warehouse, so every user, the administrator
included, signs in again with a code.

Disabling a user (`update_user_status(false)`) revokes their sessions; enabling
them again re-activates a disabled profile. It does not approve a request: a pending
one answers ENROLLMENT_PENDING and a rejected one ENROLLMENT_REJECTED; an administrator's
"Review again" (`review_enrollment_again`) puts a rejected request back in Access requests.

**The last administrator.** The only active administrator cannot delete their
own account, and an administrator cannot be deactivated or given another role
when no other active administrator would remain. If a warehouse nevertheless
has no administrator who can sign in (for example one deleted before this
rule existed), rerun the setup command with `--admin-phone` and `--admin-name`:
when no approved, active administrator exists, setup makes the profile with
that phone an administrator again, or creates one. An existing profile keeps
its name. Setup still refuses to act when another administrator is active.

**Replacing MSG91 credentials.** Write the new values to a mode-0600 provider
file and rerun the same setup command with `--provider-env` pointing at it.
The rerun replaces only the `SMS_PROVIDER` and four `MSG91_*` lines of
`config/compose.env` (atomically, mode preserved), reports "Updated MSG91
provider settings in existing operator state.", recreates the database
container with the new environment and synchronizes the protected
`public.sms_config` row. Identity, paths and signing keys are untouched; an
unchanged provider file leaves the configuration byte-identical. Send yourself
a code afterwards.

### The facility's own Wi-Fi address

Every phone on the facility's Wi-Fi reaches the internet through one public
address, so the whole staff counts as **one source** for the per-source limits:
30 SMS requests and 20 failed verifications an hour. On a morning when many
people sign in together (after a [key rotation](#rotate-signing-keys), or when
sessions end together after a long SMS outage) the thirty-first request is
refused with "Too many OTP requests" for up to an hour. Tell the database
which addresses are yours and they get a higher send limit (`otp_trusted_source_hourly_sends`,
default 120 an hour; the limit that applies is the larger of it and
`otp_source_hourly_sends`). The list is the key `otp_trusted_source_list` in
`warehouse_security.auth_config`. It is a different thing from a phone's *trusted
sources* above (the table `warehouse_security.otp_trusted_sources`: the networks
a person signed in from, which only widen that one phone's allowance).

Find the address: on a phone on the facility Wi-Fi, open any "what is my IP
address" page (this is the address the Cloudflare edge sees as
`CF-Connecting-IP`). If the facility has IPv6, a phone may show an IPv6 address:
list the range that your provider gave you (usually a /64) as well. Then, as
`supabase_admin`:

```bash
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
-- addresses or CIDR ranges, comma separated; something that is not an address is ignored
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_trusted_source_list','203.0.113.45, 2001:db8:1234:5678::/64')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
-- optional: the limit for those addresses (default 120 an hour)
INSERT INTO warehouse_security.auth_config(key,value) VALUES ('otp_trusted_source_hourly_sends','120')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
SQL
```

It applies to the next request, no restart needed. Remove the list with
`DELETE FROM warehouse_security.auth_config WHERE key='otp_trusted_source_list'`.
A range may be no wider than /8 for an IPv4 address and /32 for an IPv6 one:
the database refuses to store a wider one (`0.0.0.0/0` or `::/0` would make the
whole internet a trusted source) and says so, and a wider range that got in some
other way is an error when the list is read, so requests for a code fail until
it is corrected.
The phone and warehouse limits above still apply to those addresses, and so do
the five wrong guesses per code; only the per-source send count is higher. The
ordinary limits are keys too: `otp_source_hourly_sends` (30) and
`otp_source_hourly_failures` (20; not higher for the listed addresses). Setup
creates these keys once and does not reset a value you set. List only an
address you control: anybody behind a listed address can ask for up to 120 SMS
an hour, which MSG91 bills.

### Break-glass administrator sign-in

When SMS does not work (the MSG91 balance is used up, the sender header is suspended, the provider is down) and nobody can get a code, the
operator can sign an **administrator** in without one. Once the administrator is in, they can approve or fix everything else from the app.
Sessions that are already open keep working ([Sessions](#authentication-and-otp-limits): they are renewed while used), so this is for the
person whose session has ended.

On the server, with the stack running:

```bash
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash scripts/break-glass-admin.sh 9XXXXXXXXX      # the administrator's 10-digit mobile number
```

It prints a six-digit code **once**, with the name of the administrator it belongs to and this warning: *this code signs in the admin
`<name>` on any phone within 10 minutes; use it only when SMS is down.* It refuses (and prints no code) when the number is not an active,
approved administrator (staff, a supervisor, a customer, a switched-off or pending account, a service account, an unknown number). The
command takes the operator lock like setup and backup do: if one of them is running it says so; wait for it and run it again. It prints the
code only to a terminal: run it in a terminal session on the server, not through a pipe, `tee`, a redirect or a logged wrapper (it
refuses with a message, and makes no code, when standard output is not a terminal; `--to-stdout` before the number overrides that on
purpose).

Learn it before the day it is needed: the `functions` container must be running the code of this checkout. `setup.sh` recreates it on
every run, and so does an upgrade with `upgrade.sh`. If you changed the checkout without running either, recreate it by hand
(`bash scripts/compose.sh up -d --force-recreate functions`, [Rerun and upgrade](#rerun-and-upgrade)); a stale `operator-otp` shows the app
"SMS delivery unavailable" and never its code screen when the provider refuses, and the break-glass code cannot be typed.

Give the code to that administrator in person or by a call you trust. On their phone: open the app, enter their number, ask for a code (the
app shows its code screen even while the SMS provider refuses the request, as long as the break-glass code is open), and type the break-glass
code instead of the SMS code.

**An administrator can sign in over the LAN fallback with a break-glass code.** An internet outage is exactly when SMS fails, so the
sign-in functions `operator-otp` (the request for a code and the verification) may be used over the
[LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network) as well: the provider cannot be reached (the name does not resolve, the
connection is refused or times out; it can take up to 10 seconds to give up), and while a break-glass code is open for that number the
request is answered "OTP sent successfully" anyway, as above, so the app reaches its code screen. Only that sign-in goes over the LAN: the
association's sign-in (`central-exchange`) needs the internet, and a phone that is not an administrator's gets "SMS delivery unavailable"
and cannot sign in until the line is back. The cost is the one of the fallback: the code crosses the Wi-Fi in clear. It is valid for
10 minutes and works once, so give it only to the administrator who is standing there, and make it just before it is typed.

Making the code also clears that number's own per-phone request counters (the same two statements as `reset_otp_limits`, [above](#authentication-and-otp-limits)),
because they fill during an SMS outage: a request the provider refused is not given back, so an administrator who tried five times before
calling is at the hourly limit and would be refused the code screen. It does **not** clear the limits of the address or of the warehouse.
If the code screen still answers "Too many OTP requests" ("Please wait before requesting another OTP" only means one minute between two
requests: wait and ask again):

1. **Use mobile data.** Switch the phone from the facility Wi-Fi to mobile data and ask again. On the day SMS stops, everybody on the Wi-Fi
   retries, and the Wi-Fi's one address reaches its per-address limit (30 requests an hour) and keeps it for up to an hour. List the Wi-Fi's
   address beforehand ([The facility's own Wi-Fi address](#the-facilitys-own-wi-fi-address)) and this is rarer.
2. **Check the warehouse switches.** `otp_global_hourly_cap` must not be `0` (the no-send switch) and `otp_daily_provider_attempt_cap` (required on a public installation)
   must not be used up (requests the provider refused count against it, and are never given back):

   ```bash
   bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c "SELECT key, value FROM warehouse_security.auth_config WHERE key IN ('otp_global_hourly_cap','otp_daily_provider_attempt_cap')"
   ```

The rules:

- It is valid for **10 minutes**, works **once**, and ends after **five wrong tries** from any address (run the command again for a new
  one; a new code ends the earlier open one of that number). It belongs to that number and that administrator: if the administrator is
  switched off or is no longer an administrator before it is used, it stops working.
- Nobody else can make one: the database function (`warehouse_security.break_glass_code`) can be executed by `supabase_admin` alone; no
  app role, the service role included, can call it or read its table. The code is stored only as a keyed hash (HMAC-SHA256 with the JWT
  secret, like the SMS codes).
- A break-glass sign-in opens a normal session (renewed like any other). It does not mark the number as verified by SMS and does not make
  the sign-in address a trusted source of the phone.
- Making a code and using one are each written to `public.audit_log` (kept 24 months: [audit_log retention](CONTAINER_SECURITY.md#audit_log-retention)); the code itself never is. To see them:

  ```sql
  SELECT created_at, action, new_data->>'name' AS administrator, ip_address
  FROM public.audit_log WHERE table_name = 'break_glass' ORDER BY created_at DESC LIMIT 20;
  -- CODE_ISSUED: an operator made a code. SIGN_IN: it was used (from ip_address).
  ```

  A `CODE_ISSUED` row with no `SIGN_IN` after it means the code expired unused; a `SIGN_IN` you did not expect means the code was shared.
- **What it does not cover: the association's sign-in.** Break-glass replaces this facility's own SMS code only. In the app with association
  sign-in, a facility that accepts association sign-in is reached through the association's sign-in: the app sends everyone who is not
  signed in to it first. If the association's service cannot send codes, a break-glass code cannot be typed anywhere, and only sessions that
  are still open (they slide, [Sessions](#authentication-and-otp-limits)) keep people in. With `--central-local-code on`, the break-glass
  code stands in for the facility's own code after a successful association sign-in, and for nothing else. So it covers a facility that
  uses its own SMS (MSG91) for sign-in, not an outage at the association's.
- It does not fix the SMS service: top up or repair MSG91 ([Replacing MSG91 credentials](#authentication-and-otp-limits)) and send yourself
  a code. Administrators who need no sign-in right now do not need a break-glass code.

## Central sign-in

Optional, and off by default. A member of the association can let people sign
in with the association's central identity service instead of an SMS code
sent by this facility. SMS sign-in keeps working. What you then rely on the
central service for, and what you do not, is the first section of
[CENTRAL_LOGIN.md](CENTRAL_LOGIN.md#what-the-facility-relies-on-the-central-service-for):
in short, it vouches that a phone number belongs to a central account; it
cannot approve anyone here, but its sign-in alone opens an existing person
profile with that number (administrators included) unless you switch on this
facility's own extra code, `--central-local-code on` below.

Turn it on with the issuer the association gives you and **one** source for
its public keys, added to the usual setup command (first installation or
rerun):

```bash
# keys fetched from the association
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
  --central-issuer https://login.association.example \
  --central-jwks-url https://login.association.example/.well-known/jwks.json

# or: keys from a file the association sent you
bash setup.sh --operator \
  --state-dir "$WAREHOUSE_STATE_DIR" \
  --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
  --central-issuer https://login.association.example \
  --central-jwks-file /secure/association-jwks.json
```

(On a first installation, the command also carries `--alert-webhook-file` and `--letterhead-file`, or setup asks for both on a terminal.)

- `--central-issuer` goes with exactly one of `--central-jwks-url` and `--central-jwks-file`. The issuer and the address
  must be `https://`; the issuer is stored exactly as typed, because it is compared with the token as a string.
- **Address or file?** With the address the functions container fetches the keys over HTTPS when a sign-in needs them, and
  a key the association rotates is picked up without you; if the container cannot reach it, central sign-in answers
  "temporarily unavailable" and SMS sign-in is unaffected. With the file nothing is fetched, but when the association
  rotates its keys it sends you the new file and you rerun the command with it; until you do, central sign-in fails and
  SMS sign-in still works.
- The file is checked (a JSON key set of at most 64 KB with at least one usable P-256 public key; a file that contains a
  private key is refused) and copied to `public/central-jwks.json` in the state directory; your original is not needed
  afterwards, and a rerun with the option replaces the copy. The running service reads it when it starts a worker for a
  sign-in; `bash stop.sh && bash start.sh` makes new keys certain.
- **If the association withdraws a signing key in an emergency:** with the address the facility refuses the withdrawn key
  within 300 seconds (a fetched key set is used for at most 4 minutes). With the **file** the withdrawn key stays trusted
  until you get the new key set from the association, rerun the command with `--central-jwks-file <new file>` and the same
  `--central-issuer`, and restart as above. Do this as soon as the association tells you.
- The settings are `CENTRAL_ISSUER`, `CENTRAL_JWKS_URL` and `CENTRAL_JWKS_FILE` in `config/compose.env`; setup also
  writes the issuer to the database. A later rerun without the central options keeps everything. Changing them recreates
  the functions container during that setup run; the database container is not touched.
- Turn it off with `--central-issuer off` (and no key option). People who signed in centrally keep their profiles and
  sessions; they sign in with an SMS code from then on.
- `--central-local-code on|off` (default **off**): with `on`, this facility also sends its own SMS code and asks for it at
  **every** new central sign-in, for every approved profile. Leave it off to let the association's single sign-in open this
  facility; the price is that whoever controls the central service, or a number's SMS there, can open any person profile
  with that number here. It is refused unless central sign-in is configured. A rerun without the flag keeps the stored
  value; `--central-issuer off` clears it with the rest. It is stored as `CENTRAL_LOCAL_CODE` in `config/compose.env` and
  as the `auth_config` key `central_local_code`. A service account (a machine) is never opened by the
  central sign-in whatever this says.
- Check: `curl -s https://<your origin>/functions/v1/get-public-config` shows
  `"centralLogin":{"issuer":"…","localCode":false}` when it is on (`localCode` is `true` with `--central-local-code on`)
  and `"centralLogin":null` when it is off or a value is unusable.

**Restores.** The trusted issuer lives in the database as well as in `compose.env`,
and setup is what makes the two agree. After an in-place restore of a database
made before you turned central sign-in on (or off), central sign-in answers
"not available" until you have run `setup.sh` again with your usual inputs.
`public/central-jwks.json` (public keys only) is copied into every backup as
`central-jwks.json`, covered by the signature, and `db:restore-host` puts it
back, mode 0644, with no setup run. A backup written before that holds no copy:
`db:restore-host` then ends by printing the exact `setup.sh --operator …
--central-issuer … --central-jwks-file …` rerun (keep the key set the
association sent you for that case). An in-place `db:restore --restore-config`
can bring back a `compose.env` that names a key file this state no longer has;
it finishes with a warning and prints the same rerun.

After any restore that brought back `central-jwks.json` (a copied key-set file
rather than `--central-jwks-url`), install the association's newest key-set
file before people sign in: rerun `setup.sh` with your usual inputs and
`--central-jwks-file <newest file>`. The restored copy is as old as the backup,
so it may still trust a key the association has since withdrawn, or lack the
key it signs with now. Ask the association for the current file and compare
the key ids with it.

`doctor` (`--local` and the full run) fails whenever `CENTRAL_JWKS_FILE` is set
and `public/central-jwks.json` is missing, not a regular file, larger than
64 KB, not JSON or without a usable P-256 key: without the file every central
sign-in fails while the app still offers it.

A person who already has a profile here is linked to the central account by
the first central sign-in with the same phone number (no code, unless the
facility's own code is on); approving, revoking and the one new
administrator action (unlinking a profile) are described in
[CENTRAL_LOGIN.md](CENTRAL_LOGIN.md#what-the-facility-administrator-does).

## Cloudflare Tunnel ingress

Cloudflare Tunnel is the only supported ingress. The `cloudflared` connector on
the host is the sole path from the internet to the gateway on
`127.0.0.1:18000`; Cloudflare terminates TLS for the canonical origin given as
`--api-url`, so no certificate is installed locally. The gateway (nginx) trusts
`CF-Connecting-IP` only from that loopback hop and keys its per-client rate
limits on it. Do not place another reverse proxy (Caddy, nginx, Traefik) in
front of the gateway: it would not set the header, clients could supply their
own address and every phone would share one rate-limit budget.

Reference file with placeholders:
[deploy/cloudflared-config.example.yml](../deploy/cloudflared-config.example.yml).
`scripts/tunnel.sh install-service` writes the systemd unit itself; it needs
`tunnel.sh create` or `tunnel.sh adopt` first (it stops with an error if the state holds no credential).

Install `cloudflared` from [Cloudflare's package repository](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/#1-download-and-install-cloudflared):

```bash
sudo install -m 0755 -d /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
printf 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main\n' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update && sudo apt-get install -y cloudflared
cloudflared --version
```

**The guided way: `tunnel.sh create`.** After `cloudflared` is installed and `setup.sh` has run, one command does the login, the
tunnel, the DNS route and the adoption into the state:

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash scripts/tunnel.sh create            # or: --name NAME (default: warehouse-<state name>)
sudo bash scripts/tunnel.sh install-service --state "$WAREHOUSE_STATE_DIR"
bash scripts/tunnel.sh status
```

`create` prints a login link: open it on any machine, sign in to Cloudflare and pick the domain that contains the hostname (a different domain would make Cloudflare create `<hostname>.<that domain>`, and `create` stops when it sees that); the command waits until you have.
It takes the hostname from this installation's `--api-url` (no hostname argument), refuses a tunnel name that already exists in
the account (it never reuses or deletes another tunnel), creates a new tunnel, routes the hostname to it **without**
`--overwrite-dns` (on a conflict it stops, names the new tunnel so you can delete it in the Cloudflare dashboard, and leaves the
existing record alone; after a later failure it tells you to delete the tunnel and the record in the dashboard), writes the config from the example with the gateway port from `compose.env`, validates it and adopts it.
The account certificate `cert.pem` is moved into a private temporary directory at once and shredded, with the credential copy and
config in that directory, when the command ends, on success or failure. It refuses if `~/.cloudflared/cert.pem` already exists
(shred it first) or if the installation already holds a tunnel credential. The sections below are the manual sequence
and the dashboard route, for when `create` does not fit.

Decide the hostname and the tunnel before routing anything:

1. Use the complete API hostname (for example `warehouse-api.example.com`), the same value as `--api-url`, which was fixed at the
   first [setup](#setup). Check its DNS and confirm nothing else serves it with `dig +short A <hostname> @1.1.1.1` only: a lookup
   through the LAN resolver before the route exists can cache "does not exist" for about half an hour
   ([TROUBLESHOOTING.md](TROUBLESHOOTING.md#tunnel-and-public-address)), and flushing the host's resolver does not clear a
   router's cache. Test a new name with `@1.1.1.1` or `curl --resolve`.
2. Use a tunnel dedicated to this host: [Cloudflare sends requests to any replica of a shared tunnel](https://developers.cloudflare.com/tunnel/configuration/#replicas-and-high-availability),
   so an occupied tunnel does not isolate this installation.
3. Choose [dashboard-managed](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
   (create the tunnel and a public hostname route to `http://127.0.0.1:18000` in the dashboard, store the connector token in
   a mode-0600 file) or [locally managed](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/)
   (`cloudflared tunnel login` writes `cert.pem`, always to `~/.cloudflared/cert.pem`, whatever `--origincert` says; on a host
   without a browser it prints a URL: open it on another machine and leave the command running until it reports success;
   create a new named tunnel with its own JSON credentials; route only the
   confirmed hostname). For a locally managed tunnel, after moving `cert.pem` into a mode-0700 private directory:

   ```bash
   cloudflared tunnel --origincert /private/path/cert.pem list --output json > /private/path/tunnels-before.json   # confirm the new name is unused
   cloudflared tunnel --origincert /private/path/cert.pem create --credentials-file /private/path/new-tunnel.json NEW_TUNNEL_NAME
   cloudflared tunnel --origincert /private/path/cert.pem route dns NEW_TUNNEL_UUID warehouse-api.example.com
   ```

Run `route dns` without `--overwrite-dns`; if it reports a conflict, inspect that record instead of overwriting it. Never
reuse, delete or clean up a tunnel or connector that belongs to another machine. Keep every token, JSON credential and
account certificate mode 0600 in that private directory and out of logs and unit files.

Copy the example config to a private path (mode 0600) and replace the tunnel
UUID, credentials path and hostname. It routes the hostname to
`http://127.0.0.1:18000` with `httpHostHeader` set to the hostname and ends
with an `http_status:404` catch-all; change the port only if the private
`compose.env` sets a different `GATEWAY_HTTP_PORT` (chosen with
`--gateway-port`, see [several facilities on one host](#several-facilities-on-one-host)). `http2-origin` stays off
because [HTTP/2 to an origin requires HTTPS](https://developers.cloudflare.com/tunnel/reference/origin-parameters/)
and this origin is private HTTP. Validate with
`cloudflared --config /private/path/config.yml tunnel ingress validate` and
confirm the hostname's DNS record points to `<tunnel-uuid>.cfargotunnel.com`.
For a dashboard-managed tunnel the hostname and origin live in the dashboard
and the YAML is not used.

**A tunnel makes the installation public, so cap the SMS first. Setting `otp_daily_provider_attempt_cap` is a required go-live step
for every installation that a phone number can reach from the internet.** Every accepted code request on a public address is a real,
billed SMS, test installations included. Set the cap
([Authentication and OTP limits](#authentication-and-otp-limits); it is off until you create it) before `install-service` below starts
the connector, read the value back, and never give a test
installation a real provider key ([Test installations](#private-inputs)). Stop the tunnel when a test ends.

**Keep the tunnel credential in the state, so backups carry it.** (`tunnel.sh create` already did this; the rest of this
paragraph is for a tunnel made by hand or in the dashboard.) Copy it into
the installation's state directory (`config/tunnel/`, mode 0700/0600) and make
the connector a system service that reads that copy and survives reboots:

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash scripts/tunnel.sh adopt --config /private/path/config.yml     # locally managed
# or: bash scripts/tunnel.sh adopt --token-file /private/path/tunnel.token   (dashboard)
sudo bash scripts/tunnel.sh install-service --state "$WAREHOUSE_STATE_DIR"
bash scripts/tunnel.sh status
```

`adopt` copies the config with its credentials JSON (rewriting the
`credentials-file:` path) or the token. It refuses the account certificate
(`cert.pem`, or a config with an `origincert:` line), which can create and
delete any tunnel or DNS record of the account and must never be in a backup,
and it refuses a config that does not route this installation's hostname.
`install-service` writes `/etc/systemd/system/warehouse-<state name>-tunnel.service`
(keeping a dated copy of an existing unit of that name), runs it as the user who
ran `sudo`, then enables and restarts it. From then on every backup, and every
USB copy, includes the credential, and
[restoring onto a new host](#recover-a-lost-host-from-the-usb-drive) brings the
public address back without a Cloudflare login. Once the service runs from the state copy you may delete the
old private copies of the config and credentials JSON, and you must delete **the account `cert.pem`**: `cloudflared tunnel login` wrote it to
`~/.cloudflared/cert.pem` as well as, or instead of, your private directory, and it can create and delete any tunnel and DNS
record of the whole Cloudflare account. Delete every copy as soon as the tunnel and its DNS route exist
(`shred -u ~/.cloudflared/cert.pem`, and the copy in your private directory), and check that none is left in the home folder,
in `/srv` or in `/root`.

To keep the credential out of backups instead, skip `adopt` and write the unit
by hand (a unit that runs as the installation user, not root (`User=` and `Group=`), with `ExecStart=/usr/bin/cloudflared --no-autoupdate --config <private config.yml> tunnel run`, or for a dashboard tunnel `ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token-file <private token file>`; never put `--token` on the command line; `sudo systemctl daemon-reload && sudo systemctl enable --now <unit>`); a
restore on a new host then needs your private copy or a new tunnel.

If the LAN router cannot hairpin to the public hostname, configure local DNS
for the same name; the app's own address is always this HTTPS origin. The only
other address a phone may use is the [LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network),
which it tries after this one has failed and never otherwise.

### Cloudflare zone settings

The API hostname is an ordinary hostname in a Cloudflare zone, and the zone's security settings apply to it. The phones run a
native app: it cannot solve a browser challenge, so a setting that challenges requests turns **every** app call into an HTML
page instead of JSON, and the whole facility stops until someone finds the setting. A change made for a website in the same
zone, by someone who never touches the warehouse server, is enough.

- **Best: give the API hostname a zone that serves nothing else**, so a change made for a website cannot reach it.
- **Bot Fight Mode must be off** (Security, Bots). On the free plan it can challenge API and mobile traffic, and a custom
  rule cannot skip it. If the zone must keep it on, move the API hostname to another zone.
- **"I'm Under Attack" mode breaks the app.** It challenges every visitor. If the zone needs it for a website, do not leave it
  on for the API hostname: add a **Configuration Rule** (Rules, Configuration Rules) for the hostname
  `warehouse-api.example.com` that sets Security Level to "Essentially Off" and Browser Integrity Check to off, and check
  that the rule is ordered above any rule that raises the level.
- Rate-limiting and firewall rules are optional ([Authentication and OTP limits](#authentication-and-otp-limits)); a rule that
  uses the action "Managed Challenge" or "Interactive Challenge" on this hostname does the same harm.
- **How you notice:** `public_https_down` fires with `HTTP 403` (a challenge is answered with status 403, which the check reports as it is), `node scripts/doctor.mjs --local`
  is healthy while `node scripts/doctor.mjs` fails, and
  `curl -sI https://warehouse-api.example.com/functions/v1/get-public-config` answers with a `cf-mitigated: challenge` header
  or a 403 page instead of JSON. Undo the setting; nothing on the host needs to change.

## LAN fallback (plain http on the warehouse network)

An internet outage stops the public path (the Cloudflare Tunnel) and, with it, the app on every phone, although the server and the
phones are on the same Wi-Fi. The LAN fallback gives the phones a second address for the same server: the server's own address on the
warehouse network, over **plain http**. The app is built to try the public address first and to use the LAN address only after the
public one has failed, and to return to the public address by itself when the internet is back. No
certificate, no DNS record and no router setting are involved; this is the one case in which the app uses cleartext.

**The app that uses it ships separately and is not released yet.** Until a version of the app that has it is installed on the phones,
turning the fallback on only opens the listener: nothing uses it, and the exposure below is not yet incurred, only the listener is there.
(The app's version number will be named here when it is released.)

- **What it is.** A second nginx container, `gateway-lan` (Compose profile `lan`, off by default), that is **the gateway's own image**
  (`docker/nginx`; it has no build of its own, so an upgrade that rebuilds the gateway rebuilds this too). It listens on port 8080 inside
  the container and is published on the host's **own private address** only (`LAN_BIND_IP:LAN_HTTP_PORT`). It has the same key check,
  body limits and rate limits as the public gateway, with differences that matter: it takes the client address from the connection,
  never from a header (the public gateway trusts the tunnel's `CF-Connecting-IP`), so the limits and the sign-in functions see each
  phone's own address; it answers the warehouse network only (`LAN_CIDR`); it answers only a request whose `Host` is the server's own
  LAN address (see below); and every answer carries `X-Warehouse-Path: lan`, which is how the app and `doctor` tell the two paths apart.
- **What it is not.** It is not a way to sign in with an SMS code or through the association: those need the internet, so a phone that
  is not signed in cannot sign in during an outage, with one exception: **an administrator can sign in over the LAN fallback with a
  break-glass code** ([Break-glass administrator sign-in](#break-glass-administrator-sign-in)). It does not publish anything to the
  internet, and the tunnel and the public gateway are unchanged (the public gateway has no LAN listener at all).
- **The exposure you accept.** While a phone uses this path, its access token (one hour) and any
  refresh token it exchanges cross the Wi-Fi **unencrypted**, and so do the photos and documents it sends and receives. Anybody who has
  the Wi-Fi password, or is on the network, can read them. That has these consequences:
  - **A token that is read works from anywhere, not only on the LAN**, including from the attacker's own mobile data during your outage,
    until it ends.
  - **A stolen refresh token keeps a session alive**: a thief who refreshes first keeps the session going (30 days idle, 90 at most)
    until the real phone presents the token it had; reuse detection then ends the session for both. The same mechanism lets anyone on
    the Wi-Fi **sign phones out during an outage**, when they cannot sign back in.
  - **Administrator tokens carry administrator rights.**
  - **A stale saved address can send tokens to another device**: if the host's address changes and a phone still holds the old one, the
    app is to check the address before it sends anything (and once a day while the internet is up), but a phone that was offline since
    the change has no way to know.
  - What stays in force: a refresh token is replaced at every use and a stolen one used beside the real phone ends that session (reuse
    detection), sessions are deleted when a person is deactivated, the LAN path is used only while the public path fails, the listener
    refuses every address outside `LAN_CIDR` and every `Host` but its own address, and it is published on that address only.
  Protect the Wi-Fi like a key: a strong password that visitors do not get (give them a guest network that cannot reach the server),
  and turn the fallback off with `bash scripts/lan.sh off` if the facility does not want this exposure. The full statement is in
  [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#lan-fallback-gateway-lan).

Steps (the stack must be running; the host needs a private address on the warehouse network):

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
bash scripts/lan.sh on auto        # the private address of the interface with the default route; or: bash scripts/lan.sh on 192.168.1.20
bash scripts/lan.sh status         # the address for the app, whether the host still has it, the container
bash scripts/lan.sh off            # removes the container and the variables
```

`on` takes `[<address>|auto] [--cidr <range>] [--port <n>]`. It refuses an address that is not private (10.x.x.x, 172.16-31.x.x,
192.168.x.x) or is not on an interface of this host, a range outside those blocks or without the host in it, a port outside
1024-65535, and a port something else holds (one held by this installation's own `gateway-lan` is fine, so it is safe to repeat; a rerun
that fails puts the earlier settings back and starts the service with them again). The range defaults to the network of the interface
(`192.168.1.0/24` for `192.168.1.20/24`) and the port to 8080, or to the one already set. It writes `LAN_ENABLED`, `LAN_BIND_IP`,
`LAN_HTTP_PORT`, `LAN_CIDR` and `COMPOSE_PROFILES=lan` (added beside any profile already listed) to `config/compose.env`, starts
`gateway-lan`, recreates the function runtime (a few seconds; it now offers the address to signed-in phones), runs the LAN checks of
`doctor` and prints, for example:

```
LAN fallback: 192.168.1.20:8080 on ens33, allowing 192.168.1.0/24
LAN address for the app: http://192.168.1.20:8080
The app that uses this address ships separately and is not released yet: until a version that has the fallback is installed on the phones, turning it on only opens the listener.
Allowed clients: 192.168.1.0/24. Once the app has it, phones use this address only when the public address fails; sign-in still needs the internet, except that an administrator can sign in over it with a break-glass code ...
Check one phone: on the warehouse Wi-Fi its address ... must be inside 192.168.1.0/24. ... Do not forward port 8080 on the router.
Host firewall: nothing to add. ufw rules, incoming or routed, do not apply to a port that Docker publishes ... The controls are the bind address (the container is published on 192.168.1.20 only) and the allow-list of the LAN server (192.168.1.0/24 only). ...
Reserve this address for the host in the router (DHCP reservation). ...
```

1. **Reserve the address.** Give the host a DHCP reservation in the router, so its address stays the same. If it changes anyway (a power
   cut and a new lease), the container cannot be published on the old one: `compose.sh` leaves the `lan` profile out of the command
   and says so, the public services start as usual, `bash scripts/lan.sh status` and `doctor` print a warning, and the checker alerts
   `lan_ip_changed` ([MONITORING.md](MONITORING.md)). Run `bash scripts/lan.sh on auto` again. The phones learn the new address the
   next time they connect over the internet (the app refreshes it from `get-config`); a phone that has been offline since the change
   cannot use the fallback until then.
2. **The firewall: there is nothing to add.** ufw does not see the traffic of a port that Docker publishes: Docker accepts it in its own
   rules first, so **no `ufw allow` or `ufw route` rule is needed, and none would have any effect** (that includes
   `ufw default deny routed`). The controls are the bind address (the container is published on that one address, not on every
   interface) and the allow-list inside the LAN server (that one network). A host that must filter Docker-published traffic itself does
   it in Docker's `DOCKER-USER` chain, where the packet's destination is already the container's; the example line is in
   [CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#lan-fallback-gateway-lan). Check that the router does not give guests or other VLANs
   a route to the host; a Wi-Fi with client isolation will not reach the server at all. **Do not forward `LAN_HTTP_PORT` on the
   router**: some routers re-address forwarded traffic to their own LAN address, which is inside `LAN_CIDR`.
3. **Check one phone.** `doctor` and `lan.sh` connect from the host, whose own address is always inside `LAN_CIDR`, so they cannot see
   a range that no phone is in (a narrow `--cidr`, a Wi-Fi on another subnet than the server's, an interface that is a /31 or /32: they
   warn about a range of fewer than 4 addresses). Look at the Wi-Fi details of one phone: its address must be inside `LAN_CIDR`
   (`bash scripts/lan.sh status` prints it). A phone outside it is answered `403` and never reaches the server. The app is to check the
   address while the internet is up and show the result in Settings, which is the check that tells before the outage.
4. **The server's address is the Host the phones write.** The listener answers only a request whose `Host` header is
   `LAN_BIND_IP` or `LAN_BIND_IP:LAN_HTTP_PORT` (anything else gets `404`), because the app addresses the server by its IP address.
   A browser, a `curl` that names the host by a DNS name, or a phone that was given a name for the server, gets 404: use the address
   `lan.sh status` prints.
5. **Reading the address.** `bash scripts/lan.sh status` and `node scripts/doctor.mjs --local` print `LAN address for the app: http://<address>:<port>`.
   The app is given it by the server (a signed-in phone has it after its next successful `get-config`); in Settings it shows the
   address and the path it is on, "Connected via: warehouse network" or "internet" (the app change ships separately, and the address can be typed there when the saved one is stale).
6. **Several facilities on one host** each need their own address or port: `--port` (the public gateway ports are loopback).
7. **Backups and restore.** `compose.env` is in every backup, so a restore brings the LAN lines back. On a new host that does not have
   the address, the guard above leaves the container out until you run `lan.sh on auto` there.
8. **Upgrades, key rotation and restarts.** `gateway-lan` is the gateway's image, so `setup.sh` and `upgrade.sh` rebuild and recreate both
   together. They (and `start.sh` and `restore.sh`) **never stop for the fallback**: they wait for the public services only and start
   `gateway-lan` afterwards on its own (`bash scripts/lan.sh start`), where a fault is a warning (the port is taken by another program,
   the container is unhealthy). `bash rotate-keys.sh --yes` recreates `gateway-lan` with the new keys; if that fails it says so and names
   the repair, because a container with the old keys refuses every REST request of every phone on the LAN path while the rest of the
   fallback looks fine. `doctor` and the checker send the installation's anon key to the LAN address to catch exactly that.
9. **Docker.** The fallback assumes a rootful Docker Engine with its iptables rules (the default), where a phone's packets keep their
   source address. Rootless Docker, `"iptables": false` and Docker Desktop do not, and `doctor --lan` warns about them and about a
   `LAN_CIDR` that overlaps one of Docker's own networks ([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#lan-fallback-gateway-lan)).

`node scripts/doctor.mjs --lan` runs only the LAN checks: the address is on this host, the container is published on that address and
nothing else, `http://<address>:<port>/functions/v1/get-public-config` answers from this host with this installation's `instanceId` and
`X-Warehouse-Path: lan`, and a REST request with this installation's anon key (`GET /rest/v1/`) is not refused by the gateway's key
check. `doctor --local` (what `start.sh`, `setup.sh` and `upgrade.sh` run) shows a fault of the fallback as a warning, so a router
problem or a taken port never stops a start or an upgrade; the full `node scripts/doctor.mjs` and `--lan` fail on it.
If it does not work, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-app-says-the-lan-address-is-unreachable).

## External doctor

```bash
export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
node scripts/doctor.mjs
```

The external doctor repeats the local health check, then fetches the public configuration through the canonical origin
(no redirects allowed) and verifies that the anon key, instance ID and canonical origin it returns are this installation's.
Repeat it from warehouse Wi-Fi and from cellular data. `doctor --local` covers the loopback gateway only;
`--host-preflight` and `--preflight` are the checks setup runs before touching anything; `--lan` runs only the checks of the
[LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network).

If the external doctor reports `fetch failed` right after you routed the hostname, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#tunnel-and-public-address).

## First-use checks

**Before anything else (required):** an installation that a phone number can reach from the internet must have
`otp_daily_provider_attempt_cap` set, or the first sign-in tests can cost real SMS money without limit
([Authentication and OTP limits](#authentication-and-otp-limits); the `INSERT` and the read-back are there).

Install the companion app ([rn-warehouse-template](https://github.com/abhiguru/rn-warehouse-template)), select this
origin and confirm the company name it discovers. Then, with fictional data and owned phones:

1. Sign in as the administrator with a real SMS code.
2. Create two fictional customers (Settings → Customers) and an item with a price (Settings → Items, Item Pricing). Sign up
   a customer login from a second phone; it stays pending until you approve it from Enrollment Review, and the assignment
   list there is empty until customers exist. Approve it with an assignment to the first customer, sign in, and confirm it
   sees only that customer's records.
3. Create a staff account. There is no create-user screen: the person signs in once, you approve them, then set the role
   under Settings → Users → edit. As staff, create a goods receipt for the customer who is **not** assigned to that person
   (the app requires a photo of the GRN book entry), a partial and a final dispatch (a photo is optional and can only be
   attached while the dispatch is being created), and save the invoice: totals are computed by the server and staff see no
   price list.
4. Download the GRN, dispatch, invoice and stock PDFs as an authorized user; confirm an anonymous or foreign request is
   denied.
5. Disable a user (Settings → Users → edit → Account Status) and confirm login is refused (the code can still be requested,
   verification is rejected), then re-enable and sign in again.
6. Take a backup and verify it (below), and keep a copy of the backup key away from this machine and from the backup drive:
   run `bash scripts/backup-key-escrow.sh show`, copy the key it prints, and type the whole key back to confirm it
   ([Backup key](#backup-key)).

One phone is enough to exercise every role if you sign out and in again for each, but each role needs its own number that
can receive an SMS. To reuse a number for the staff role, change that login's role only after the customer checks are
finished.

[INVOICE_RULES.md](INVOICE_RULES.md) and [STAFF_GRN_POLICY.md](STAFF_GRN_POLICY.md)
describe the expected behaviour. The fictional billing example there (subtotal
950, tax 48, total 998) holds only for its fixture dates. Record what you tested.

## Ordinary operation

Use the installed checkout, the recorded state directory and a shell with Node 22 and effective Docker access. The Compose
wrapper refuses a running project owned by another checkout.

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

`bash health-check.sh` runs the checker's local checks (`node scripts/watch.mjs health`: the services, the database,
the gateway's public configuration and a `get_public_config` probe through it, and the PDF renderer) and, when one fails, prints the
logs of the gateway, functions and REST services. The public hostname is tested by the checker's `api_public` check and the external doctor.

`compose ps` shows every service `Up (healthy)` except `rest`, which defines no healthcheck and appears as plain `Up`; the
doctor, not the status column, is the health verdict. `stop.sh` leaves the file `config/stopped-by-operator`, so the stack stays
down through a reboot and the monitoring checker does not start it again until `start.sh` removes the file. Start and stop the
tunnel service separately through its systemd unit. Do not run `down -v`, a broad Docker prune, or delete state as a restart procedure.

**Taking an installation out of service.** `stop.sh` stops the stack but not the tunnel service, which keeps the public address
answering with errors, and not the timers. To retire the installation, in this order: `bash stop.sh`;
`sudo systemctl disable --now warehouse-<state name>-tunnel.service` (the public address then answers with a Cloudflare error,
1033, until the tunnel is deleted); `sudo bash scripts/watch-timer.sh uninstall --state "$WAREHOUSE_STATE_DIR"` (the checker, daily and boot units; `sudo` drops the
environment, so name the state); `sudo bash scripts/backup-usb.sh uninstall` if a USB drive was set up (it removes the rule, units,
helper and configuration and leaves the drives untouched); then, only
once you have a copy of the data you need, delete the tunnel and its DNS record in Cloudflare, which also revokes every copy of
its credential, including those in backups. Deleting the state directory is a separate step that destroys the data.

To look at the data, open a SQL prompt inside the database container:

```bash
bash scripts/compose.sh exec db psql -U supabase_admin -d postgres
```

For a session that cannot change anything, use the read-only variant:

```bash
bash scripts/compose.sh exec -e PGOPTIONS='-c default_transaction_read_only=on' db psql -U supabase_admin -d postgres
```

This signs in as the database superuser, so read first and change data only
through the app or a reviewed script. There is no web dashboard.

Every operator command (`setup.sh`, `start.sh`, `stop.sh`, `rotate-keys.sh`, `db:backup`, `db:restore`,
`backup-usb.sh run`, `test:recovery`, `retention:*`, `test:gateway-dns`, `test:pooler` (runs `pooler.sh on` itself), `test:cups`, `test:sensors`, and
`scripts/migrate.sh` when run by itself) takes an exclusive per-state lock on `config/operator.lock` before touching Docker.
A second command for the same state fails immediately with "Another operator command ... is running for this state."; wait
for the first to finish and never delete the lock file. The automatic USB backup is the one exception that waits: it
retries for up to 15 minutes, then records a failure.

### Monthly host maintenance

The host's own software is not updated by this repository, and the packages that matter most are outside Ubuntu's automatic
updates: `cloudflared` comes from Cloudflare's repository (Cloudflare supports only versions within a year of its newest release,
and the tunnel service runs with `--no-autoupdate`) and Docker from Docker's. Once a month, in a quiet window (after closing, never in the backup window), as the
installation user with `sudo`:

1. **Look first.** `node scripts/watch.mjs status` shows nothing firing and "Daily backup: ok" for today;
   `bash scripts/watch-timer.sh status` shows the units and the Node.js; `df -h /` has room.
2. **Mute the checker for the window:** `node scripts/watch.mjs mute 60` (the backup alerts are never muted).
3. **Update the packages:** `sudo apt-get update && apt list --upgradable`, read the list, then `sudo apt-get upgrade`. An
   upgrade of `docker-ce` or `containerd.io` restarts every container (about a minute of downtime); an upgrade of
   `cloudflared` does not restart the tunnel service that is already running: `sudo systemctl restart
   warehouse-<state name>-tunnel.service` and `bash scripts/tunnel.sh status`. Check `cloudflared --version`.
4. **Node.js minor/patch:** when nodejs.org lists a newer 22.x (or the next LTS before Node 22 ends on 2027-04-30), unpack it
   next to the old one as in the [Ubuntu sequence](#ubuntu-2404-sequence), then
   `sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR" --node ~/.local/opt/node-$NODE-linux-x64/bin/node`
   (this moves the `~/.local/opt/node-current` link the timers use) and `node scripts/watch.mjs status`. Keep the old
   directory until the next month.
5. **Reboot** when `/var/run/reboot-required` exists or the kernel was updated: `sudo reboot`. After the boot the services
   start by themselves (`<project>-stack.service`); wait three minutes.
6. **Prove it:** `node scripts/doctor.mjs --local && node scripts/doctor.mjs`, sign in on one phone, then
   `node scripts/watch.mjs unmute`. The next morning check that the "Monitoring is alive" line arrived and that
   `node scripts/watch.mjs status` shows the night's backup as ok.
7. Write the date and the versions (`docker --version`, `cloudflared --version`, `node --version`) in your own notes.

The checker also tells you weekly when this month's work was skipped: `cloudflared_old` (the installed `cloudflared` is 11 months old, or the
tunnel still runs a binary that was replaced), `host_node_eol` (the Node.js major is within 60 days of its end) and `root_copy_stale` (a
file installed with `sudo`, such as the USB backup helper or a systemd unit, was written by an earlier release:
[MONITORING.md](MONITORING.md)). Dates further out, from image pins to the PostgreSQL move planned for 2029, are in
[MAINTENANCE_CALENDAR.md](MAINTENANCE_CALENDAR.md).

## Retention

Retention is the clean-up of expired sign-in records and generated PDFs. With
the timers installed (see "Monitoring is not a Compose profile" in the installation section above), the daily pass (`watch.mjs daily`, run by the `<project>-daily` timer) runs `scripts/retention.sh apply`
once a day, after the day's backup attempt and after it has pruned the local backups (it does not wait for the backup or its verify
to succeed: a backup that is refused for lack of space or fails its verify is when old backups must still go; it is skipped only
when the database is not running or not healthy). Pruning keeps the newest 7 backups, the newest verified one and the backup of an interrupted `upgrade.sh`. To stop the
retention, do not install the timer, or run `sudo bash scripts/watch-timer.sh uninstall`; apart from the pruning of local backups
(below), nothing else deletes on a schedule. Run the retention command yourself at any time:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run retention:preview   # counts only
npm run retention:apply
```

It removes expired sign-in records and old security logs from the database
(`warehouse_maintenance.retention_policy`), and generated PDF files older than
7 days from the private `documents` bucket (the PDFs are removed through the
Storage API, so the storage container must be running; see
[PDF_GENERATION.md](PDF_GENERATION.md)). Business records and photos are never
removed by it. The daily pass also deletes local backup directories beyond the newest 7 in `<state>/backups`, except the newest one that
passed its verify (`config/backups-verified.list`) and the backup that an interrupted `upgrade.sh` names as its way back
([MONITORING.md](MONITORING.md#the-daily-backup-verify-prune-and-retention)); the USB backup drive is not pruned by it.

## Rotate signing keys

Rotate when the JWT secret, anon key or service key may have been exposed, when a device or backup holding them leaves
your control, or on a planned schedule:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash rotate-keys.sh --yes
```

Without `--yes` the command prints a usage message, changes nothing and exits with status 1. With `--yes` it takes the
operator lock, requires a healthy database, and then:

1. stages a copy of `config/compose.env` with a new 96-hex `JWT_SECRET` and newly signed `ANON_KEY` and
   `SERVICE_ROLE_KEY` (only those three lines change);
2. in one database transaction under advisory lock 71042: stores the new secret in `warehouse_security.auth_config`,
   deletes every refresh session and voids pending OTP challenges. The secret reaches `psql` only on standard input,
   never as an argument;
3. renames the staged file over `config/compose.env` (mode 0600);
4. recreates the running key consumers (`db gateway rest storage functions`, plus `supavisor` when the pooler is on (`POOLER_ENABLED=true` and
   running) with `--force-recreate --wait`; then, apart from them, the [LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network)
   container `gateway-lan` when one exists, which holds the keys too (a failure there is a warning that names the repair: the rotation
   itself stands); and runs `node scripts/doctor.mjs --local`.

Consequences: every signed-in device is logged out and must complete OTP login again; any copied anon key is invalid and
`get-public-config` advertises the new one; the service key changes. A failure before step 3 leaves the file and database
untouched. If the process is interrupted between steps 2 and 3, the database already holds a secret the file does not;
rerun `bash rotate-keys.sh --yes`, which stages and applies a newer secret end to end. Take a fresh `db:backup` afterwards:
earlier backups restore the previous keys together with the previous database state, but no longer match the running
instance.

An external `doctor` run immediately afterwards can fail once while the recreated services settle behind the tunnel; rerun it
after about thirty seconds. Already-open apps are not sent to the login screen: their next requests are rejected with HTTP 401
and the client shows load errors or empty lists. Ask every user to sign out (Settings → Sign Out) and sign in again.

## Backup and restore

`npm run db:backup -- /absolute/destination` writes a private, signed
`warehouse-backup-v6` directory (default `$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>`).
The stored files (photos and generated PDFs) are kept as a tree of files, not as an archive, and **a file that has not
changed since the previous backup is a hard link to that backup's copy**: the second night costs the database dump and the new
photos, not another copy of every photo. A photo is therefore stored once on the disk however many backups hold it, and it
stays in the older backups after it has left the live storage. Hard links need the backup folder and the previous backups on
one filesystem, which is the normal case (`backups/` of the state).

The services are stopped only for the database dump, the catalog queries and the last pass of the file copy, then restarted;
the first pass of the copy, the checksums and the signing happen while the app is up. The stop does not grow with the size of the
photos or with how many are new, but it does grow with the number of files: the last pass reads the name, time and attributes of
every stored file on both sides (twice, the second time as a check that nothing is left to copy), which takes seconds for tens of
thousands of files, not minutes. `db:backup` prints how long the services were stopped, how long the backup took, and how many files were new
(`metadata.txt` records `stop_seconds=`, `duration_seconds=`, `storage_files=`, `storage_bytes=`, `storage_new_bytes=` and
`link_base=`, the backup the files were linked from). The first backup is a full copy. The backup it links from is the newest one whose daily verify passed within the last
two days; when there is none (nights whose verify fails, so that the last verified backup is older), the newest backup that passes
its signature check, verified or not, so that failing verifies do not make every night copy the same new photos again. Every
shared file is compared with the signed manifest of that backup, so a backup that was not verified is safe to link from.

**Free space is checked first, before anything is stopped or written.** `db:backup` works out what the backup needs on the disk
that holds its folder, and refuses when the disk could not hold it and still keep a reserve. What it needs:

- **Linking from an earlier backup** (the normal night): twice the stored files that are new since that backup (the files that
  pass 1 would copy, counting 4 KiB for each folder of the tree, which cannot be hard-linked), plus the database dump, plus 256 MiB
  for the rest.
- **With no backup to link from** (the first backup, or every earlier one is unusable): the whole photo tree **once** plus 10%
  of it, plus the database dump, plus 256 MiB. The copy of a tree that is made twice in a row costs the tree only once, because the
  second pass links to the first; the 10% covers the folders and what is uploaded meanwhile.
- The database dump is counted as 1.5 times the dump of the backup it links from (at least 96 MiB); with no such backup, 1.5 times
  the database's own size.
- The disk must have all that free **plus the reserve**, `WAREHOUSE_BACKUP_RESERVE_MB` (a whole number of MiB, 2048 by default, so
  that a backup never fills the disk the database lives on).

The free space is read with `df`; when `df` gives no number, with `stat -f` (free blocks times block size), and the backup says so with a
`WARNING` line, which the daily status shows. If **neither** can be read, the backup is **refused** (the check is never silently
skipped): `Refusing: could not read the free space of <folder> (df and stat -f both failed), so the backup cannot be checked to fit.
Nothing was stopped.` A refusal for lack of space is the last line on standard error, with the numbers (`Refusing: not enough free
space in <folder>: a backup needs about N MiB (...) plus a reserve of R MiB, but only A MiB are free. Nothing was stopped.`); the app
keeps running and no partial backup is left. Slack `backup_failed` shows the same line; see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#backup-usb-drive-and-restore), "backup refused: not enough free space". A backup that goes ahead
records the numbers it was judged by in `metadata.txt` (`preflight_need_mb=`, without the reserve, and `preflight_avail_mb=`).

**A backup with no usable earlier backup to link from needs the most room.** It copies everything. If the disk has
less free than the photo tree plus the 2 GiB reserve, every night is refused until you free the room: a refused night
makes no new backup, so nothing ages out by itself. Free the room (delete backups you no longer need from `$WAREHOUSE_STATE_DIR/backups`, or add disk). The USB script copies only the newest verified backup and prunes the drive to the newest three archives, so it does not keep
an old backup for you; to keep one, write its archive into a folder of its own on the drive, outside this installation's folder (for
example `warehouse-backups/kept/`: a run never looks into sub-folders, and a signed archive left in `warehouse-backups/<state name>/`
is pruned at the next good run), with the `backup_archive_write` commands under "Manual fallback" in
[DEVELOPER_HANDOFF.md](DEVELOPER_HANDOFF.md#usb-backup-drive) (set `DST` to that folder). Check first
with `du -sh "$WAREHOUSE_STATE_DIR/data/storage"` and `df -h "$WAREHOUSE_STATE_DIR/backups"`.

To change the reserve, give the process that makes the backup the variable. For the nightly run, use the daily unit
(`sudo systemctl edit <project>-daily.service`, then `[Service]` and `Environment=WAREHOUSE_BACKUP_RESERVE_MB=1024`); for a backup by
hand, put it in front of the command. **Two other callers do not see that setting and keep 2048:** the fresh backup that the USB
unit makes before it copies (`sudo systemctl edit warehouse-usb-backup@.service`, the same two lines) and the backup inside `upgrade.sh`
(`WAREHOUSE_BACKUP_RESERVE_MB=1024 bash upgrade.sh vX.Y.Z`). Lower it in all three places or the one you forgot refuses with the
numbers above.

The directory contains:

| File | Content |
| --- | --- |
| `database.dump` | `pg_dump --format=custom` of the `postgres` database **with owners** (needed by the in-place restore). |
| `storage/` | The object storage as it was at the moment of the dump: the same folders and files, with their modes, modification times and **extended attributes** (the Storage service keeps each file's content type and cache control there; without them a restored photo or PDF is served as `application/octet-stream`). Files unchanged since the previous backup are hard links to its copy: never change a file in here, in any backup. |
| `storage.manifest` | The SHA-256 of every file in `storage/` (`<hash>  <path>`, in byte order). It is listed in `SHA256SUMS`, so the signature covers every file of the tree through it. |
| `storage_objects.txt` | The `storage.objects` catalog as `<bucket>/<name>/<version>`, byte-ordered. |
| `integrity.txt` | Output of `scripts/backup-integrity.sql`: migration fingerprint, row counts, representative grants. It also counts the three history tables (invoice discounts, zero charges, item prices), payments, order lines and order revisions, and records that the internal `invoice` columns are closed to the app role. |
| `roles.txt` | Cluster role names, so runtime-created roles can be recreated before ownership replays. |
| `compose.env`, `instance.json` | Private configuration and public manifest at backup time. |
| `central-jwks.json` | Only when the installation reads the central sign-in keys from a file (`--central-jwks-file`): a copy of `public/central-jwks.json`, public keys only. `db:restore-host` puts it back. |
| `letterhead.jpg` or `letterhead.png` | Only when the installation has a letterhead image (`--letterhead-file`): a copy of `public/letterhead.jpg` or `.png`. `db:restore-host` puts it back; a backup without it restores to plain PDFs. |
| `metadata.txt`, `SHA256SUMS` | Format, timestamp, source commit, `database_image=` (the database image the dump was taken on; restores refuse an earlier one), the sizes and times named above, and checksums of every file above except those inside `storage/` (the manifest covers them). |
| `SHA256SUMS.hmac` | The signature: HMAC-SHA256 of `SHA256SUMS` under the [backup key](#backup-key). |

The backup directory is **unencrypted** and contains every credential of the instance. Keep it mode 0700/0600 on protected
storage. `db:backup` warns when the destination shares a filesystem with `data/`: a backup on the same disk does not
survive loss of that disk. A hard link does not make a second copy: if a stored file rots on the disk, every backup that
links to it is damaged at once. `db:backup` therefore checks the signature of the backup it links from before it uses it (a
backup that fails is skipped, with a warning, and the next older one is tried), and compares each file it links with the checksum
that backup recorded. A file that no longer matches, or cannot be read, is not linked: it is copied again from the live storage,
the new backup holds the good copy, and the night ends as usual with the sentence `WARNING: N files re-copied: backup <name> has a
damaged copy` (also in the daily status line, `metadata.txt` as `rot_repaired=` and `rot_repaired_file=`). The older backups still
hold the damaged file: check them with `db:verify-restore` ([TROUBLESHOOTING.md](TROUBLESHOOTING.md), "storage file fails its
checksum"). Only when the live file does not match the recorded checksum either does the night fail. Keep the copies on the USB
drive (a full, separate copy of the photos each) for that case.
The USB drive ([below](#usb-backup-drive)) is the one copy that leaves the host: there is no unattended off-site copy, so after a
host loss you have the data as of the last time the drive was plugged in. Never use `down -v` on a production instance. The optional CUPS and sensor bridge volumes are not in
this backup either (the bridge's volume holds only readings not yet delivered).

**`$WAREHOUSE_STATE_DIR/images` is not in a backup; the USB copy carries it beside the archives.** It holds the images this
installation uses and built or pulled (`db`, `functions`, `storage`, `pdf-renderer`, and any optional one in use) as `docker save` tarballs,
written by `scripts/build-images.sh` after every successful build or pull, with a copy of the build record. They are what lets a
lost-host restore run without Debian, npm and Chrome for Testing answering (Docker Hub is still needed for the official postgres image that the restore check runs and for PostgREST, which are pulled, not built; they need about 2.5 GiB of disk;
a save that would leave under 5 GiB free, or less than the size of the newest backup when that is larger, is skipped with a
warning, and the tarball of that service is removed because the record then names a newer image than it holds; tarballs of
services the record no longer names are removed too). The folder is **signed like a backup**: `SHA256SUMS` lists every file in it and
`SHA256SUMS.hmac` is made with the [backup key](#backup-key), because a loaded image runs on the rebuilt host with every
secret. `db:restore-host` loads nothing from a folder whose signature does not check out with the key you give it
(`--backup-key`), and never with `--allow-unsigned`. `scripts/backup-usb.sh` copies the folder whole, as it is, to
`warehouse-backups/<state name>/images/` on the [USB drive](#usb-backup-drive), next to the archives, where `db:restore-host`
looks for it: once, and again only when the folder's signed list changes (after an upgrade that built or pulled an image). Add no file of your own to the
folder. If the folder is missing (for example after you removed it), write it again, and the next copy to the drive takes it:

```bash
bash scripts/build-images.sh --save
```

The images are not encrypted on the drive and are not inside the archives: they are made from this repository's recipes (or are the
released images, below) and hold nothing of the installation, so there is nothing to protect by encrypting them, and every archive would
otherwise carry the same few GiB again. What protects the rebuilt host is the signature. Keep the drive away from the host as for the archives; a drive
too small for the images next to the archives fails the run with the sizes (no archive is deleted to make room for them).

The images that Compose pulls (PostgREST) are not saved; a rebuilt host pulls them by digest. The gateway is built from `docker/nginx`, so its image is saved with the others (it is about 13 MB).

`npm run db:verify-restore -- /path/to/backup` checks every checksum and the signature first (see
[Backup key](#backup-key)), rejects absolute paths, `..` segments and links in the
stored files (for a v6 backup: every file of `storage/` is hashed and must be exactly the set that the signed
`storage.manifest` names; a link or special file refuses the backup), proves that every catalogued object is a file in the
backup (extra files are reported as a warning), restores the dump into a disposable
`--network none` container with `--exit-on-error`, replays the archived
ACLs, and compares the integrity report and the restored object catalog with
the backup. Run it against every retained backup; it never touches the installed
instance.

Backups of format v6 (written now) and the older v5 are accepted; the verifier, `db:restore` and `db:restore-host` refuse any other format, and a backup whose label disagrees with its signed file list.
`db:verify-restore --no-storage-tree` leaves the hashing of the tree out and checks the rest (signature, list, manifest,
database): it is for a copy of a backup that does not hold the tree.
A backup whose signature is missing is refused unless you add `--allow-unsigned`,
which prints a warning and proves nothing about where the backup came from; it
is only for when the backup key is lost (see [Backup key](#backup-key)). If the
`SHA256SUMS.hmac` file is missing and the key is available, all three commands
refuse the backup even with the flag, because the signature was taken away. Use
another copy.

The disposable database is sized from the backup: the dump times 10, the same again (up to 1 GiB) for the write-ahead
log, plus 256 MiB, and never less than 768 MiB. It lives in memory when that much memory is available, otherwise in a
temporary directory under `$WAREHOUSE_STATE_DIR` that is removed afterwards; the command prints the size and the place it
chose, checks free space first, and when it does not fit it stops with the numbers. Override when needed:

| Variable | Meaning |
| --- | --- |
| `WAREHOUSE_VERIFY_DATA_MB` | Size of the disposable data directory in MiB. |
| `WAREHOUSE_VERIFY_SIZE_FACTOR` | Multiplier applied to the dump size (default 10). |
| `WAREHOUSE_VERIFY_STORAGE` | `auto` (default), `tmpfs` or `disk`. |
| `WAREHOUSE_VERIFY_SCRATCH_DIR` | Parent of the disk-backed directory (default `$WAREHOUSE_STATE_DIR`). |
| `WAREHOUSE_VERIFY_MEMORY_MB` | Memory limit of the container. |

A failed verification leaves the container log, its state and the database sessions in
`$WAREHOUSE_STATE_DIR/diagnostics/verify-restore-<utc>-<id>/` (`WAREHOUSE_DIAGNOSTICS_DIR` overrides the place). The log
can contain rows of the backup; keep the directory private and delete it when the problem is understood.

### Backup key

`config/backup.key` in the state directory (mode 0600) is a random 256-bit key. `setup.sh` creates it; on an installation
made before signed backups, the next `setup.sh` run or `db:backup` creates it and says so. It is used for three things:

- every backup is **signed** with it (`SHA256SUMS.hmac`). `db:verify-restore`, `db:restore` and `db:restore-host` check the
  signature before they read anything else from the backup. Plain checksums only detect damage; anyone who can write to a
  backup drive can regenerate them, and a restore replays the dump as the database superuser and adopts the backup's
  `compose.env`. The signature is what tells your backup from an edited one. For an archive, `db:restore-host` also
  requires its `.sha256` to hold exactly one record, naming that archive, with the SHA-256 of its bytes, so a checksum and
  signature copied from another archive are refused before anything is opened;
- a USB drive is **enrolled** with it ([USB backup drive](#usb-backup-drive));
- USB archives are **encrypted** with it (they are, unless you typed `--no-encrypt`).

The key is never written into a backup and must never be stored on the backup drive. **Keep a copy away from the server and
away from the drive**: a password manager, or paper kept somewhere else. The encrypted archives on the drive are only as
recoverable as that copy: the key lives on the disk that dies with the host, so a lost host plus a lost key is the loss of every
encrypted archive.

**Confirm the copy once, and again after the key is ever replaced.** In a terminal on the host, as the installation user:

```bash
bash scripts/backup-key-escrow.sh show
```

It prints the key once (64 hexadecimal characters; copy them exactly), with where to keep them, and then asks you to **type or paste the whole
key back from your copy** (capital letters and spaces do not matter; nothing is shown as you type; three tries). Every character is
compared, so a copy with one wrong or swapped character is found now and not after the host is lost. When the whole key matches it
writes `config/backup-key.escrow` (mode 0600: a fingerprint of the key, the time and your user name; never the key), and tells you to
clear the terminal, because the key is still on its screen and in its scrollback (run `clear`, close the window, and in tmux or screen
clear the history too; do not keep a log of the session). **A USB drive is not enrolled, and an encrypted archive is not written, until
this record matches the key in use**: `backup-usb.sh setup --enroll` and `enroll` refuse, and a run records a failure that
`npm run doctor` and the checker's `usb_backup` alert show, with the command to run. Without a terminal (an unattended install, a script)
`bash scripts/backup-key-escrow.sh confirm --key-file FILE` does the same from a file that holds your copy of the key (bring it from
where you keep it; the file of the host's own key is refused, since it is lost with the host). It compares the whole key as well and
never creates a key; `show` is the command that creates one on an installation that has none. `bash scripts/backup-key-escrow.sh check`
says whether the record is good. The record proves that the whole key was given back once; it does not prove that the copy stays
readable, so check the copy again from time to time, as described next.

After the host is lost, `db:restore-host` refuses a backup unless you give it the key (`--backup-key FILE`), and an
encrypted archive cannot be opened at all without it. Without the key (lost), a signed backup can only be restored with
`--allow-unsigned`, on your own judgement that the drive never left your hands; an encrypted archive is lost. Check your
copy once: put it in a file and run
`WAREHOUSE_BACKUP_KEY_FILE=/path/to/copy npm run db:verify-restore -- /path/to/backup`.

The restored installation keeps the same key. If the key itself may have been disclosed: move `config/backup.key` aside
(keep it with the old backups, which only verify with it), take a new `db:backup` (it creates a new key), store the new
copy and confirm it (`bash scripts/backup-key-escrow.sh show`; the old confirmation is for the old key and no longer counts), and
run `bash scripts/build-images.sh --save` (it builds nothing; it signs the saved images in `$WAREHOUSE_STATE_DIR/images` again with the new key, which the USB run needs before it copies them), and enroll each USB drive again. On each drive, also move the archives written before the change
(`warehouse-<utc>.tar*` with their `.sha256` and `.hmac` files) into another folder, for example
`warehouse-backups/<state name>/old-key-<date>/`: they carry signatures of the old key, and as long as an older backup is
still under `backups/` the USB run would report its archive as "not signed with the current backup key" on every attach.
**A run never prunes an archive signed with another key** (it cannot tell one from a file somebody planted, so it names it and leaves it),
and a run never looks into sub-folders, so these archives take space on the drive until you delete them: once you no longer need the
backups they hold (they open only with the old key, which you must keep for as long as you keep them), delete them yourself. A drive
that holds them next to the new archives reaches `drive too small` sooner. Move the drive's old `images` folder aside with them (it is signed with the old key and a `db:restore-host` with the new key would ignore it); the next run copies the newly signed images. Until `build-images.sh --save` has been run, the USB run still copies the archives and prunes, and says "saved images NOT copied".
Do the same after a `db:restore-host --allow-unsigned` that was run without the key (its first backup creates a new one).

### USB backup drive

A backup on the same disk as `data/` is lost with it, which is why `db:backup` warns. The USB script copies the newest verified
backup to a **USB drive formatted exFAT**, which the operator attaches; exFAT is readable by a Linux host and by
Windows, so the drive can be read on either; the restore itself runs on Linux or in Ubuntu under WSL2. On a
[Windows host](#windows-host-ubuntu-in-wsl2) the drive is passed into the distro first, and again after every restart
([Backups off the host](#backups-off-the-host-windows)). The drive is never partitioned or
formatted, and other files on it are left alone. The copy goes under `warehouse-backups/<state name>/` as one self-contained
**encrypted** archive, `warehouse-<utc>.tar.enc` (a tar of the whole backup folder, with file modes, modification times and the
stored files' content types kept inside, and the photos written out in full: the drive has no hard links), with a
`.tar.enc.sha256` checksum and a `.tar.enc.hmac` signature made with the [backup key](#backup-key). It is `.tar`, readable, only if
you typed `--no-encrypt` (below). The drive keeps the newest three archives of this installation and deletes older ones, so it needs
room for about three times the photos plus the databases (the oldest archive is deleted early when a new one would not fit), and **the point you can recover to is the last time the drive was plugged
in**: everything recorded after it is lost with the host.

The drive also carries the installation's **saved images** (`$WAREHOUSE_STATE_DIR/images`, about 2.5 GiB) in a folder `images` beside
the archives, once and not once per archive, so it needs that much room more ([Backup and restore](#backup-and-restore)), and as much again free while a changed set is written beside the old one (about 5 GiB at each image change; the old set is deleted only after the new one has been read back). The copy is the last step of a run, after the archive is on the drive and the drive is pruned: when the images do not fit, the archive copy still counts as successful, the run says "saved images NOT copied" and `npm run doctor` shows it. The enrolment
output says how much the images add now. The run copies the
folder as soon as it exists (`bash scripts/build-images.sh --save` writes it on an installation that has none).

The operator's only job is to **attach the drive**. `scripts/backup-usb.sh` installs a udev rule and a systemd unit once;
after that, attaching an **enrolled** drive takes a fresh `db:backup` only if the newest verified backup is 20 hours old or more
(write-facing services stop briefly; a drive attached in the morning after the night's backup stops nothing), writes the newest
verified backup (the daily check's verified list, else the newest signed one) as one archive, checks the signature and every file of
that backup before a byte is written, reads the archive back from the drive and compares checksums, runs `db:verify-restore` on
the archive's small files (the databases, the manifest, the configuration: the photos are never unpacked onto the data disk, and the
run first checks that the state directory has room for the dump plus 256 MiB), deletes what the keep rule below says, and unmounts
the drive. Only an enrolled drive receives anything.
Enrolling writes a marker file, `warehouse-backups/.drive-enrolment`: a signature made with the backup key over the drive's
filesystem UUID, its partition UUID and this installation's identity, recomputed before a run takes a backup or copies a
byte. The exFAT volume serial alone does not enrol a drive (it is 32 bits and can be chosen when formatting), so a stick
that imitates it receives nothing.

1. **Confirm the backup key copy** ([Backup key](#backup-key): `bash scripts/backup-key-escrow.sh show`, which needs a terminal: run it
   in an interactive session, not as a one-shot SSH command); setup with `--enroll`
   and `enroll` refuse until you have. Then set it up once, as the installation user with `sudo`, with the drive attached (on a Windows host
   the drive is first attached to the distro: [Backups off the host](#backups-off-the-host-windows)). Find the partition with `lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS`; it
   must show `usb` and `exfat`:

   ```bash
   cd /path/to/installed/backend
   sudo bash scripts/backup-usb.sh setup --state /absolute/path/to/this/warehouse --enroll /dev/sdb1
   ```

   Run it in an interactive terminal on the host: `sudo` asks for your password, and a shell without a terminal cannot
   answer it. The copy itself always runs as the installation user, never as root. **Setup does not copy anything to a
   drive that is already attached**: unplug it and attach it again to make the first copy. The unit runs
   `scripts/backup-usb.sh` from this checkout, so do not move or delete the checkout, or switch it to a branch or release
   without that script, while USB backup is set up. Setup copies its root helper to
   `/usr/local/libexec/warehouse-usb-backup` and writes `/etc/warehouse-usb-backup.conf`, the enrolled-drive list
   `/etc/warehouse-usb-backup.drives` (root only, mode 0600), `/etc/udev/rules.d/90-warehouse-usb-backup.rules` and the
   `warehouse-usb-backup@.service` unit. Options: `--daily` for a drive that stays attached (a daily timer starts the same
   run), `--no-fresh-backup` to copy only existing backups, `--keep N` for how many archives a drive keeps (default 3), and
   `--no-encrypt` to write readable archives (not recommended; below). A later setup run that does not name one keeps what
   you chose; switch one back with `--no-daily`, `--fresh-backup` or `--encrypt`.
   Enroll a second drive for rotation with `sudo bash scripts/backup-usb.sh enroll --device /dev/sdX1`; enrolling needs the
   backup key, so run `bash scripts/backup-key-escrow.sh show` (it creates the key if there is none) or `npm run db:backup` first on an
   installation that has none yet. **Run setup again after updating
   the checkout** ([Rerun and upgrade](#rerun-and-upgrade); `setup.sh` runs first) so the installed helper and the unit match it
   (`status` warns when they do not): the unit has a 6-hour time limit for a run and carries a keep count other than 3 if you chose one;
   both reach an installation only through this rerun. `sudo bash scripts/backup-usb.sh uninstall` removes everything it installed and never
   touches a drive.
2. From then on: plug the drive in and wait (on a Windows host with the Warehouse USB task, plug it into the same port and wait;
   without the task, attach it with `usbipd attach`: [Backups off the host](#backups-off-the-host-windows)). The run takes minutes at first and longer as the photos grow (it reads the backup,
   writes and reads back one archive, and checks every archive it keeps); when the drive disappears from the file manager
   (or `lsblk` shows no mount point for it), it is unmounted and safe to remove. Do not unplug during a copy; an
   interrupted archive is left as a `.partial` file that the next run removes, together with any checksum or signature file
   left without its archive. The run holds the operator lock from the copy to the end (it hashes every archive it keeps), so
   `setup.sh`, `upgrade.sh` and the other operator commands wait for it, and the monitoring checker skips its checks meanwhile
   ([MONITORING.md](MONITORING.md#usb-run-and-the-checker)).
3. Check the result as the installation user:

   ```bash
   bash scripts/backup-usb.sh status            # last result, enrolled drives, last success age
   journalctl -u 'warehouse-usb-backup@*' -n 50  # the run's own output
   ```

   Until the first run, `journalctl` answers "Failed to add filter for units: No data available"; that only means no run
   has happened yet. The result is also written to `warehouse-backups/<state name>/LAST-RESULT.txt` on the drive, and
   `npm run doctor` warns when the last run failed, the last successful copy is older than 7 days
   (`WAREHOUSE_USB_BACKUP_MAX_AGE_DAYS`), or archives are encrypted and the [key copy](#backup-key) is not confirmed.

**What a run deletes, and what it never does.** The `images` folder is replaced whole when the installation's folder changes (the new
one is written beside it and read back first) and is never pruned; a run deletes no archive to make room for it. After a run that finished without a failure, the drive keeps the newest
three valid archives of this installation (`--keep N`) and deletes the older ones with their `.sha256` and `.hmac` files. Valid
means the bytes match the checksum and the signature is one of the current backup key. An archive that is damaged, has no signature,
or was signed with another key (after a key replacement, see [Backup key](#backup-key)) is **reported by name and never counted or
deleted**; neither is any other file on the drive. An archive without a signature is kept as well, and the run names it **on every run** until you remove it yourself. The newest valid archive is
never deleted. A run that fails deletes nothing, with
one exception: if the new archive will not fit, it deletes the oldest valid archives, one at a time while more than one remains, until
it does; it deletes nothing at all when even all of them would not make room, and if it still will not fit the run fails with
`drive too small: needs X, has Y`; use a larger drive, because the drive must hold the new archive next to the newest one it already has.
If the drive's free space cannot be read, the run is refused (`could not read the free space of the drive`) and deletes nothing. Nothing is ever deleted from `backups/` on the host by this script. A run
that finds an archive of the backup it is copying that no longer matches its checksum reports it and leaves it alone.
Problems: [TROUBLESHOOTING.md](TROUBLESHOOTING.md#backup-usb-drive-and-restore).

**Archives are encrypted by default.** Each archive is written as `warehouse-<utc>.tar.enc` (AES-256, key derived from the
[backup key](#backup-key), with a signed checksum next to it) and the run verifies the restore from the encrypted copy. Unencrypted,
an archive contains `compose.env`, which holds every credential of the instance, the whole customer database, and, after
`tunnel.sh adopt`, the tunnel credential: whoever held the drive could run a connector for your hostname and receive part of the
phones' traffic, sign-in codes included. **The price: after the switch, a lost backup key means the encrypted archives are
unrecoverable.** That is why the key copy must be confirmed before a drive is enrolled or an encrypted archive is written
(`bash scripts/backup-key-escrow.sh show`), and why the copy belongs somewhere that survives the loss of the facility.

**Deleting a readable archive does not wipe it from an exFAT drive.** `rm` only frees the space; the contents of a deleted
`warehouse-<utc>.tar` (the `compose.env` with every credential, the database dump, the tunnel credential) stay on the stick until
new data happens to overwrite them, and a data-recovery tool such as photorec or testdisk can read them back. The new encrypted archive
may well land in other free space. So a drive that ever held readable archives is still as sensitive as the server's disk, even after
the run has deleted them. **Before such a drive leaves your hands** (taken off site, lent, sold, thrown away), either rotate what the
archives held, as in the next paragraph (`./rotate-keys.sh --yes`, the MSG91 key, the tunnel credential), or retire the drive and enrol a
new one that has only ever held encrypted archives, which is the better course. The run prints this where it deletes, and so does the
notice that setup prints when it switches an installation to encrypted archives.
Typing `--no-encrypt` is a choice that setup keeps (`ENCRYPT_SET=typed` in `/etc/warehouse-usb-backup.conf`); it needs no key copy,
and a drive written that way is as sensitive as the server's disk. To encrypt again run setup with `--encrypt`; it prints the same notice
(the readable archives on enrolled drives will be deleted, and deleting does not wipe them) because it starts the same deletion. Encryption is
covered by automated tests that encrypt and decrypt an archive with the database replay simulated, and CI rebuilds a host from an
encrypted archive and the key copy alone on real containers; until you have done one restore from an encrypted archive on a
real new host yourself, treat the drive as unproven.

If a drive that ever held readable archives is lost (or leaves your hands without having been retired), even if a run deleted them,
act at once: run `./rotate-keys.sh --yes`, rotate the MSG91 key, and replace the
tunnel credential (for a dashboard tunnel, refresh its token in the Cloudflare dashboard; for a locally managed tunnel,
create a new tunnel, route the hostname to it with `route dns --overwrite-dns` and delete the old one), then
`mv "$WAREHOUSE_STATE_DIR/config/tunnel" <private place>`, `tunnel.sh adopt` the new credential,
`sudo bash scripts/tunnel.sh install-service`, replace the passwords listed under
[Secrets that rotate-keys does not change](#secrets-that-rotate-keys-does-not-change), and take a new backup. A drive kept
on site is local custody only; taking it (or a second drive in rotation) to another location is what protects against
loss of the host, theft or fire.

To use an archive from the drive: on the **same** installation (its state directory intact) unpack it into
`$WAREHOUSE_STATE_DIR/backups/` (it decrypts a `.tar.enc` with the state's key and keeps the stored files' attributes; the
state needs room for the whole backup) and follow [In-place restore of the same instance](#in-place-restore-of-the-same-instance);
after losing the host, follow [Recover a lost host from the USB drive](#recover-a-lost-host-from-the-usb-drive).

```bash
( set -e; source scripts/backup-key.sh; source scripts/backup-archive.sh
  backup_key_load "$WAREHOUSE_STATE_DIR/config/backup.key"
  A="$DRIVE/warehouse-backups/<state name>/warehouse-<utc>.tar.enc"
  ( cd "$(dirname "$A")" && sha256sum -c "$(basename "$A").sha256" )     # the bytes are the ones that were written
  backup_check_archive "$A" "$BACKUP_KEY"                                # and this installation's key signed that checksum
  backup_archive_extract "$A" "$WAREHOUSE_STATE_DIR/backups" )
```

Both checks come first: an archive changed on the drive, or put there by somebody else, is not unpacked (`db:restore-host` makes the
same two checks).

**Record a fingerprint with each backup you may need to prove later.** Right after a USB run, before anyone uses the app
again:

```bash
bash scripts/data-fingerprint.sh > ~/fingerprint-<backup name>.txt
```

It prints a row count and a SHA-256 for every business table (customers, items, prices, GRNs, dispatches, invoices, stock
movements, users, orders with their lines and revisions, and payments), for the three append-only histories (invoice
discounts, zero charges, item prices), the storage catalog and the stored files. Take both fingerprints to compare on the
same release: a fingerprint from another release can differ in its lines, so a restore does not print `IDENTICAL` against it; take a new one after upgrading. It holds no secrets; keep a copy off the host (for example next to the archive on the drive). After a restore the same command must
print identical lines.

### In-place restore of the same instance

`npm run db:restore -- --yes /path/to/backup` replaces the installed database
and stored objects with a signed v5 or v6 backup **of the same instance** (older
formats are refused). For a replacement host see
[Recover a lost host from the USB drive](#recover-a-lost-host-from-the-usb-drive).

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:verify-restore -- /path/to/backup
bash stop.sh
npm run db:restore -- --yes /path/to/backup   # add --restore-config if keys were rotated after the backup
bash start.sh
node scripts/doctor.mjs --local
bash setup.sh --operator ...   # only if you use central sign-in: makes the restored database agree with compose.env
```

A restore returns the instance to the moment of the backup: everything recorded
after it is gone. To rehearse a restore without losing current data, take a
fresh `db:backup` immediately beforehand and restore that one.

The restore refuses, without touching anything, unless all of the following hold:
`--yes` is given; no other operator command holds the state lock; `compose ps -q`
is empty (run `stop.sh` first); the backup's checksums and its signature under
this installation's `config/backup.key` are valid; the backup is
`warehouse-backup-v5` or `-v6` (an older format is refused); the backup's catalog is not on a newer Storage schema than this checkout's
Storage image migrates to (`Refusing: the backup was taken with Storage schema version <n> ..., newer than version <m>, the newest that
this checkout's Storage image <version> migrates to. Check out a release at least as new as the backup, then retry. Nothing was moved.`;
`db:verify-restore` and `db:restore-host` refuse it the same way, and a backup from an older Storage schema is fine, Storage migrates it
forward at its next start); the backup's
`instance.json` names the same instance as `public/instance.json` (the same `instanceId`, `canonicalOrigin` and `companyName`; the capabilities and the other fields may differ); the backup's `compose.env` equals
`config/compose.env`, or `--restore-config` is given and the backup names the
same project and state paths; and `db:verify-restore` passes for the backup; and there is room: the restored files are a second copy next to the kept
`data/storage.pre-restore-<utc>`, so the free space in `data/` must hold the size of the stored files again
(`storage_bytes=` in `metadata.txt`, for a v5 backup the size of its tarball) plus 1 GiB. Otherwise it stops with the numbers
before it moves anything. Free space by removing the `*.pre-restore-*` directories of earlier restores you have accepted.

It then moves `data/db` and `data/storage` to `data/db.pre-restore-<utc>` and `data/storage.pre-restore-<utc>`, recreates
both with mode 0700, copies the stored files back (a v6 tree with `rsync -rptX`, which keeps modes, times and extended
attributes, then a second, dry run that must find nothing left to do; a v5 tarball is unpacked with `tar`), optionally
replaces `config/compose.env` (keeping
`config/compose.env.pre-restore-<utc>`), starts a fresh cluster, recreates missing roles from `roles.txt` as `NOLOGIN`,
recreates the `postgres` database from `template0` (connected to `template1`) and replays its dump with `--exit-on-error` and the
archived owners and ACLs (as the verifier does), diffs `scripts/backup-integrity.sql` against the backup's `integrity.txt`,
runs `scripts/migrate.sh --operator` (a no-op unless this checkout added migrations after the backup), starts every service
with `--wait` and runs `doctor --local`. After the services are up the restore looks at up to 20 of the restored files; if any
has no content type (a v5 backup holds no extended attributes, and neither does a v6 backup of files that had lost theirs) it runs `npm run storage:retag`, which sets each file's
content type and cache control again from the catalog (the bytes are intact either way; a failure there is a warning). Role passwords always come from the active `compose.env`; the backup never
contains them. Pass `--restore-config` only when the keys in the backup are the ones the restored data was signed with,
that is, when `rotate-keys.sh` ran after the backup and the restored sessions must match the old keys.

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

### Content types of stored files (`npm run storage:retag`)

The Storage service reads each stored file's content type and cache control from extended attributes of the file. A file
without them is served as `application/octet-stream` with `no-cache`, and its modification time shows 1970 if it was restored
from a tarball that fixed the time. A restore from a v5 backup can leave files without them. The bytes are intact and the
app's image viewer recognises its content, so nothing looks broken; downloads of a PDF
may name the wrong type. To set them again for every object the catalog knows:

```bash
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run storage:retag
```

It reads the catalog (`storage.objects.metadata`: `mimetype`, `cacheControl`) and sets `user.supabase.content-type` and
`user.supabase.cache-control` of each file from inside the storage container, with the same module the Storage service
uses. It changes nothing else, may be run at any time, and prints how many files it updated, how many were already correct,
and how many catalogued objects have no file. `db:restore` (and so `db:restore-host`) runs it itself after a restore when a sample of the restored files has no
content type. `npm run storage:retag -- --if-missing` does that look at a sample first and sets nothing when none lacks one.

The change of attributes counts as a change for the next backup: it links a file to the earlier backup's copy only when the
attributes are the same too, so **the first backup after a retag copies every photo again** (a full copy, as the first backup
does).

### Recover a lost host from the USB drive

Use this when the original host is gone (disk failure, reinstall, stolen or
destroyed machine) and the USB drive is the only thing left. The rebuilt host
becomes **the same warehouse**: same instance identity, HTTPS origin, signing
keys, MSG91 settings, users, sessions and data, exactly as at the moment of the
backup. Phones keep working without selecting the server again. Everything
recorded after the backup is lost.

> **Status:** CI runs a lost-host drill on real containers (fresh backup, an encrypted USB archive made from it,
> containers removed, restore from that archive and the key copy alone into a different path, identical fingerprint).
> Record the result of your first drill on a real new host.

**Never run the old and the new host at the same time.** They would answer as
the same warehouse with the same keys. If the old host might come back, wipe
its disk or keep it disconnected; if in doubt, rotate the keys afterwards
(step 9).

Before you start you need: the new host prepared as in
[host prerequisites](#host-prerequisites) (Node 22, Docker with a Compose plugin that accepts `up --wait-timeout`,
`rsync` and GNU `tar`, `cloudflared`, your user in the `docker` group), the USB drive, and **your
copy of the [backup key](#backup-key)** in a file on the new host (for example
`~/backup.key`, mode 0600; one line of 64 hexadecimal characters). Backups taken
after `tunnel.sh adopt` carry the tunnel credential; if the tunnel was not adopted, you also
need your private copy of it (the tunnel `config.yml` plus its credentials
JSON, or the dashboard token file). If this facility's central sign-in reads its
keys from a file, backups carry that file too
(`central-jwks.json`); keep the key set the association sent
you as well (step 7). The drive carries the old host's saved images beside the archive (`warehouse-backups/<state name>/images`,
[Backup and restore](#backup-and-restore)), so **no Debian, npm or Chrome for Testing mirror has to answer** to rebuild the images of a lost host. **Docker Hub is still needed:** the restore
check runs the official postgres image (`scripts/db-image.sh`) and Compose pulls PostgREST from it, and neither is in the saved images. If the drive has no such folder, bring a copy of the old host's `images` folder if you have one (step 3). Without
saved images, a checkout that is exactly at a release tag pulls the images the release published for its recipes (`restore-host` runs
`build-images.sh --from-release` before the restore, which needs GitHub and `ghcr.io`) and builds the rest; any other checkout builds them all
(the fallback below). **Do not run `setup.sh` before the restore**: on the new host it
would create a new, different warehouse. After `db:restore-host` has finished,
`setup.sh` on the restored state keeps the identity. Step 7 needs it, and so
does step 8 when the installation sent alerts to Slack; when both apply,
one rerun with both sets of options does.

1. **Get the code.** Clone the repository with `umask 022` as in the Ubuntu
   sequence. Any release at least as new as the backup works (the backup's
   `metadata.txt` records `source_commit`); newer migrations are applied during
   the restore. A checkout older than the release that wrote the backup refuses it at
   once ("Refusing: the backup has N migrations and this checkout only M. Check out a release at least as new as the backup (metadata.txt source_commit=...)"):
   check out that release or a later one.
2. **Attach the drive and choose the backup.** The desktop usually mounts it under `/media/$USER/`;
   otherwise `udisksctl mount -b /dev/sdX1` (find it with
   `lsblk -o NAME,TRAN,FSTYPE,LABEL,MOUNTPOINTS`: `usb`, `exfat`).

   ```bash
   DRIVE="/media/$USER/<label>"
   ls "$DRIVE"/warehouse-backups/*/                       # one folder per installation
   cd "$DRIVE/warehouse-backups/<state name>"
   sha256sum -c warehouse-<utc>.tar.enc.sha256            # the newest that says OK (.tar.sha256 for a readable archive)
   ```

3. **Restore.** Choose the state directory for this host. The original path is
   a good choice (the drive's folder name is its last part), but any new path
   works. Its parent must belong to you, and the state itself must
   not exist yet or be empty:

   ```bash
   export WAREHOUSE_STATE_DIR=/srv/warehouse/acme
   sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" "$(dirname "$WAREHOUSE_STATE_DIR")"
   npm run db:restore-host -- --state-dir "$WAREHOUSE_STATE_DIR" --backup-key ~/backup.key --yes \
     "$DRIVE/warehouse-backups/<state name>/warehouse-<utc>.tar.enc"
   ```

   The built images come from the saved tarballs when you have them: the `images` folder next to the archive (the USB backup
   puts it there, [Backup and restore](#backup-and-restore)) is used by itself when it holds the build record
   `image-recipes.sha256`, or name another folder with `--images DIR`; only the tarballs that record names are loaded, and only
   when the folder's signature (`SHA256SUMS.hmac`) checks out with your backup key: a folder named with `--images` that does not
   is refused before anything is created, one found next to the archive is ignored with the reason, and with `--allow-unsigned`
   saved images are not used at all. They are loaded with `docker load` and their build record adopted before the restore starts, so the
   `db`, `storage`, `functions` and `pdf-renderer` images are not built again (a build needs Docker Hub, Debian, npm and
   Chrome for Testing); a tarball that does not load is reported and that image is built as usual, and so is every image
   whose recipe in this checkout differs from the saved one. Then, when the checkout is exactly at a release tag (the code you cloned in
   step 1 was a tag), `restore-host` runs `bash scripts/build-images.sh --from-release` for the new state: an image that the saved images
   did not supply is pulled by digest from the release if the release published it for the same recipe ([Rerun and upgrade](#rerun-and-upgrade);
   it needs GitHub and `ghcr.io`), and the rest is built here as always; if that fails it says so and the restore below builds what is
   missing. A checkout that is not at a tag (a branch, `main`) builds every image that the saved ones do not cover. `scripts/restore.sh`
   itself is unchanged: it runs its own build step afterwards, which finds nothing left to build when the pulls succeeded.

   `--yes` confirms that the original host is permanently off. Before it creates
   the state the command checks, in this order: the archive, unopened, against its
   `.sha256` and its `.hmac` signature against your key (an archive without a
   `.hmac` file is not opened; copy the `.hmac` from the drive with the archive,
   and only an archive you packed yourself has none and needs `--allow-unsigned`);
   then, after unpacking into a temporary folder next to the new state (an
   encrypted `.tar.enc` is decrypted with the same key; the folder is removed
   again if anything fails), the backup inside: its signature, its contents
   (only the backup folder, no links, exactly the signed files) and its own
   checksums; that this checkout contains every migration the backup applied
   (otherwise it names the `source_commit` to check out); that no container and
   no database of this installation exists on the host; the host prerequisites; and 10 GiB of free space. For an archive it
   first checks that the disk holds twice the archive plus 1 GiB (the unpacked backup, then the stored files copied into the
   new state; an encrypted archive is also unpacked once) and stops, naming the numbers, before it writes anything.
   A backup that fails the signature check was changed after it was written or
   belongs to another installation: do not restore it. A backup of an older
   format than v5 is refused. A backup whose `SHA256SUMS.hmac` is missing is
   accepted only with `--allow-unsigned` and without `--backup-key`, for a drive
   that never left your custody; leave `--backup-key` out only when the key is
   really lost. The command then creates the state from the backup's `compose.env`
   and `instance.json`, changing only the three state-path lines (and installs
   `public/central-jwks.json` when the backup carries one), keeps a copy of the
   backup under `backups/`, and runs the in-place restore: a new database from
   the pinned image, replay of both databases and the stored files, integrity
   comparison, newer migrations, all services started and `doctor --local`. It
   ends by printing the remaining steps. A backup directory (already extracted)
   works as well as the `.tar`. If it fails after creating the state, it says so
   and how to start over; nothing else on the host is changed.
4. **Check the summary line.** The command prints the instance ID and the path the
   installation used before. Use `export WAREHOUSE_STATE_DIR=<the new path>` for
   every operator command on this host from now on.
5. **Prove it.** If you recorded a fingerprint with this backup:

   ```bash
   bash scripts/data-fingerprint.sh | diff ~/fingerprint-warehouse-<utc>.txt - && echo IDENTICAL
   ```

   A fingerprint recorded by another release can differ in its lines (see above); take a new fingerprint after upgrading.

   Otherwise sign in to the app and check the latest GRNs, dispatches and
   invoices you remember. Record the result.
6. **Bring the public address back.** If the backup carried the tunnel
   credential, `db:restore-host` put it in `config/tunnel/` and says so; then:

   ```bash
   sudo bash scripts/tunnel.sh install-service --state "$WAREHOUSE_STATE_DIR"
   node scripts/doctor.mjs
   ```

   Otherwise adopt your private copy first (`bash scripts/tunnel.sh adopt
   --config …` or `--token-file …`, as in
   [Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)), then run the same
   two commands. The DNS route already exists; do not create a new tunnel. If
   the credential is lost too, create a new tunnel and point the existing
   hostname at it in the Cloudflare dashboard, replacing the old tunnel's record.
7. **Central sign-in from a key file.** Skip this unless `CENTRAL_JWKS_FILE` is set
   in `config/compose.env` ([Central sign-in](#central-sign-in)). When the backup
   brought `public/central-jwks.json` back, `node scripts/doctor.mjs --local`
   confirms it. Otherwise run the `setup.sh --operator ... --central-issuer ...
   --central-jwks-file ...` command that `db:restore-host` printed, with your usual
   administrator phone and name and the key set the association sent you. Setup
   keeps the instance identity and the data and rebuilds the images once. Until
   then every central sign-in fails while the app still offers it, and `doctor`
   says so; SMS sign-in is unaffected.
8. **Protect the new host.** Set up the [USB backup drive](#usb-backup-drive)
   again (`sudo bash scripts/backup-usb.sh setup …`, then re-plug the drive) and
   check that a new backup appears next to the old ones. **The key copy confirmation is not on the rebuilt host**: the record
   `config/backup-key.escrow` lives in the state's `config/` and is not part of a backup, so on the new host the drive is not enrolled
   and no run writes until you confirm the key again. The restore has put the key itself back (`config/backup.key`, the copy you gave
   with `--backup-key`); as the installation user run `bash scripts/backup-key-escrow.sh confirm --key-file ~/backup.key` (or `show`
   in a terminal, and type the key back from your copy), then enrol the drive. `setup --enroll` and `enroll` say the same if you
   forget.

   Install the monitoring checker again too, with the command `db:restore-host` printed
   (`sudo bash scripts/watch-timer.sh install --state <state>`). The Slack webhook URL is a
   secret and is not in a backup: if this installation sent alerts to Slack,
   alerts are local only until you run `setup.sh --operator` again with your
   usual inputs, leaving out `--alert-webhook-file off` (it then asks for the URL on a terminal), or with `--alert-webhook-file` ([MONITORING.md](MONITORING.md#alert-delivery)).
9. **Rotate if the drive may have been exposed.** Unencrypted archives (a drive set up with `--no-encrypt`, or a drive that held readable archives that a run has since deleted: deleting
   does not wipe them from an exFAT drive) hold every key in plain text; an encrypted one is as safe as your key copy. `bash rotate-keys.sh --yes` replaces the signing keys (every phone
   signs in again). Rotate the MSG91 key in its console and apply it as in
   [Replacing MSG91 credentials](#authentication-and-otp-limits), replace
   the tunnel credential (see [USB backup drive](#usb-backup-drive)) and the
   passwords under
   [Secrets that rotate-keys does not change](#secrets-that-rotate-keys-does-not-change),
   then take a new backup.
### Secrets that rotate-keys does not change

`rotate-keys.sh` replaces the JWT secret and the two API keys derived from it. `compose.env`, and so every unencrypted
backup, holds more. After a backup medium was exposed, these stay valid until you change them by hand. Except
`SENSOR_INGEST_KEY`, which posts sensor readings through the tunnel and so must be replaced at once, none of them is usable
from the internet through the tunnel: they matter to someone who also reaches the host or its network.

| Secret | What it opens | How to replace it |
| --- | --- | --- |
| `CUPS_ADMIN_PASSWORD` | The CUPS administration page (printing profile). | Manual, below. |
| The Slack webhook URL (`config/slack-webhook-url`) | Posting messages to the facility's Slack channel, by anyone who holds the URL. | Revoke it in Slack (Apps → Incoming Webhooks) and create a new one, then rerun `setup.sh --operator` with your usual inputs and `--alert-webhook-file ask` (or a file holding the new URL; create it with `install -m 600 /dev/null FILE` and an editor, so the URL stays out of the shell history). |
| `TAPO_PASSWORD` (with `TAPO_USERNAME`) | The Tapo account of the hubs: the hubs on the LAN, and the account in the Tapo app and cloud (sensors profile). | Change it in the Tapo app, set the new value in `compose.env`, then `bash scripts/compose.sh --profile sensors up -d --force-recreate sensor-bridge`. |
| `SENSOR_INGEST_KEY` | Posting sensor readings to this installation's ingest function, from anywhere the gateway is reachable (sensors profile). | Mint a new key with a new label (`bash scripts/compose.sh exec -T db psql -X -qAt -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -v label=<new label> < scripts/sensor-ingest-key.sql`, which prints it once), set it, recreate the bridge, then revoke the old one (`bash scripts/compose.sh exec -T db psql -X -q -v ON_ERROR_STOP=1 -U supabase_admin -d postgres -c "UPDATE warehouse_security.sensor_ingest_keys SET revoked_at = now() WHERE label = '<old label>' AND revoked_at IS NULL"`); [SENSORS.md](SENSORS.md#ingest-keys). |
| `POSTGRES_PASSWORD` | The superuser login (`supabase_admin`), from inside the Compose network or the host. | `npm run db:rotate-passwords -- --yes --superuser`; see [Rotating the database passwords](#rotating-the-database-passwords). |
| `DB_PASSWORD_AUTHENTICATOR`, `DB_PASSWORD_STORAGE` (every install), `DB_PASSWORD_POOLER` (only after `pooler.sh on`) | Each one database login of one service (PostgREST, Storage, the pooler's pool user), from inside the Compose network. | `npm run db:rotate-passwords -- --yes`; see [Rotating the database passwords](#rotating-the-database-passwords). |
| `SECRET_KEY_BASE`, `VAULT_ENC_KEY` (only after `pooler.sh on`) | Pooler session signing; encryption of the pooler's stored tenant credentials. | No supported procedure yet; see below. |

These procedures are **not exercised by CI**. Take a `db:backup` first and check with `node scripts/doctor.mjs --local`
afterwards. The command for `CUPS_ADMIN_PASSWORD` (the rows above say how to set the others):

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup
new="$(openssl rand -hex 32)"
# Replace one line of the private configuration, keeping its mode (only where printing is used):
sed -i "s/^CUPS_ADMIN_PASSWORD=.*/CUPS_ADMIN_PASSWORD=$new/" "$WAREHOUSE_STATE_DIR/config/compose.env"
bash scripts/compose.sh --profile printing up -d --force-recreate cups
node scripts/doctor.mjs --local
```

`SECRET_KEY_BASE` (present only once the pooler has been turned on) signs the pooler's sessions and `VAULT_ENC_KEY` encrypts the pooler's stored tenant (which holds the pool
user's password). Changing them is not scripted and has not been rehearsed, so this guide gives no procedure that could
leave the pooler unable to read its tenant. They cannot be used from outside the host and its Docker network (the database
publishes no port and the gateway listens on loopback only); keep the host's logins and network closed. If you must replace
them now, rehearse on a copy first: restore the newest backup onto a spare machine with `db:restore-host`, try the change
there, and only then repeat it on the real host.

### Rotating the database passwords

Every database login has its own password in `compose.env`
([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#database-passwords-one-per-login)):
`POSTGRES_PASSWORD` is the superuser's (`supabase_admin`), and
PostgREST, Storage and the pooler's pool user (when it is on)
each sign in with their own. One command
replaces them:

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
npm run db:backup
npm run db:rotate-passwords -- --yes                # every service login
npm run db:rotate-passwords -- --yes --superuser    # also POSTGRES_PASSWORD
npm run test:db-roles                               # each login refuses the superuser password and takes its own
npm run db:backup                                   # older backups carry the previous values
```

What it does, in this order:

1. Writes new values into `config/compose.env.rotating-db` (only those lines
   differ from `compose.env`).
2. Sets them in the database in one transaction, signed in with the current
   superuser password. It sends SCRAM verifiers on standard input, never the
   passwords, so nothing reaches a log, an argument list or
   `pg_stat_statements`.
3. Keeps the previous file as `config/compose.env.before-db-rotation`, puts
   the new one in place, and recreates the database and every running service
   that signs in to it (PostgREST, Storage, and the pooler when it runs). The
   command takes about a minute, with about 11 seconds in which the app cannot
   load data. A service you stopped on purpose stays stopped and reads its new
   value when it next starts. No session ends and no phone signs in again: the
   JWT signing keys are `rotate-keys.sh`'s.
4. Proves each login (`npm run test:db-roles`) and runs `node scripts/doctor.mjs --local`.
   If a service does not come back or a login misbehaves, it sets the previous
   values in the database again, moves the previous file back, recreates the
   services and exits with an error: nothing is rotated.

If the command stops half-way (a power cut, a killed shell, a full disk), it
leaves `compose.env.rotating-db`, `compose.env.before-db-rotation` or both
behind. Do not move or delete them yourself: run
`npm run db:rotate-passwords -- --yes` again. It does not rotate then; it finds
out which values the database has by signing in over the network with each
file's values, keeps the file that matches as `compose.env`, removes the others
and says so. Then do what its last line says: run `bash start.sh` so every
service uses these values, check with `npm run test:db-roles`, and rotate again
if you still want new ones. If the database is not running, start it alone
first (`bash scripts/compose.sh up -d --wait db`). If the database takes the
values of none of the files, or gives no clear answer, the command changes
nothing and says so; keep every file and ask for help, quoting the message.

A restore of a backup taken before a rotation brings that backup's values
back together with its data (`db:restore -- --restore-config`, or
`db:restore-host`); the restored database gets them at start.

## Pooler (optional)

The pooler (supavisor) is off by default; a new installation has no pgbouncer role, schema or `get_auth`, no `_supabase` database and no
`DB_PASSWORD_POOLER`, `SECRET_KEY_BASE` or `VAULT_ENC_KEY` (`compose.env` has `POOLER_ENABLED=false`). It needs a running, healthy
database and takes the operator lock.

```bash
bash scripts/pooler.sh on       # generates the three secrets where missing, creates role pgbouncer, schema pgbouncer (get_auth) and
                                # database _supabase (scripts/configure-pooler.sql), records POOLER_ENABLED=true, starts supavisor
                                # with --profile pooler up -d --no-deps (db is not recreated); idempotent
bash scripts/pooler.sh off      # stops and removes the container, records POOLER_ENABLED=false; deletes nothing (role, schema,
                                # database and secrets stay, the pgbouncer password is not rotated while off; `on` reuses them)
bash scripts/pooler.sh status   # prints on, off or unset
```

After an in-place or lost-host restore the pooler is not started (the restore starts the core services only); while `POOLER_ENABLED=true`
the restore recreates its role, schema and `_supabase` database, and `bash scripts/pooler.sh on` starts it again. Test: `npm run test:pooler`.

## Rerun and upgrade

A rerun is the same `setup.sh --operator ...` command with the same inputs against the same state directory. It
regenerates nothing that already exists: identity, signing keys, database, stored files, the administrator and the provider
lines are preserved (a different `--provider-env` file replaces only the MSG91 lines; the `--central-…` options set or
replace only the [central sign-in](#central-sign-in) lines and its key file; `--gateway-port` replaces only
`GATEWAY_HTTP_PORT`, and only while the containers are stopped). A rerun never replaces the per-role database passwords or the backup key. Run it a second time right after installation and compare
`public/instance.json` and the administrator record before and after.

**Operators follow release tags (`vMAJOR.MINOR.PATCH`), not `main`.** `main` is where development happens, and a commit on it
can carry changes that were never released. A release is a tag with a GitHub release note; a security fix is announced in a
release note with "Security" in its title, and is supported for the current and the previous minor line ([SECURITY.md](../SECURITY.md)).
Read the release note, then upgrade within one PostgreSQL major (a move to a new PostgreSQL major is a manual step that
`upgrade.sh` refuses; the release that brings it documents the steps, see [Major PostgreSQL upgrade](#major-postgresql-upgrade)):

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
bash upgrade.sh --dry-run vX.Y.Z       # first: runs every check, prints what the release asks of you and the plan, changes nothing
bash upgrade.sh vX.Y.Z                 # then the real run, once you have done what the dry run listed under "before"
sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR"   # only if you use a USB backup drive
```

**Run the dry run first, and do what it lists under "before".** `upgrade.sh` holds the operator lock from start to end (the monitoring checker
judges nothing meanwhile; its `operator_lock_stuck` alert fires after 2 hours, or after twice the time of the last backup plus the last verify when that is longer) and prints the operator actions of `CHANGELOG.md` between your
release and the new one **twice**: first, before anything is changed, as part of the release's preflight (below), and again at the end. The first
print is the dry run's: the real run prints it too, but then the backup follows. At a terminal the real run waits after the list when it has
operator actions, as the last step of the preflight (after the host, floor, room and rehearsal checks; "Press Enter to continue, Ctrl-C to stop"; the lock is held while it waits, and Ctrl-C releases it with nothing changed; with no answer for 30 minutes the upgrade stops by itself, also with nothing changed);
`--yes` skips that pause, and a run without a terminal (cron, CI, `ssh host command`, `</dev/null`) never pauses, so an action that says
"before" is done only if the dry run was read.

*The preflight.* `upgrade.sh` is the script of the release you run now, so it cannot know what the release you move to needs. Each release
carries `scripts/upgrade-preflight.sh`; `upgrade.sh` reads it, and the files it names, out of the release's commit (`git archive`), runs it
from a temporary directory before the backup, and a `--dry-run` runs it too. The preflight prints the operator actions of `CHANGELOG.md`
for the whole span, checks the host against what **that** release needs (the Node.js version, Docker and the Compose plugin, `rsync` and
`tar` with extended attributes, free space: the same checks as the release's own `setup.sh`, so a host that would fail after the checkout
fails now), and enforces the oldest release it accepts an upgrade from (`scripts/upgrade-floor.txt`: an older installation is told which
release to upgrade to first, then to run the command again). It also refuses when the free space is below the stored files of the newest
verified backup plus its database dump plus 1 GiB, because the way back from the upgrade is an in-place restore ([Disk space](#disk-space)).
*The rehearsal.* The preflight also applies the release's migrations to a disposable copy of your data: it restores the newest verified backup
(`config/backups-verified.list`) into a network-isolated container (`scripts/verify-restore.sh --keep`), runs the release's migration plan on
it (`scripts/upgrade-rehearse.sh`), prints `applying them took N s` (only the migrations are timed) and removes the container. The live database and its files are only read, so a
`--dry-run` rehearses too. A migration that fails on your data refuses the upgrade before the backup and the checkout: the message names the
file (for example `00000000000117_customer_name_rule.sql`) and the database's own error, and says "Nothing was changed". Do not retry the same
command: the failure is in the data or in the release, and it repeats. Report the message with the release number. The rehearsal is of the newest verified backup, not
of the moment: it prints that backup's name and age and warns when it is more than two days old. A backup only counts once it is verified and
recorded: the nightly pass does that, and so does `upgrade.sh` for the backup it takes; to do it by hand run `bash scripts/backup.sh`, then
`bash scripts/verify-restore.sh <the new folder under backups/>`, then `node scripts/watch.mjs record-verified <its name>`. If the copy cannot
be restored, the refusal quotes the restore's own last message: the host (free disk space or memory, a database image that has to be pulled
while the host is offline) is as likely a cause as the backup. With no verified backup on record it warns that it did not rehearse and the
upgrade goes on (the migrations then run for the first time on the live database, after the checkout).
Any refusal says "Nothing was changed". The facility is closed to phones for the backup, the proof that it restores and
the setup of the release (*While it upgrades*, below). **Run it inside `tmux` or `screen` when you are connected over SSH:** a dropped connection stops it
half way (the rerun below finishes it, but there is no reason to need that). Run it as the installation user, not with `sudo`.
**It refuses, and changes nothing,** when: it runs as root, or the checkout belongs to another user; the checkout has uncommitted changes
to tracked files, or untracked files stand where the release has files of its own; the
argument is not a release tag that exists on `origin` (`--ref COMMIT_OR_BRANCH` opts out, with a warning, for tests and development;
only tags are supported); the local tag differs from origin's (a moved tag); the release does not contain `upgrade.sh`; the checkout is
already past the release (it contains it, or sits on a higher release number: `upgrade.sh` only moves forward, wait for the next release);
the release runs another PostgreSQL major, or the database server does (follow [Major PostgreSQL upgrade](#major-postgresql-upgrade);
`upgrade.sh` then works again for later releases); the database recorded migrations the release does not contain (a new baseline, or an
older release: [Baseline reload](#baseline-reload)); `--admin-phone` is not the facility's administrator; the stored Slack webhook file
is not a Slack URL; the database is not answering (unless an interrupted upgrade is recorded, below); the release's own preflight refuses
(above); a `psql` session from outside the stack is open on the database (*While it upgrades*, below). The checkout ends detached at the
tag, whatever branch it was on; that is expected.

*While it upgrades.* An upgrade is a planned downtime. From before the backup to the end of the setup of the release nothing may write to the
database, or the way back (an in-place restore of that backup) would lose it without a trace. So after the preflight, and before the backup,
`upgrade.sh` closes the API to phones (**maintenance mode**, `bash scripts/maintenance.sh on`), and it opens it again after the setup of the new
release (`off`, which also runs the health check).

- **How long, and when.** The facility is closed for the backup, the proof that it restores, and the setup (building the images the release
  changed, the migrations, the restarts). Run it **after hours**, and plan from your own numbers: the newest backup's `duration_seconds=` in
  its `metadata.txt`, the seconds the last verify took (the third field of its line in `config/backups-verified.list`, which `upgrade.sh`
  writes when it proves a backup), and the setup of the release. The monitoring checker uses the same numbers: while an upgrade is recorded
  it calls the operator lock stuck only after twice the last backup plus the last verify (never under 2 hours, never over a day).
- **What phones get.** Both gateways (`gateway`, and `gateway-lan` while the [LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network)
  runs) answer every request for `/rest/v1/`, `/storage/v1/` and `/functions/v1/` with HTTP **503**, `Retry-After: 120` and the body
  `{"code":"upgrading","message":"The facility's server is being updated. Try again in a few minutes."}`, whatever the request's key or path.
  The CORS preflight and `X-Warehouse-Path` are as always, so an app can read the answer; `/health` and the paths that were never routes
  are unchanged. An app that knows the code can show the message; an app that does not treats it as any failed request. The nightly
  backup stops `gateway-lan` with the gateway too, so the dump is consistent for phones on the warehouse network as well.
- **fas-sync.** It writes straight to the database (`docker exec ... psql`), not through the gateways, so closing the API does not stop it
  and `upgrade.sh` cannot. **Pausing it is your job** (let its run finish and do not start another until the upgrade has finished). The
  plan says so, and as a safety net the real run **refuses to start, changing nothing,** while a `psql` session from outside the stack is open on the
  database. That check sees only a session that is open at that moment: it catches a `psql` someone left open, but fas-sync opens a session for
  each statement, so a run that is between two statements is usually not seen, and passing the check does not show that fas-sync is paused.
  (A session of `psql` is how fas-sync and anyone with `docker exec ... psql` connect; the services of the stack connect under
  their own names, and the operator scripts do not run beside `upgrade.sh`, which holds the lock). It looks twice, three seconds apart, so a
  session that is just ending does not count; `--dry-run` only warns. A session opened after that check is not stopped: keep fas-sync off
  until the upgrade is done.
- **When it stops.** Once the checkout has moved to the new release the API **stays closed**: the facility may be half upgraded, and `start.sh`, a restore
  or the next release's setup all keep it closed until a person decides (`config/maintenance` is the marker; `scripts/compose.sh` gives
  every Compose command `WAREHOUSE_MAINTENANCE=upgrading` while it exists). The printed way forward ends with the rerun, which opens it when it
  succeeds; the way back has the line that opens it. A failed check, backup or proof, before anything was changed, opens it again by itself. The
  checker raises `upgrade_interrupted` at once ([MONITORING.md](MONITORING.md)) and does not restart services meanwhile.
- **By hand.** `bash scripts/maintenance.sh status` says whether it is on and what each gateway was started with (it works while an upgrade
  holds the lock); `on` and `off` take the lock. `off` recreates the gateways without the word and runs the health check; if the gateway does
  not come up the marker is put back, so the API is closed or down and never half open.

*The setup arguments.* You do not repeat them: `setup.sh --operator` needs `--state-dir`, `--admin-phone` and `--admin-name`, and every other
option keeps what the state holds on a rerun (identity, URLs, provider lines, central sign-in, gateway port, letterhead, signing keys).
`upgrade.sh` passes `--state-dir "$WAREHOUSE_STATE_DIR"` and reads the administrator from the database (any active approved administrator
satisfies setup's check; the name is only used when none exists). The one thing a state cannot show is "no Slack webhook": when none
is stored it passes `--alert-webhook-file off` again, so setup does not stop to ask. To change something in the same step, or to
give another administrator, add `--admin-phone 91XXXXXXXXXX --admin-name NAME` before the tag, and options for setup after `--`, for
example `bash upgrade.sh v0.8.0 -- --alert-webhook-file /secure/slack.txt --gateway-port 18001`.

*If it stops.* Before its first change `upgrade.sh` writes `$WAREHOUSE_STATE_DIR/config/upgrade-in-progress` (mode 0600): the old
commit, the target, the setup inputs and the current step, whether the release had a preflight (`preflight=ok` or `absent`) and the tag of the
saved images (`pre_images=`), whether it closed the API (`maintenance=on`; `maintenance=opened` once it was opened and only the health check after that failed); once the backup has been proved to restore, also the path of that backup.
The file is deleted when the upgrade succeeds, and while it exists `doctor`, `start.sh`, `bash scripts/watch-timer.sh status` and
`node scripts/watch.mjs status` say "an upgrade from X to Y was interrupted at step Z" (a run killed by a power cut or a lost SSH
connection leaves it too). A failed step prints the same facts, then both ways out.

- *Finish it.* Fix the cause shown above and run **the same command again** (it prints it). The rerun reads the record, reuses the
  verified backup and **takes no new one** (a backup of a half-upgraded database is not a way back), takes the old commit from the
  record, and goes on with the checkout (skipped if it was done) and setup. It also works when the database is down: setup starts it,
  and the administrator comes from the record. A different release is refused while the record exists. The API stays closed meanwhile
  (the rerun closes it again if it was opened) and is opened when the rerun succeeds, or by `bash scripts/maintenance.sh off`.
- *Go back to the old release.* Everything the facility recorded after the backup is lost; the API was closed from before the backup, so
  that is only what reached the database another way (fas-sync if it was not paused, a `psql` session). In the checkout, in this order (it
  prints them with your values, and `node scripts/upgrade-record.mjs rollback` prints them again from the record):

  ```bash
  (umask 022; git checkout --detach <old commit>)
  bash stop.sh
  bash scripts/pre-images.sh restore <old release>                 # only when the upgrade saved the images (below); setup then normally builds nothing
  npm run db:restore -- --yes --restore-config <the backup>
  bash setup.sh --operator --state-dir "$WAREHOUSE_STATE_DIR" --admin-phone 91XXXXXXXXXX --admin-name NAME    # the old release's setup
  bash scripts/build-images.sh --save                              # only after pre-images.sh restore: saves the old images again (below); builds nothing
  bash scripts/compose.sh up -d --force-recreate --no-deps --wait --wait-timeout 180 functions
  bash scripts/maintenance.sh off                                  # opens the API again (the upgrade closed it) and runs the health check
  node scripts/doctor.mjs --local
  rm -f "$WAREHOUSE_STATE_DIR/config/upgrade-in-progress"          # only when the facility is healthy on the old release
  ```

  `--restore-config` is needed because the new release's setup usually rewrote `compose.env`, and the restore refuses a `compose.env`
  that differs from the backup's. The restore also refuses, before it moves anything, a checkout whose migrations are fewer than the
  backup's or differ from them: check out the commit the backup was made on (the line above does). `start.sh` never builds images, so the
  old code would run on the images the new release built: the old release's `setup.sh` removes the containers of services only the new
  release has, and it builds the images the new release changed, unless the upgrade saved the old ones: before the checkout `upgrade.sh`
  tags every image the running services use as `<project>-<service>:pre-<old release>` and keeps a copy of the build record
  (`config/image-recipes.pre-<old release>.sha256`); `bash scripts/pre-images.sh restore <old release>` points the installation's image
  names at them again and puts the record back, so setup finds the images current and normally builds nothing and needs no network (an
  image that was not in the saved set is still built; that needs the network). Because setup then finds nothing to build, it also saves
  nothing, and `<state>/images`, the signed copy of the images that a lost-host restore loads first, would still hold the new release's
  images: `bash scripts/build-images.sh --save` after the old release's setup writes the images that now run, and their build record, there
  again (it builds nothing). After a successful upgrade only the newest `pre-` set is kept (older tags are removed by exact name; `docker image prune` is never run);
  remove the last one with `docker image rm <project>-<service>:pre-<release>` once the upgrade is accepted. Add `--alert-webhook-file off` to the setup line when the facility has
  no Slack webhook (the printed line does).

Every run that gets past the checks adds a line to `$WAREHOUSE_STATE_DIR/config/upgrades.log` (UTC time, from, to, the old commit,
the backup, `resumed` for a rerun, then `ok` or the step it failed at).

<details>
<summary>What upgrade.sh does (the manual sequence, when you want each step by hand)</summary>

```bash
cd /path/to/installed/backend
export WAREHOUSE_STATE_DIR=/absolute/path/to/this/warehouse
git status --short                     # must print nothing for tracked files
git fetch --tags origin
bash scripts/maintenance.sh on         # closes the API to phones (pause fas-sync first)
npm run db:backup                      # prints the backup directory
npm run db:verify-restore -- "$WAREHOUSE_STATE_DIR/backups/warehouse-<utc>"
(umask 022; git checkout --detach vX.Y.Z)
bash setup.sh --operator --state-dir "$WAREHOUSE_STATE_DIR" --admin-phone 91XXXXXXXXXX --admin-name 'Warehouse Administrator' \
  --alert-webhook-file off             # the same inputs as the installation; leave the --alert-webhook-file line out when a Slack webhook is stored
bash scripts/maintenance.sh off
node scripts/doctor.mjs                # the public check; setup has just run the local one
sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR"   # only if you use a USB backup drive
```

1. `git fetch --tags origin` (the script fetches first, so that it checks the tag against origin).
2. Take the operator lock, so that no other operator command and no checker pass interleaves (`upgrade.sh` holds it for all of the steps).
3. Refuse if the checkout is dirty, if the tag is not on origin, if the checkout is already past it, if the release changes the PostgreSQL
   major, if the ledger holds migrations the release lacks, or if the release's own preflight refuses (`scripts/upgrade-preflight.sh`, read
   out of the release's commit; by hand, read the release's section of `CHANGELOG.md` and the free space first, [Disk space](#disk-space)).
   Write `config/upgrade-in-progress`.
4. Close the API (`scripts/maintenance.sh on`), then `db:backup`, then `db:verify-restore` of that backup. Both run on the OLD release: a backup of the new code on an old database
   would carry the wrong image label. The proved backup is put on `config/backups-verified.list` (`node scripts/watch.mjs record-verified`),
   so the nightly pruning keeps it like a nightly backup that passed its verify (the newest of its migration state for 60 days).
5. Tag the images the running services use as `<project>-<service>:pre-<old release>` (`scripts/pre-images.sh tag`), then a detached
   checkout of the tag under `umask 022`.
6. `setup.sh --operator` of the NEW release: rebuilds the images whose recipes changed, applies the new migrations, applies the roles and
   configuration, restarts the services whose definition changed, **recreates the `functions` container** and runs
   `node scripts/doctor.mjs --local`. The edge functions (`functions/`, including `functions/_shared/`) are bind-mounted into the
   `functions` container and the edge runtime keeps the modules it has loaded, so neither a checkout nor a start reloads them; forgetting
   the recreate is the usual way to run new SQL under old function code. Setup does it on every run.
   The marker `config/maintenance` is still there, so the gateways that setup recreates come back closed, and `doctor --local` says it could not probe
   the API through them.
   Then `scripts/maintenance.sh off` of the new release opens the API and runs the health check.
7. The public `node scripts/doctor.mjs`, which `upgrade.sh` leaves to you.
8. A line in `upgrades.log`, the record deleted, and the `pre-` image tags of earlier upgrades removed.

The last manual line keeps the USB choices of your earlier setup (`--no-encrypt` if you typed it, `--daily`, `--no-fresh-backup`, `--keep`); it prints them, so
check that line. Database migrations need no separate step: setup applies them. If setup prints a
`sudo bash scripts/watch-timer.sh install …` command, run it.

</details>

**Setup rebuilds the images whose recipes changed, or pulls the released ones.** Before it starts
anything, `setup.sh` runs `scripts/build-images.sh --from-release`. That script compares each
image recipe (the files under its `docker/` build directory, its Dockerfile
path, build target and build arguments) with a record of what it built last
(`config/image-recipes.sha256` in the state directory) and rebuilds the images
whose recipe differs or whose tag no longer names the image it built. Setup's
start then replaces only the containers whose image changed. What to expect:

- A state with no record (a new one, or one made by `restore-host` without saved images) rebuilds
  every image in use once. That needs the network and can take a good while on
  a small machine; later reruns print "Images match their recipes; nothing to
  rebuild." and need no network.
- **At a release tag, an image that needs building is pulled when the release published it.** A checkout exactly at a tag
  (`vX.Y.Z`, which is what `upgrade.sh vX.Y.Z` leaves and what a fresh clone of the tag is) downloads that release's
  `release-images.json` from the GitHub Release (https, one file, 60 seconds). The release workflow built every image of the tag
  without the build cache, scanned it with the exception ledger ([CONTAINER_SECURITY.md](CONTAINER_SECURITY.md#exception-ledger-and-the-image-scan))
  and pushed it to `ghcr.io/abhiguru/supabase-warehouse-template/<service>`; the file lists each image by digest with the fingerprint of
  its recipe. For each service setup would build whose fingerprint equals the one in the file, it runs `docker pull` of
  `<service>@sha256:<digest>`, checks that the image on the host carries that digest, tags it `<project>-<service>` and records it as a build
  would, so nothing downstream differs. It prints which services were pulled and which built, for example
  `Pulled 4 image(s) from the release (db functions pdf-renderer storage) and built 1 here (gateway).` Everything else builds here as
  always, with one line that says why: a checkout that is not at a tag (`main`, a branch, a copy you changed), a release whose file
  is missing or cannot be read (the release is still a draft, GitHub or `ghcr.io` cannot be reached), a file that names another
  commit or release, or a reference outside `ghcr.io/abhiguru/supabase-warehouse-template`, a recipe in your checkout that is not
  the released one (a file below `docker/<service>` is not as released: changed, but also untracked or ignored, such as a `.env` left in `docker/sensor-bridge` or a `__pycache__` folder), an image that cannot be pulled, or one whose digest is not the one asked
  for. Nothing is fetched when no image needs building. Pulling needs about the same disk and less time than building; it
  does not need Debian, npm or Chrome for Testing to answer. The trust is GitHub's account of the repository, as for `git fetch`: the
  digest pins the content, the file and the images come from the maintainer's account over TLS, and nothing new is installed on the host.
- After a build or a pull, every image is also written to `$WAREHOUSE_STATE_DIR/images/<service>.tar` (an older tarball of
  that service is replaced) and the folder is signed with the backup key. See [Backup and restore](#backup-and-restore) for what
  they are for; the USB backup copies the folder to the drive. A save that fails is a warning, not a failed build.
- A build, or a pull, needs the network when a recipe changed. If a build fails, setup stops
  before it starts or stops anything and records nothing as built. Running
  services stay as they are. Run setup again when the network is back rather
  than leaving the installation half way.
- **Setup tries the address once and warns.** With `--central-jwks-url`, setup fetches it from this host (10 seconds, no
  redirect) after it has written the state. If that fails (no connection, an error status, an answer that is not JSON or has
  no `keys` list) it prints "Warning: could not fetch the central keys from ... (reason)" and carries on, because a host may
  be set up before it is online. A pass proves only that **this host** can reach the address, not that the `functions`
  container can; a wrong or unreachable address still shows at the first sign-in as "temporarily unavailable". Test it from
  this host first: `curl -fsS https://login.association.example/.well-known/jwks.json`. A host resolver that cached an
  NXDOMAIN answer fails here too ([TROUBLESHOOTING.md](TROUBLESHOOTING.md#tunnel-and-public-address)).
- **The app must be built for central sign-in too.** The backend setting alone leaves the app on its single "warehouse
  server" screen: build the app with `EXPO_PUBLIC_CENTRAL_ORIGIN=https://login.association.example` (the app repository's
  `.env.example`). The value is inlined when the app is bundled, so restart Metro with `--clear` after changing it.
- **The central service has its own Cloudflare Tunnel and hostname**, separate from this facility's; see the OPERATOR.md of
  the central identity repository ([CENTRAL_LOGIN.md](CENTRAL_LOGIN.md#built-and-not-built)).
- The pooler's objects follow `POOLER_ENABLED` (see [Pooler (optional)](#pooler-optional)).
- Optional services (`printing`, `pooler`, `sensors`) are rebuilt only if
  this installation has a container of them, and setup replaces the running
  ones whose image or configuration changed. A failure there is printed as a
  warning; the core services stay up. A running optional service whose image
  does not match this checkout is left running with the warning "the
  <service> image does not match this checkout"; `bash scripts/build-images.sh`
  or the next setup rerun builds it, and the following start replaces it.
- An optional service switched on after setup (`compose --profile printing up`, `scripts/pooler.sh`) is built here by Compose on its
  first start, from the recipes in the checkout; it is not pulled from the release, because the pull belongs to setup's build step, which
  covers the images in use at that time.
- `start.sh` never builds: a host that restarts offline starts what it has.
- Every built image is tagged for its installation (`<project>-<service>`).

The build cache also keeps the operating-system packages of the day an image
was first built. Now and then, rebuild without it:
`bash scripts/build-images.sh --no-cache`, then `bash start.sh`.
`bash scripts/build-images.sh --all` rebuilds everything in use with the cache. Both build here, from the recipes in the checkout, and never pull;
`bash scripts/build-images.sh --from-release` is what `setup.sh` runs (it can be run alone, under the operator lock).

Update the checkout under `umask 022`, as for the first clone. Git writes the
files it changes with the current umask: Ubuntu's default `0002` makes them
group-writable, which the root-run backup helpers refuse, and `077` makes them
unreadable by the containers. `setup.sh` restores the modes of every tracked
file on each run, and `bash scripts/checkout-permissions.sh` does the same on
its own, for example after a `git pull` or `git checkout` made without
`umask 022`.

The rerun applies only the migrations the ledger has not seen (append-only and
checksum-verified; a changed applied file is refused) and recreates the
services whose definition changed. Read `CHANGELOG.md` for the release first:
a release that changes the mobile contract needs the matching app build. If
the upgraded instance is rejected, stop it and restore the pre-upgrade backup
with the in-place restore above.

## Baseline reload

A script that refuses with a message naming "Baseline reload" has found a database or a backup that this checkout cannot
use as it is. Nothing was changed when it refused. Which case you have:

- **The checkout is older than the database, or the release was rebuilt on a new baseline.** The migration ledger guard
  stops `scripts/migrate.sh`, `setup.sh` and `upgrade.sh` when the database recorded a migration the checkout does not
  contain. `scripts/migration-plan.mjs` words it: "This database recorded migrations that are not in this release ...
  or it is newer than this checkout (check out the release that recorded those migrations)". For `migrate.sh` and
  `setup.sh` on a fresh installation this means the checkout is older than the database: check out the release that
  recorded those migrations, or a later one, and run the command again. `upgrade.sh` takes a target and only moves
  forward: it says that either the target release was rebuilt on a new baseline, which cannot be applied in place (the
  release note of that release gives the reload), or the target is older than the release that recorded the migrations;
  for an older target, name the release that recorded them or a later one.
- **The database or backup was made on another database image.** `setup.sh`, `start.sh`, `rotate-keys.sh` and
  `rotate-db-passwords.sh` (`scripts/db-version-preflight.sh`) refuse data from before PostgreSQL 17 ("... cannot start on
  that data ..."). `db:backup` refuses a running database that is not on this release's database yet ("This installation has not been
  moved to this release's database yet"; it names "Major PostgreSQL upgrade" and "Baseline reload"). `db:restore`, `db:restore-host` and `db:verify-restore`
  refuse a backup made on the `supabase/postgres` image, a backup with no `database_image=` line, a dump from PostgreSQL
  older than 17, and a backup whose `roles.txt` lists a role this version does not have. No installation made with this
  release has such data, so a fresh install does not meet this case. The conversion procedure (a data-only dump loaded into a
  new cluster that this release builds) is in this guide as it stands on main at commit `b45ae0b`
  (`git show b45ae0b:docs/OPERATOR_INSTALL.md`); the old schema's migration files and the release that can restore such a
  backup are in the git tag `migrations-pre-baseline`.


## Major PostgreSQL upgrade

A move to a new PostgreSQL major version is a manual backup-and-restore move, because the data files of one major do not
open in the next. The scripts refuse it before they change anything:

- `bash upgrade.sh` stops when the release runs another PostgreSQL major than the checkout ("A new PostgreSQL major
  cannot be applied in place: follow docs/OPERATOR_INSTALL.md, `Major PostgreSQL upgrade`") or when the database server runs another
  major than the checkout says.
- `setup.sh`, `start.sh`, `rotate-keys.sh` and `rotate-db-passwords.sh` stop (`scripts/db-version-preflight.sh`) with "This release runs PostgreSQL <new> and cannot
  start on PostgreSQL <old> data. No database, container or image was changed. The data moves with a major upgrade: back up
  with the checkout that runs PostgreSQL <old>, then restore on this one".

The way forward is the ordinary backup and [in-place restore](#in-place-restore-of-the-same-instance) taken across the two
releases: back up with the checkout that runs the old major, check out the release with the new major, restore. The release
that brings a new major documents the steps, the way back and the disk it needs, in its release note and in this section. Nothing
is needed on an installation that already runs the release's major. The procedure for 17 to 18 is in this guide as it stands on main at
commit `b45ae0b` (`git show b45ae0b:docs/OPERATOR_INSTALL.md`).

### Collation changes

Text indexes (customer names, document numbers, the search fields) store strings in the order the C library of the **database image**
gives them. PostgreSQL records the library's collation version when the database is created (`pg_database.datcollversion`) and asks
the library for it again when a session connects to the database (`pg_database_collation_actual_version`), and warns there when the two
differ. When they differ, the order the indexes were built in may no longer be the order the library produces: a lookup can miss a row
that exists, and a unique index can accept a duplicate. The recorded version is the glibc release only (for example `2.41`), not the
Debian revision: a collation change that a Debian update backports inside one glibc release is invisible to this check, and the
changelog reading that the guard in `docker/postgres/Dockerfile` asks for is the only defence against it.

`node scripts/doctor.mjs` (also `--local`, which `setup.sh` and `start.sh` end with) compares the two for the `postgres` database and
fails with `collation version changed; REINDEX required before use`; `rotate-keys.sh` and `db:rotate-passwords` run the same check
(`node scripts/doctor.mjs --collation`) before they change anything and refuse on it. The database image's own guard refuses to build a
base image whose `libc6` or `locales` differ from the recorded versions, so the usual cause is that a glibc update was accepted into that
line on purpose, or that a data directory was kept across a database image with another glibc. Do not use the facility for writes until
it is repaired. The repair, with the API closed so that nothing writes meanwhile. Every database the query lists is repaired before
the query is run, and maintenance stays on until the query prints nothing and `doctor` passes:

```bash
npm run db:backup
bash scripts/maintenance.sh on
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c 'REINDEX DATABASE postgres'
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c 'ALTER DATABASE postgres REFRESH COLLATION VERSION'
# Only when the pooler is on: its _supabase database, the REINDEX connected to that database.
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d _supabase -c 'REINDEX DATABASE _supabase'
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c 'ALTER DATABASE _supabase REFRESH COLLATION VERSION'
# Only when the query below lists template1: its version alone is refreshed, from -d postgres, with no REINDEX.
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -c 'ALTER DATABASE template1 REFRESH COLLATION VERSION'
bash scripts/compose.sh exec -T db psql -X -U supabase_admin -d postgres -At -c "SELECT datname FROM pg_database WHERE datcollversion IS NOT NULL AND datcollversion <> pg_database_collation_actual_version(oid)"
node scripts/doctor.mjs --local
bash scripts/maintenance.sh off
```

`REINDEX DATABASE` rebuilds every index outside the system catalogs (since PostgreSQL 16 it skips them; harmless, they use the `C`
collation) and blocks writes to each table while it works, so the downtime is the time to
build all indexes from nothing; it grows with the database, and is not measured here: try it on a restored copy of the newest backup
first and plan the window from that. The query lists databases whose recorded version still differs (a database with no recorded version
passes, as in the doctor); it should print nothing before you run `doctor` and turn maintenance off. `template0` needs nothing: initdb
records no collation version for it, and it holds no collation-dependent objects. `template1` holds no index that depends on the C library
either (the catalogs use the `C` collation), so when the query lists it, only its version is refreshed, and the `ALTER DATABASE template1`
line is the whole repair.
If the doctor says it could not read the version, run the `SELECT` of the block above by hand; the check retries three
times before it gives up and then fails closed.

**The rule.** The Debian base of the database image is never changed in place. A base change (a new Debian release, a different glibc
line) happens only through the dump-and-restore major move, which rebuilds every index in the new image: one scripted move per
facility, planned for the first half of 2029, with the PostgreSQL major ([MAINTENANCE_CALENDAR.md](MAINTENANCE_CALENDAR.md)). Until
then the glibc guard line moves only with a Debian update of the same glibc series, after reading the glibc changelog for collation
changes.

## Windows host (Ubuntu in WSL2)

A Windows host runs the same Linux stack inside Ubuntu 24.04 under WSL2, with Docker Engine installed inside Ubuntu. A
virtual machine product (VMware Workstation or similar) with Linux inside Windows is not a supported route. Docker Desktop
and running the scripts from Git Bash or PowerShell are not supported either: `setup.sh` already stops at its first checks
there, because the scripts need Linux file modes, `flock`, `rsync`, systemd and `sudo`.

After the Windows-specific steps below, every command is the Linux one in this guide, typed inside Ubuntu. Marks used in this
section: **Verified** means the step was run on a real Windows host and worked; **Not verified yet** means it is written from
the documentation of the tool and has not been run. Where a step is not verified, check it on a host that serves no live facility
first. Shell tags: **[PS-admin]** is an elevated PowerShell on Windows, **[PS]** an ordinary PowerShell, **[Ubuntu]** a shell
inside the distro.

What was verified, on Windows 10 22H2 with WSL 3.0.1 (and 3.0.3 as offered by the update) and Ubuntu 24.04: a fresh install that follows this text from
the top (with passwordless `sudo`), the power settings, the install (`setup.sh`, `doctor --local`, the gateway test), a backup
with `db:verify-restore`, the monitoring and boot units, a Cloudflare tunnel created with `tunnel.sh create`, adopted and
installed as a service (the external doctor, run on the host, healthy), a reboot with nobody signed in, recovery after
`wsl --shutdown`, `wsl --terminate` and a host reboot, disabling and enabling the keep-alive task for planned work, a WSL update
(with the task disabled), and a USB backup drive passed into the distro with `usbipd-win` (enrolled, and one automatic run
copied and verified), and the sensor bridge's `--once --dump` check against Tapo H200 hubs ([Sensors (Windows)](#sensors-windows)).

Also verified, with both tasks registered by `scripts/windows/register-tasks.ps1` (Windows 10 Pro 22H2): after `Restart-Computer`
and after `wsl --shutdown`, with no one touching anything, the distro came back by itself (about 1 minute), `usbipd-win` attached
the USB drive again within about 1 minute of that, the USB backup unit ran after the stack unit and succeeded, and the monitoring
checker raised no false alert. A console session was signed in again after the restart (Windows auto logon, apparently), so the
test did not show the tasks working with nobody signed in. The tasks store the account's password and should not depend on a
signed-in session, but that was **not tested** with auto logon off.
What was **not** verified: `sudo` asking for a password, Windows 11, the Home edition, mirrored
networking, that the `.wslconfig` memory limit takes effect, recovery after a WSL update with the task enabled, the version after
`wsl --update`, a real Windows Update reboot, a graceful stop when Windows shuts down, a restart with the tasks registered by the script and no
console session signed in at all, a physical re-plug of the drive, a USB run that also takes a fresh backup, printing, and the sensor bridge running continuously and posting readings ([Sensors (Windows)](#sensors-windows)).

### Prerequisites

- Windows 10 22H2 (verified) or Windows 11 (not verified yet), Pro or Enterprise, x64. Windows 10 22H2 is out of Microsoft's
  support. The Home edition is not verified. This route has the Cloudflare tunnel only, with no LAN fallback
  ([Ingress and the LAN](#ingress-and-the-lan)).
- Hardware virtualisation on in the firmware. When Windows is itself a virtual machine, nested virtualisation (VT-x/EPT or the
  equivalent) must be switched on for that machine: WSL2 does not start without it. Check from PowerShell:

  ```powershell
  Get-CimInstance Win32_Processor | Select-Object VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions
  ```

- Sizes it was verified with: 4 virtual CPUs, 16 GB of RAM and 60 GB free on `C:`. These are what was used, not proven minimums.
  By default the distro may use half of the host's RAM and all its CPUs, and its disk is a virtual disk file that grows on
  `C:` (about 13 GB used after an install and a backup). Size `C:` with the rule in [Disk space](#disk-space).
- Power settings (verified): no sleep and no hibernation on AC power. [PS-admin]

  ```powershell
  powercfg /change standby-timeout-ac 0
  powercfg /hibernate off
  ```

- Optionally limit the memory the distro takes (writing the file is verified; that the limit takes effect is not verified): create `%UserProfile%\.wslconfig` with

  ```ini
  [wsl2]
  memory=8GB
  ```

  and apply it with `wsl --shutdown`, which stops the distro abruptly: do that only on a host with no live facility, or follow
  [Planned work and updates](#planned-work-and-updates).
- One Windows account owns the distro and the keep-alive task, and it needs a password (the task stores it). Nobody has to be
  signed in after the setup.

**Where the data lives.** The distro, with the whole installation, is one virtual disk file (`ext4.vhdx`) under that Windows
account's profile. Never run `wsl --unregister` for this distro, never delete that Windows account or its profile, and do not
reinstall Windows without a copy of a backup from outside the host ([Backups off the host](#backups-off-the-host-windows)).

### WSL and Ubuntu 24.04 with systemd

Verified, except where marked. If Docker Desktop is installed on this Windows host, read [Docker Desktop](#docker-desktop-if-it-is-installed) first.

1. [PS-admin] `wsl --install --no-distribution`, then restart Windows (only if WSL is not installed yet).
2. [PS-admin] `wsl --install Ubuntu-24.04 --no-launch`
3. [PS] Create the operator user as `root`. Do not call it `operator`: Ubuntu already has a group of that name. This guide
   uses `warehouse`.

   ```powershell
   wsl -d Ubuntu-24.04 -u root -- bash -c "adduser --disabled-password --gecos '' warehouse && usermod -aG sudo warehouse"
   wsl -d Ubuntu-24.04 -u root -- passwd warehouse
   ```

   The verified install used passwordless `sudo`; the `passwd warehouse` line and `sudo` asking for the password during
   `setup.sh` and `watch-timer.sh` are not verified yet.
4. [PS] Turn on systemd and make `warehouse` the default user:

   ```powershell
   wsl -d Ubuntu-24.04 -u root -- bash -c "printf '[boot]\nsystemd=true\n\n[user]\ndefault=warehouse\n' > /etc/wsl.conf"
   wsl --shutdown
   wsl -d Ubuntu-24.04
   ```

5. [Ubuntu] `systemctl is-system-running` may print `degraded` because `systemd-binfmt` fails in WSL; that is expected. A
   message "Failed to start the systemd user session" at the first start, and `logger: /dev/log` errors, are harmless too.

Notes for typing commands into the distro from Windows:

- `wsl` starts in the Windows working directory, so a `git clone` typed without `cd ~` lands on the Windows disk. Open a shell
  with `wsl -d Ubuntu-24.04 --cd ~`, or `cd ~` first.
- `wsl -l -v` prints UTF-16: captured into a file or a pipe it contains null bytes.
- A command run as `wsl -d Ubuntu-24.04 -- bash -c "node ..."` is not a login shell and does not read `~/.profile`, so it finds
  no `node` and no `WAREHOUSE_STATE_DIR`. Run such commands (your own scripts or jobs started from Windows) as
  `wsl.exe -d Ubuntu-24.04 -u warehouse -- bash -lc '<command>'`. The tasks that `register-tasks.ps1` creates run no warehouse
  command and need no login shell.
- A multi-line step such as the `printf ... | sudo tee` lines of this guide is mangled by nested quoting (for example `ssh`
  into Windows, then `wsl`): the file is silently not written. Work in a shell inside the distro, or put the steps in a script.
- Prove that the distro itself restarted with `ps -o lstart= -p 1`; `uptime -s` does not change after `wsl --terminate`.

### Docker Desktop (if it is installed)

Docker Engine runs inside Ubuntu, as on a Linux host; do not use Docker Desktop for this installation. If Docker Desktop is
installed on the host, quit it and turn off "Start Docker Desktop when you sign in" (verified: its start-up entry in the
registry stays, so check that it does not start again after a sign-in), and do not turn on its WSL integration for this distro.
The engine in the distro has its own daemon and images; a `docker` typed in Windows talks to Docker Desktop, not to the distro.
With Docker Desktop installed the default distro can be `docker-desktop`: name the distro in every command (`wsl -d Ubuntu-24.04`),
or run `wsl --set-default Ubuntu-24.04` (not verified yet).

### Continue with the Linux steps inside Ubuntu

Verified. Open a shell inside the distro as `warehouse` and follow the Linux guide from [Host time zone](#host-time-zone) (after the wait for systemd below) and
the [Ubuntu 24.04 sequence](#ubuntu-2404-sequence) unchanged, then [Private inputs](#private-inputs) and [Setup](#setup), then
register the keep-alive task of the [next section](#keep-the-distro-running-and-start-it-at-boot), then the
[Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress) (`bash scripts/tunnel.sh create` does the login, tunnel, DNS route and
adoption in one step, verified on WSL2; the link it prints can be opened in a browser on Windows) and
`sudo bash scripts/watch-timer.sh install --state "$WAREHOUSE_STATE_DIR"`.
Differences:

- On a distro that has just started (after `wsl --shutdown`, `wsl --terminate` or an idle stop), wait for systemd before the first
  `timedatectl` of [Host time zone](#host-time-zone): systemd's bus may not be up yet, and `timedatectl` then fails with "Failed to
  connect to bus" (verified; a rerun a minute later worked). The wait below accepts `running` or `degraded`; the race is verified,
  the wait itself was not tested.

  ```bash
  for i in $(seq 1 30); do
    s=$(systemctl is-system-running 2>/dev/null)
    [ "$s" = running ] || [ "$s" = degraded ] && break
    sleep 2
  done; echo "systemd: $s"
  ```

  If it does not print `running` or `degraded`, do not continue: check `systemctl --failed` and that `/etc/wsl.conf` has
  `systemd=true`.

- Register the keep-alive task **before** `bash scripts/tunnel.sh create`. The command waits for a login in a browser, which can
  outlast the 15 seconds after which WSL stops an idle distro, and a `wsl` started detached from an SSH session does not survive
  that session (verified). With the task registered, the distro stays up during the login.

- Clone the repository and keep the state directory on the Ubuntu filesystem (the home folder or `/srv`), never under `/mnt/c`
  or another Windows drive: NTFS has no Unix modes, `flock` or extended attributes, and the scripts refuse or misbehave there.
- Keep a `wsl` session open for as long as setup runs (about 6 to 7 minutes the first time). When the
  last session ends, WSL stops the distro after about 15 seconds and kills the build. Until the keep-alive task below exists, keep
  a terminal window open.
- Right after the distro has just started, Docker may not answer for a moment. `setup.sh` waits for the Docker daemon for up to
  60 s before it refuses (verified: after `wsl --terminate` it printed "Waiting for the Docker daemon to answer (up to 60 s)..." and
  went on); if it still stops with "Docker did not answer within 60 s", check `systemctl status docker`.
- Under WSL 3.0.3, WSL mounts full images read-only at `/usr/src/linux-headers-...-WSL2` and `/usr/lib/linux-tools/...`. The checker
  skips read-only mounts, so it raises no `disk_low` alert for them (not yet observed on a WSL host).
- Decide the public hostname before the first setup ([Setup](#setup)).
- Put the Node `PATH` and `export WAREHOUSE_STATE_DIR=...` in `~/.profile`: the Ubuntu terminal is a login shell and reads it
  (for commands started from Windows see [the notes above](#wsl-and-ubuntu-2404-with-systemd)).

- The clock: `systemd-timesyncd` keeps the distro's clock right by NTP (`timedatectl` shows `NTP service: active`). After the
  distro starts, or after the Windows host has been asleep or busy, the clock can be off by several seconds and `timedatectl`
  can show `System clock synchronized: no`; `clock_unsynced` has fired on a WSL2 host this way (clock about 13 s ahead). The
  checker raises it when `NTPSynchronized` is `no` or the clock is more than 10 s from the public address's clock, and alerts
  after two checker runs in a row ([MONITORING.md](MONITORING.md)). Check `timedatectl status`, `timedatectl timesync-status`
  (a small `Offset` and a recent server mean it is working) and `systemctl status systemd-timesyncd`. If it stays `no`, run
  `sudo timedatectl set-ntp true` and `sudo systemctl restart systemd-timesyncd`, and check that the host can reach its time
  servers (UDP 123 not blocked). This was **not** tried on a Windows host while the alert was firing (the clock was
  synchronised, offset under 1 s, when looked at afterwards).

### Keep the distro running and start it at boot

WSL stops a distro about 15 seconds after its last session ends, and a host that restarts has no session at all. One scheduled
task of the Windows account that owns the distro must hold a session open, start at boot without anyone signing in, and start
again by itself after `wsl --shutdown` or `wsl --terminate`. A task that only has a boot trigger and a restart count is not
enough: the restart count acts on a task that failed to launch, not on a `wsl.exe` that was killed (verified: the public address
stayed down for nearly 10 minutes after `wsl --shutdown`). The verified form is a boot trigger plus a trigger that repeats every
2 minutes without end, with new instances ignored while one is running.

The task is registered by `scripts/windows/register-tasks.ps1` from the checkout inside the distro: boot plus every 2 minutes,
running whether or not anyone is signed in, as the Windows account that owns the distro (`SYSTEM` cannot see the distro). It is
verified that tasks registered by the script bring the distro back after a host restart and after `wsl --shutdown`
([Windows host (Ubuntu in WSL2)](#windows-host-ubuntu-in-wsl2)). Read back after the script ran (verified, including
`-Force` replacing existing tasks and `-BusId` registering both): Running; RunLevel Highest; MultipleInstances IgnoreNew; StartWhenAvailable; both battery switches off
(`DisallowStartIfOnBatteries` and `StopIfGoingOnBatteries` False); RestartCount 999 at 1 minute; no time limit; the boot trigger
and the 2-minute repeating trigger enabled. Do not run the script while the tasks are disabled for planned work; it registers
them enabled and starts them.

[PS-admin], in a console on the host (the script asks for the password with `Get-Credential`, which may not prompt over a remote
session). Run it from an elevated PowerShell of the Windows account that owns the distro (the account that ran `wsl --install`).
The prompt is filled in with that account; type its password. The script refuses if the account typed at the prompt is not the one running it (not tested). Use the checkout path of this guide (`~/backend` for the user
`warehouse`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File \\wsl.localhost\Ubuntu-24.04\home\warehouse\backend\scripts\windows\register-tasks.ps1
```

- `-ExecutionPolicy Bypass` applies to this one command only; it does not change the machine's policy. It also avoids the
  "not digitally signed" refusal that a script read from a network path can meet under `RemoteSigned`. The `\\wsl.localhost`
  command above is verified (Windows 10 22H2, elevated PowerShell, with `-Force -BusId`). If the path is not found right after the
  distro starts, try again a few seconds later. If `\\wsl.localhost` is still not found, use `\\wsl$\Ubuntu-24.04\...` for the same path.
  If the script still does not start from there, copy it to your own temp folder and run it from there (not verified on
  Windows 10 22H2):
  `Copy-Item \\wsl$\Ubuntu-24.04\home\warehouse\backend\scripts\windows\register-tasks.ps1 $env:TEMP\`, then
  `powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\register-tasks.ps1`. Use the temp folder of your own account,
  not `C:\Temp`: a folder that other users can write to is unsafe for a script that runs elevated. An execution policy set by
  Group Policy overrides `-ExecutionPolicy Bypass`.
- Parameters: `-Distro` (default `Ubuntu-24.04`), `-BusId` (also registers the USB task, see
  [Backups off the host](#backups-off-the-host-windows)), `-UsbOnly`, and `-Force` (replace tasks that exist (verified); without it the
  script refuses). The script checks that it is elevated and that the distro exists before it changes anything, asks once for the
  password, never stores or prints it, starts the task, and reads it back: State, LastRunTime, LastTaskResult, the triggers
  (with the repeat duration; empty means no end), MultipleInstances, the battery switches, RunLevel, the user and logon type, the
  restart settings, time limit, StartWhenAvailable and the action. Check that the task shows Running with the boot trigger and the 2-minute
  repeating trigger.
- The task shows **Running** all the time (`LastTaskResult` 267009, 0x41301, means running now), and the 2-minute repeat ends with
  2147946720 (0x800710E0) because it finds the first instance still running. Both are expected and not a fault; the script
  prints the same note.
- After the Windows account's password changes, update the tasks, or they stop starting (a password change was not tested; the rerun with `-Force` itself is verified): run the script
  again with `-Force`, with the stick plugged in (add `-BusId <id>` if the USB task exists; the bus id is in
  `(Get-ScheduledTask 'Warehouse USB').Actions.Arguments`). Alternatively, for each task:
  `Set-ScheduledTask -TaskName 'Warehouse WSL' -User $c.UserName -Password $c.GetNetworkCredential().Password` with a new
  `$c` from `Get-Credential`, and the same for `'Warehouse USB'`.
- Recovery times measured with the verified task (single samples per run, plus or minus 20 seconds): the public address answered
  again about 40 seconds to 2 minutes after `wsl --shutdown`, about 85 seconds after `wsl --terminate`, and about 70 to 90
  seconds after a host reboot with nobody signed in.

Nothing stops the stack cleanly when Windows shuts down or restarts for an update (not verified yet): the processes are killed
and PostgreSQL recovers its log on the next start. For a planned shutdown follow the next section.

### Ingress and the LAN

The Cloudflare tunnel, running inside Ubuntu, is the only way in. The gateway listens on `127.0.0.1` inside the distro, and
nothing is published to the Windows network.

- Do not add a Windows `netsh interface portproxy` rule, or a firewall rule, to reach the gateway from the LAN. Every request
  then reaches the gateway from the container bridge address, and the gateway trusts `CF-Connecting-IP` from private
  addresses ([Cloudflare Tunnel ingress](#cloudflare-tunnel-ingress)): a device on the LAN can choose its own rate-limit bucket and
  per-source sign-in limits, and all other clients share one.
- The [LAN fallback](#lan-fallback-plain-http-on-the-warehouse-network) is not available on a WSL2 host with the default NAT
  networking: `lan.sh` binds an address of the distro's private network, which phones cannot reach. Windows 11 mirrored
  networking (`networkingMode=mirrored` in `.wslconfig`) is not verified. A facility on this route has no fallback if the
  internet or Cloudflare is down.
- The external doctor runs inside the distro, on the install host ([External doctor](#external-doctor)).

### Planned work and updates

`wsl --shutdown`, `wsl --terminate`, a WSL update, and a restart of Windows all kill PostgreSQL and the containers abruptly;
the database recovers on the next start, but do not do them on a live facility without this order. The order was run end to
end (verified): stop, mute, disable the task, update WSL, restart Windows, enable and start the task, start, unmute, both doctor
modes passing.

1. [Ubuntu] `export WAREHOUSE_STATE_DIR=...`, then `bash stop.sh`.
2. [Ubuntu] Silence the checker for the window: `node scripts/watch.mjs mute <minutes>`.
3. [PS-admin] `Disable-ScheduledTask 'Warehouse WSL'`, so the distro is not started again in the middle of the work. If the
   [Warehouse USB task](#backups-off-the-host-windows) exists, also `Disable-ScheduledTask 'Warehouse USB'`.
4. Do the work: update WSL (`wsl --update`), Windows, `wsl --shutdown`, restart.
5. [PS-admin] `Enable-ScheduledTask 'Warehouse WSL'`, then `Start-ScheduledTask 'Warehouse WSL'`.
6. [Ubuntu] `bash start.sh`, then `node scripts/watch.mjs unmute` and the doctor in both modes.
7. [PS-admin] If the Warehouse USB task exists, `Enable-ScheduledTask 'Warehouse USB'` now that both doctor modes pass; its repeating
   trigger attaches the drive within 2 minutes, and that starts a USB run.

A task left disabled keeps the facility down after the next restart of Windows. `Disable-ScheduledTask` does not stop the
keep-alive or the USB loop that is already running, so the distro stays up until the next `wsl --shutdown`, WSL update or restart of Windows.
While the work is going on, the public address answers 530 when the tunnel or the distro is down, and 502 when the tunnel is up
but the stack is stopped (for example after `stop.sh`); both are normal.

`wsl --update` was run once with the task disabled (it offered 3.0.1 to 3.0.3 and took about 3 minutes; its exit code and the
version afterwards were not read back): it stopped the distro, which then stayed down while the task is disabled. Recovery after an update with the task enabled is not verified. The package work of
[Monthly host maintenance](#monthly-host-maintenance) is done inside Ubuntu as written; a restart of the host is the Windows
restart in step 4 of this list, not `sudo reboot` (not verified yet).

### Sensors (Windows)

The optional sensor bridge ([SENSORS.md](SENSORS.md#run-it-as-a-profile-of-the-installation)) runs inside the distro like the
rest of the stack. The hub addresses in `SENSOR_BRIDGE_HUBS` must be reachable from inside the distro; under WSL's default NAT
networking outgoing connections to the LAN normally work (verified below), and mirrored networking is not verified (as in
[Ingress and the LAN](#ingress-and-the-lan)). Before you start the bridge, set `SENSOR_BRIDGE_HUBS`, `TAPO_USERNAME` and
`TAPO_PASSWORD` as in step 2 of that section (the ingest key is not needed for this check), then run:

[Ubuntu] `bash scripts/compose.sh --profile sensors run --rm sensor-bridge --once --dump`

The check passes when it prints the sensors of each hub with no `"error"` entry and exits 0; an unreachable hub is printed as
`{"host": ..., "error": ...}` and the command exits 1.

Verified, on Windows 10 Pro 22H2 with WSL's default NAT networking: this check reached three Tapo H200 hubs (firmware 1.7.7) from
inside the distro and from a container on the stack's default network, listed all four T310 sensors of the three hubs (one of them offline at its hub, listed without an error) and exited 0.
**Not verified**: the bridge running continuously (`up`) and posting readings to the ingest function, mirrored networking, and
Windows 11.

### Backups off the host (Windows)

**A Windows host meets the off-host backup requirement only while the USB drive is attached to the distro, and the attach is lost
whenever the distro stops. The "Warehouse USB" task below attaches it again by itself (verified after a host restart and after `wsl --shutdown`).** The USB
drive is the off-host copy ([PRODUCTION_DEPENDENCIES.md](PRODUCTION_DEPENDENCIES.md)), and `backup-usb.sh` writes only to an enrolled
USB drive that the distro can see. On this route the drive is passed into the distro with `usbipd-win` on Windows.

Verified on WSL 3.0.3 with usbipd-win 5.3.0: the distro's kernel has exFAT, the udev rule fires inside the distro when the drive
is attached, the drive was enrolled, and an automatic run copied the newest verified backup and the saved images to the drive,
read them back and passed the restore verification of the copy. The attach was triggered with `usbipd detach` and
`usbipd attach`. Not verified: a physical re-plug, a run that also takes a fresh backup (the newest backup was fresh), and setup
with a `sudo` password (the test host used passwordless `sudo`).

Install usbipd-win once: download the signed MSI from its GitHub releases and run it from an elevated PowerShell,
[PS-admin] `msiexec /i <msi> /qn /norestart`. The `usbipd` command is found only in sessions opened after the install. Then, in
this order:

1. [PS-admin] `usbipd list`, to find the drive's bus id.
2. [PS-admin] `usbipd bind --busid <id>`, once; the bind persists.
3. Register the keep-alive task first ([above](#keep-the-distro-running-and-start-it-at-boot)), then the "Warehouse USB" task
   [PS-admin], in a console on the host, after `usbipd bind`, with the bus id from step 1 (the command is
   the one of the keep-alive section with `-UsbOnly -BusId`; the task runs as the Windows account that owns the distro, and the
   script finds `usbipd.exe` itself and refuses a bus id that is not shared):

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File \\wsl.localhost\Ubuntu-24.04\home\warehouse\backend\scripts\windows\register-tasks.ps1 -UsbOnly -BusId <id>
   ```

   It is shaped like the keep-alive task for a reason. `--auto-attach` keeps running and attaches the stick again whenever it comes
   back, but it refuses to start while the distro is down and ends when WSL stops (from the usbipd-win source; not tested here);
   the repeating trigger starts it again after every `wsl --shutdown`, WSL update or restart, and `IgnoreNew` keeps one copy running.
   A repeat while the distro is down ends with `LastTaskResult` 1, which is expected. The loop holds a distro session, so it also keeps
   the distro up. `--wsl Ubuntu-24.04` ties the loop to the warehouse distro, like the keep-alive's `-d Ubuntu-24.04`. `--unplugged` lets it start while the
   stick is out. The bus id belongs to the USB port, not to the stick: keep the stick in the same port (the usbipd-win
   documentation says the id changes with the port; not tested here). If you must move it: [PS-admin] `Stop-ScheduledTask 'Warehouse USB'`,
   repeat steps 1 and 2 for the new bus id, run the script again with `-UsbOnly -BusId <new> -Force` (it starts the task again). To remove the task: [PS-admin]
   `Stop-ScheduledTask 'Warehouse USB'; Unregister-ScheduledTask 'Warehouse USB' -Confirm:$false`, then `usbipd detach --busid <id>`.
   Like the keep-alive task, it shows Running all the time, and a repeat that finds it running is expected, not a fault.
   The script reads the task back and prints `usbipd list` for the bus id; with the stick in, its state
   should be **Attached** within 2 minutes once the distro is up. It re-attached the drive after a host restart and after `wsl --shutdown`; whether it does so with no console session signed in is not verified.
4. [Ubuntu] Inside the distro, `lsblk` shows the drive as `usb` and `exfat`. Then set up USB backup as written in
   [USB backup drive](#usb-backup-drive), with `--daily` now that the drive stays attached:
   `sudo bash scripts/backup-usb.sh setup --state "$WAREHOUSE_STATE_DIR" --daily --enroll /dev/sdX1`. Every re-attach (after a
   restart, a WSL update or a re-plug) also starts a USB run through the udev rule, as a plug-in does on Linux.
   Setup copies nothing to a drive that is already attached. Make the first copy with [PS] `usbipd detach --busid <id>`: the task's loop
   attaches it again within seconds and the run starts (the usbipd-win behaviour; not tested here). Check with
   `bash scripts/backup-usb.sh status`. After a restart a USB run may start within a few minutes and hold the operator lock: wait for it
   (`journalctl -f -u 'warehouse-usb-backup@*'`) before `start.sh`, `setup.sh` or `upgrade.sh`.

Fallback, if the task is not registered or does not work: [PS] `usbipd attach --wsl --busid <id>` by hand, every time the drive
has to reach the distro (run from an elevated PowerShell in the test; the usbipd-win documentation says an ordinary one is enough).

**Without the task the attach does not survive a restart.** After a host reboot the drive was listed as Shared, not Attached
(verified); it is also expected to detach whenever the distro stops (`wsl --shutdown`, a WSL update; not read back in the test), and
every plug-in on Windows needs an attach too. The "Warehouse USB" task is the answer to that: it was run through a host restart and a
`wsl --shutdown`. Still check `usbipd list` for "Attached" after every restart and use the manual attach if it says "Shared". If nobody does, the `usb_backup` alert and `npm run doctor` warn once the last copy is over 7 days old
(the default of `WAREHOUSE_USB_BACKUP_MAX_AGE_DAYS`). Printing over USB has the same limits
([PRINTING.md](PRINTING.md)), and is not verified on this route. Copying files to a Windows drive through `/mnt/<drive>` loses the
extended attributes and ownership that a restore needs from the stored photos, so it is not a substitute.

Until a run has copied a backup to the drive, the distro's virtual disk holds the only copy of the data. Verified: `db:backup` and
`db:verify-restore` inside the distro, on its own virtual disk, work as on Linux.

### Acceptance

Before the facility goes live, on this host, with nobody signed in to Windows:

1. Restart Windows. The public address answers `get-public-config` again within a few minutes without anyone signing in, the
   `<project>-stack.service` and tunnel units are active, and `node scripts/doctor.mjs --local` and `node scripts/doctor.mjs`
   (run inside the distro) both pass.
2. Run `wsl --shutdown` from a PowerShell, then do not touch anything. The task starts the distro again, the stack comes back, and
   both doctor modes pass (do this on a host that serves no live facility).
3. Run the planned-work order above once end to end, including `Disable-ScheduledTask` and `Enable-ScheduledTask` (before go-live, on
   this host only). If any step does not behave as written, stop and report it; do not go live.
4. Check the keep-alive task after it is registered: it shows Running, with the two triggers.
5. A USB backup drive, enrolled and copying a verified backup, and still working after the same restart, is required for a real facility.
   On Windows this is met with the Warehouse USB task: after the same restart `usbipd list` shows the drive
   Attached and `bash scripts/backup-usb.sh status` shows a successful run after the restart, without anyone attaching it
   ([Backups off the host](#backups-off-the-host-windows)). If it shows Shared, this host does not pass: report it; a manual
   `usbipd attach` is only a stopgap, not acceptance.
   Printing, where the facility uses it, is not verified on this route either.
