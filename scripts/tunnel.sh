#!/usr/bin/env bash
# Keep this installation's Cloudflare Tunnel credential inside its state directory
# (config/tunnel/), so every backup carries it and db:restore-host can bring the
# public address back on a new host without a Cloudflare login.
#
#   bash scripts/tunnel.sh create [--name NAME]       log in, create the tunnel and its DNS route, adopt it (one step)
#   bash scripts/tunnel.sh adopt --config FILE        locally managed: config.yml and its credentials JSON
#   bash scripts/tunnel.sh adopt --token-file FILE    dashboard-managed: the connector token
#   sudo bash scripts/tunnel.sh install-service       write, enable and (re)start the systemd unit
#   bash scripts/tunnel.sh status
#
# All commands read WAREHOUSE_STATE_DIR (install-service also accepts --state DIR).
# create shows a login link (open it on any machine), creates a new tunnel named
# warehouse-<state name> (or --name), routes this installation's hostname to it
# (never overwriting a DNS record) and adopts it; the account certificate is
# shredded when the command ends, whatever the outcome.
# The account certificate (cert.pem) is refused: it can create and delete any
# tunnel or DNS record of the account and must never be copied into a backup.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$ROOT/scripts/tunnel.sh"
# Test override; printed by status whenever it is set.
UNITS="${WAREHOUSE_TUNNEL_UNIT_DIR:-/etc/systemd/system}"
die() { echo "$*" >&2; exit 1; }
usage() { sed -n '6,10p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 1; }

state_dir() {
  local state="${1:-${WAREHOUSE_STATE_DIR:-}}"
  [[ "$state" == /* && ! -L "$state" && -f "$state/config/compose.env" && -f "$state/public/instance.json" ]] \
    || die 'Set WAREHOUSE_STATE_DIR (or --state) to the installed operator state.'
  printf '%s\n' "$state"
}
# The hostname this installation answers on, from its public manifest.
origin_host() { node -e 'const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(new URL(m.canonicalOrigin).hostname)' "$1/public/instance.json"; }
yaml_get() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -n 1 | sed "s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]*$//"; }
unit_name() { printf 'warehouse-%s-tunnel.service\n' "$(basename "$1")"; }
refuse_certificate() {
  ! grep -q -- '-----BEGIN' "$1" || die "Refusing $1: it holds a certificate or key block. Copy only the tunnel's credentials JSON or token, never cert.pem."
}

cmd_adopt() {
  local config='' token='' state dest stage host tunnel creds
  while (($#)); do
    case "$1" in
      --config) (($# > 1)) || usage; config="$2"; shift 2 ;;
      --token-file) (($# > 1)) || usage; token="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$config$token" && ( -z "$config" || -z "$token" ) ]] || die 'adopt needs exactly one of --config FILE or --token-file FILE.'
  [[ "$(id -u)" != 0 ]] || die 'Run adopt as the installation user, not as root.'
  state="$(state_dir)"
  dest="$state/config/tunnel"
  [[ ! -e "$dest" && ! -L "$dest" ]] || die "$dest already exists. To replace the credential, move it aside first (it is private: keep or shred the old copy)."
  host="$(origin_host "$state")"
  stage="$(mktemp -d "$state/config/.tunnel.XXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  if [[ -n "$config" ]]; then
    [[ -f "$config" ]] || die "Not a file: $config"
    refuse_certificate "$config"
    ! grep -Eq '^[[:space:]]*origincert:' "$config" || die "Refusing $config: it names an origincert (the account certificate). Remove that line; a running connector only needs the tunnel's credentials JSON."
    tunnel="$(yaml_get tunnel "$config")"
    creds="$(yaml_get credentials-file "$config")"
    [[ "$tunnel" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "$config has no tunnel: <uuid> line."
    [[ "$creds" == /* && -f "$creds" ]] || die "$config names no readable absolute credentials-file (found '${creds:-nothing}')."
    refuse_certificate "$creds"
    node -e '
      const [file, tunnel] = process.argv.slice(1);
      const c = JSON.parse(require("fs").readFileSync(file, "utf8"));
      if (c.TunnelID !== tunnel || !c.TunnelSecret || !c.AccountTag) { console.error(`${file} is not the credentials JSON of tunnel ${tunnel}.`); process.exit(1); }
    ' "$creds" "$tunnel" || exit 1
    grep -Eq "^[[:space:]]*-?[[:space:]]*hostname:[[:space:]]*[\"']?${host//./\\.}[\"']?[[:space:]]*$" "$config" \
      || die "$config does not route $host (this installation's canonical origin); refusing another installation's tunnel."
    install -m 0600 -- "$creds" "$stage/credentials.json"
    awk -v c="$dest/credentials.json" '/^credentials-file:/ { print "credentials-file: " c; next } { print }' "$config" > "$stage/config.yml"
    chmod 0600 "$stage/config.yml"
  else
    [[ -f "$token" ]] || die "Not a file: $token"
    refuse_certificate "$token"
    [[ "$(wc -l < "$token")" -le 1 ]] && grep -Eq '^[A-Za-z0-9+/=_-]{40,}[[:space:]]*$' "$token" \
      || die "$token is not a single-line connector token."
    install -m 0600 -- "$token" "$stage/token"
  fi
  chmod 0700 "$stage"
  mv -T -- "$stage" "$dest"
  trap - EXIT
  echo "Adopted the tunnel credential into $dest; every backup from now on carries it."
  echo "Point the connector at it: sudo bash scripts/tunnel.sh install-service --state $state"
  echo 'Then remove or shred the old private copy once the service runs from the state copy.'
}

# Guided setup of a locally managed tunnel. The account certificate (cert.pem) can
# create and delete every tunnel and DNS record of the account, so it lives only in
# a private temporary directory and is shredded on every exit path.
cmd_create() {
  local name="" state dest host port tunnel uuid creds cfg cert out dir_default home_cert
  while (($#)); do
    case "$1" in
      --name) (($# > 1)) || usage; name="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$(id -u)" != 0 ]] || die 'Run create as the installation user, not as root.'
  state="$(state_dir)"
  dest="$state/config/tunnel"
  [[ ! -e "$dest" && ! -L "$dest" ]] || die "This installation already has a tunnel credential in $dest. Check it with: bash scripts/tunnel.sh status"
  [[ -n "$name" ]] || name="warehouse-$(basename "$state")"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || die "Not a usable tunnel name: $name (letters, digits, '.', '_' and '-', at most 63 characters)."
  command -v cloudflared >/dev/null || die 'cloudflared is not installed; see docs/OPERATOR_INSTALL.md, "Cloudflare Tunnel ingress".'
  host="$(origin_host "$state")"
  port="$(sed -n 's/^GATEWAY_HTTP_PORT=//p' "$state/config/compose.env" | tail -n 1)"
  port="${port:-18000}"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "GATEWAY_HTTP_PORT in compose.env is not a port number: $port"
  home_cert="$HOME/.cloudflared/cert.pem"
  [[ ! -e "$home_cert" && ! -L "$home_cert" ]] || die "$home_cert already exists: it is an account certificate that can create and delete every tunnel and DNS record. Shred it (shred -u $home_cert) and run create again."

  dir_default="$(mktemp -d "${TMPDIR:-/tmp}/warehouse-tunnel-create.XXXXXX")"
  TUNNEL_CREATE_TMP="$dir_default"; TUNNEL_CREATE_HOME_CERT="$home_cert"
  trap tunnel_create_cleanup EXIT
  trap 'exit 130' INT TERM HUP
  chmod 0700 "$dir_default"
  cert="$dir_default/cert.pem"

  echo "Creating the tunnel $name for https://$host ."
  echo 'Open the link that cloudflared prints on any machine, sign in and pick the domain. This command waits until you have.'
  cloudflared tunnel login || die 'cloudflared tunnel login failed; nothing was created.'
  [[ -f "$home_cert" ]] || die "Login finished but $home_cert is missing; nothing was created."
  mv -- "$home_cert" "$cert"
  chmod 0600 "$cert"

  out="$(cloudflared tunnel --origincert "$cert" list --output json)" || die 'Could not list the account tunnels; nothing was created.'
  printf '%s' "$out" | node -e '
    const name = process.argv[1];
    const list = JSON.parse(require("fs").readFileSync(0, "utf8") || "[]") || [];
    if (list.some(t => t.name === name)) process.exit(3);
  ' "$name" || {
    (($? == 3)) && die "A tunnel named $name already exists in this account. Nothing was created or changed; choose another name with --name."
    die 'Could not read the tunnel list; nothing was created.'
  }

  creds="$dir_default/$name.json"
  out="$(cloudflared tunnel --origincert "$cert" create --credentials-file "$creds" "$name" 2>&1)" || die "tunnel create failed: $out"
  uuid="$(printf '%s\n' "$out" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n 1)"
  [[ -n "$uuid" && -f "$creds" ]] || die "Could not read the new tunnel's id or credentials from: $out"
  tunnel="$uuid"

  cloudflared tunnel --origincert "$cert" route dns "$tunnel" "$host" || die "The DNS route for $host could not be created (a record may already exist there; it was not overwritten).
The tunnel $name ($tunnel) exists and is unused: delete it in the Cloudflare dashboard (Zero Trust, Networks, Tunnels), fix or remove the existing $host record, then run create again."

  cfg="$dir_default/config.yml"
  awk -v t="$tunnel" -v c="$creds" '/^tunnel:/ { print "tunnel: " t; next } /^credentials-file:/ { print "credentials-file: " c; next } { print }' \
    "$ROOT/deploy/cloudflared-config.example.yml" \
    | sed "s#<confirmed-hostname>#$host#g; s#http://127.0.0.1:18000#http://127.0.0.1:$port#" > "$cfg"
  chmod 0600 "$cfg"
  ! grep -v '^[[:space:]]*#' "$cfg" | grep -q '<' || die 'The generated config still has a placeholder; see deploy/cloudflared-config.example.yml.'
  cloudflared --config "$cfg" tunnel ingress validate || die 'The generated tunnel config did not validate.'

  # Adopt in a subshell: it has its own exit trap and must not clear ours.
  ( cmd_adopt --config "$cfg" ) || die 'Adopting the credential failed.'

  echo
  echo "Tunnel $name ($tunnel) routes $host to this installation; the account certificate is being shredded."
  echo 'Next:'
  echo "  sudo bash scripts/tunnel.sh install-service --state $state"
  echo '  bash scripts/tunnel.sh status'
}
tunnel_create_cleanup() {
  local f
  for f in "${TUNNEL_CREATE_HOME_CERT:-}" "${TUNNEL_CREATE_TMP:-}"/*; do
    [[ -n "$f" && -f "$f" ]] || continue
    shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
  done
  [[ -z "${TUNNEL_CREATE_TMP:-}" ]] || rm -rf -- "$TUNNEL_CREATE_TMP"
}

cmd_install_service() {
  local state='' uid gid user group unit exec tmp old=''
  while (($#)); do
    case "$1" in
      --state) (($# > 1)) || usage; state="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ "$(id -u)" == 0 ]] || die 'install-service writes a systemd unit: run it with sudo from the installation user.'
  state="$(state_dir "$state")"
  [[ "$state" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "The state path must contain only letters, digits, '.', '_', '-' and '/': $state"
  uid="${SUDO_UID:-}"; gid="${SUDO_GID:-}"
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[0-9]+$ ]] || die 'Run install-service through sudo from the installation user (SUDO_UID is missing or 0); the connector must not run as root.'
  [[ "$(stat -c %u -- "$state")" == "$uid" ]] || die "$state is not owned by the user who ran sudo."
  user="$(getent passwd "$uid" | cut -d: -f1)"; group="$(getent group "$gid" | cut -d: -f1)"
  [[ -n "$user" && -n "$group" ]] || die "Cannot resolve user $uid or group $gid."
  if [[ -f "$state/config/tunnel/config.yml" ]]; then
    exec="/usr/bin/cloudflared --no-autoupdate --config $state/config/tunnel/config.yml tunnel run"
  elif [[ -f "$state/config/tunnel/token" ]]; then
    exec="/usr/bin/cloudflared --no-autoupdate tunnel run --token-file $state/config/tunnel/token"
  else
    die "No tunnel credential in $state/config/tunnel; run bash scripts/tunnel.sh adopt first."
  fi
  unit="$(unit_name "$state")"
  mkdir -p -- "$UNITS"
  if [[ -f "$UNITS/$unit" ]]; then
    old="$UNITS/$unit.before-state-copy.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p -- "$UNITS/$unit" "$old"
  fi
  tmp="$(mktemp "$UNITS/.$unit.XXXXXX")"
  cat > "$tmp" <<EOF
# Managed by scripts/tunnel.sh: the connector reads the credential kept in the
# installation's state ($state/config/tunnel), which every backup carries.
[Unit]
Description=Warehouse instance HTTPS tunnel (cloudflared) for $state
Wants=network-online.target
After=network-online.target docker.service

[Service]
User=$user
Group=$group
ExecStart=$exec
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$tmp"; mv -f -- "$tmp" "$UNITS/$unit"
  systemctl daemon-reload
  systemctl enable "$unit" >/dev/null
  systemctl restart "$unit"
  [[ -z "$old" ]] || echo "Kept the previous unit as $old."
  for other in "$UNITS"/warehouse-*-tunnel.service; do
    [[ -f "$other" && "$other" != "$UNITS/$unit" ]] || continue
    echo "Note: another tunnel unit exists ($(basename "$other")); make sure it does not run this installation's tunnel." >&2
  done
  if systemctl is-active --quiet "$unit"; then
    echo "$unit is running from $state/config/tunnel. Check the public address: node scripts/doctor.mjs"
  else
    die "$unit did not start; see: journalctl -u $unit -n 50"
  fi
}

cmd_status() {
  local state unit dest
  state="$(state_dir)"; dest="$state/config/tunnel"; unit="$(unit_name "$state")"
  [[ -z "${WAREHOUSE_TUNNEL_UNIT_DIR:-}" ]] || echo "Test override: WAREHOUSE_TUNNEL_UNIT_DIR=$UNITS"
  if [[ -f "$dest/config.yml" ]]; then
    echo "Tunnel credential: locally managed tunnel $(yaml_get tunnel "$dest/config.yml") in $dest (carried by backups)."
  elif [[ -f "$dest/token" ]]; then
    echo "Tunnel credential: dashboard token in $dest (carried by backups)."
  else
    echo "Tunnel credential: not in the state; backups do not carry it. Run: bash scripts/tunnel.sh adopt --config FILE | --token-file FILE"
  fi
  if [[ -f "$UNITS/$unit" ]]; then
    if grep -q -- "$dest/" "$UNITS/$unit"; then echo "Service: $unit reads the state copy."
    else echo "Service: $unit does NOT read the state copy; run: sudo bash scripts/tunnel.sh install-service --state $state"; fi
    echo "Service state: $(systemctl is-active "$unit" 2>/dev/null || true)"
  else
    echo "Service: $unit is not installed."
  fi
}

(($#)) || usage
cmd="$1"; shift
case "$cmd" in
  create) cmd_create "$@" ;;
  adopt) cmd_adopt "$@" ;;
  install-service) cmd_install_service "$@" ;;
  status) (($# == 0)) || usage; cmd_status ;;
  *) usage ;;
esac
