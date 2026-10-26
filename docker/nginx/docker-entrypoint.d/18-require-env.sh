#!/bin/sh
# Runs before the image's 20-envsubst-on-templates.sh. The three values below are written into the nginx
# configuration as quoted strings, so a missing one would leave the text ${NAME} in the file (and a key could then be
# the text "${ANON_KEY}"), and a quote, semicolon, dollar sign or space in one would change the configuration itself.
# Keys are JWTs (letters, digits, dot, dash, underscore); the origin is scheme://host[:port]. Anything else stops the
# container with a message instead of starting a gateway whose rules are not the ones written in the template.
set -eu

fail() { echo "gateway: $1" >&2; exit 1; }

# $1 name, $2 value
check() {
  [ -n "$2" ] || fail "$1 is not set"
  case "$2" in
    *[!A-Za-z0-9._~:/-]*) fail "$1 has a character that is not allowed in the gateway configuration (allowed: letters, digits and . _ ~ : / -)" ;;
  esac
}

check CORS_ALLOWED_ORIGIN "${CORS_ALLOWED_ORIGIN:-}"
case "$CORS_ALLOWED_ORIGIN" in
  http://?*|https://?*) ;;
  *) fail "CORS_ALLOWED_ORIGIN must be one origin, http(s)://host[:port], not a pattern" ;;
esac
check ANON_KEY "${ANON_KEY:-}"
check SERVICE_ROLE_KEY "${SERVICE_ROLE_KEY:-}"

# The LAN container (docker-compose.yml, service gateway-lan, profile `lan`) also writes three more values into its server: LAN_CIDR
# as the allow list, and LAN_BIND_IP and LAN_HTTP_PORT as the Host the server answers to (the Host pin). An empty or odd one would
# leave the server answering nobody or, written carelessly, everybody, so each is refused here: LAN_CIDR is one IPv4 range in CIDR
# form inside a private block (10.0.0.0/8 or longer, 172.16.0.0/12 or longer, 192.168.0.0/16 or longer), LAN_BIND_IP one private
# IPv4 address, LAN_HTTP_PORT a port from 1024 to 65535. scripts/lan.sh on writes all three, derived from the interface of the host.
# The public container has no GATEWAY_ROLE, reads the default template directory and ignores them.
#
# Which container is the LAN container: the one that reads the LAN template directory of this image (templates-lan) or says so with
# GATEWAY_ROLE=lan, and, whatever either says, any container whose templates write one of the three names in a line that is not a
# comment (a comment that names a variable is harmless and must not stop the public gateway; the role does not protect the allow
# list, the template does).
template_dir="${NGINX_ENVSUBST_TEMPLATE_DIR:-/etc/nginx/templates}"
lan_server=no
if [ "${GATEWAY_ROLE:-}" = lan ] || [ "$template_dir" = /etc/nginx/templates-lan ]; then
  lan_server=yes
elif cat "$template_dir"/*.template 2>/dev/null | grep -v '^[[:space:]]*#' | grep -Eq '\$\{?LAN_(CIDR|BIND_IP|HTTP_PORT)'; then
  lan_server=yes
fi
if [ "$lan_server" = yes ]; then
  check LAN_CIDR "${LAN_CIDR:-}"
  octet='[0-9]{1,3}'
  if ! printf '%s\n' "$LAN_CIDR" | grep -Eq "^(10\.$octet\.$octet\.$octet/([89]|[12][0-9]|3[0-2])|172\.(1[6-9]|2[0-9]|3[01])\.$octet\.$octet/(1[2-9]|2[0-9]|3[0-2])|192\.168\.$octet\.$octet/(1[6-9]|2[0-9]|3[0-2]))\$"; then
    fail "LAN_CIDR must be one private IPv4 range such as 192.168.1.0/24 (10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16 or a part of one); the gateway-lan container does not start with $LAN_CIDR"
  fi
  check LAN_BIND_IP "${LAN_BIND_IP:-}"
  if ! printf '%s\n' "$LAN_BIND_IP" | grep -Eq "^(10\.$octet\.$octet\.$octet|172\.(1[6-9]|2[0-9]|3[01])\.$octet\.$octet|192\.168\.$octet\.$octet)\$"; then
    fail "LAN_BIND_IP must be one private IPv4 address such as 192.168.1.20 (10.x.x.x, 172.16-31.x.x or 192.168.x.x); the gateway-lan container does not start with $LAN_BIND_IP"
  fi
  check LAN_HTTP_PORT "${LAN_HTTP_PORT:-}"
  if ! printf '%s\n' "$LAN_HTTP_PORT" | grep -Eq '^[0-9]{4,5}$' || [ "$LAN_HTTP_PORT" -lt 1024 ] || [ "$LAN_HTTP_PORT" -gt 65535 ]; then
    fail "LAN_HTTP_PORT must be a port from 1024 to 65535; the gateway-lan container does not start with $LAN_HTTP_PORT"
  fi
fi
