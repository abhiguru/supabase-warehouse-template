#!/bin/bash
#
# rotate-keys.sh - Regenerate JWT keys and sync configuration
#
# Usage:
#   ./rotate-keys.sh              # Regenerate all keys
#   ./rotate-keys.sh --check      # Check current key status
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/docker/.env"
DOCKER_DIR="$SCRIPT_DIR/docker"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}ERROR: docker/.env not found. Run ./setup.sh first.${NC}"
    exit 1
fi

if [ "$1" = "--check" ]; then
    echo "=== Key Status ==="
    JWT_SECRET=$(grep "^JWT_SECRET=" "$ENV_FILE" | cut -d'=' -f2)
    ANON_KEY=$(grep "^ANON_KEY=" "$ENV_FILE" | cut -d'=' -f2)

    echo "JWT_SECRET: ${JWT_SECRET:0:20}... (${#JWT_SECRET} chars)"
    echo "ANON_KEY: ${ANON_KEY:0:30}..."

    # Check for demo keys
    if [[ "$ANON_KEY" == *"supabase-demo"* ]]; then
        echo -e "${RED}WARNING: Demo keys detected! Run ./rotate-keys.sh to generate production keys.${NC}"
    else
        echo -e "${GREEN}Keys appear to be custom-generated.${NC}"
    fi
    exit 0
fi

echo "=== Rotating JWT Keys ==="

# Generate new JWT_SECRET
JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n' | head -c 64)
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" "$ENV_FILE"
echo -e "${GREEN}Generated new JWT_SECRET${NC}"

# Generate JWT tokens
generate_jwt() {
    local role="$1"
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload="{\"iss\" : \"supabase\", \"role\" : \"$role\", \"exp\" : 4920311268}"
    local header_b64=$(echo -n "$header" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    local payload_b64=$(echo -n "$payload" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    local signature=$(echo -n "${header_b64}.${payload_b64}" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
    echo "${header_b64}.${payload_b64}.${signature}"
}

ANON_KEY=$(generate_jwt "anon")
SERVICE_ROLE_KEY=$(generate_jwt "service_role")

sed -i "s|^ANON_KEY=.*|ANON_KEY=$ANON_KEY|" "$ENV_FILE"
sed -i "s|^SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY|" "$ENV_FILE"
echo -e "${GREEN}Generated new ANON_KEY${NC}"
echo -e "${GREEN}Generated new SERVICE_ROLE_KEY${NC}"

echo ""
echo -e "${YELLOW}Keys rotated. Restart services to apply:${NC}"
echo "  ./stop.sh && ./start.sh"
echo ""
echo "New ANON_KEY: ${ANON_KEY:0:30}..."
