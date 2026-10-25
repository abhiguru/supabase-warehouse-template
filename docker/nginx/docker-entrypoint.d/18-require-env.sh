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
