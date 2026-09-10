#!/bin/bash
#
# setup.sh - One-command bootstrap for Supabase Warehouse Template
#
# Usage: ./setup.sh
#
# This script:
# 1. Checks prerequisites (Docker, Docker Compose, openssl, jq)
# 2. Checks minimum resources (4GB RAM, 10GB disk)
# 3. Copies .env.example -> docker/.env
# 4. Generates all secrets (JWT keys, passwords, tokens)
# 5. Generates kong.yml from template
# 6. Copies edge functions to docker volumes
# 7. Starts containers
# 8. Applies database migrations
# 9. Runs health checks
# 10. Prints summary

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"
ENV_FILE="$DOCKER_DIR/.env"
FUNCTIONS_SRC="$SCRIPT_DIR/functions"
FUNCTIONS_DST="$DOCKER_DIR/volumes/functions"
MIGRATIONS_DIR="$SCRIPT_DIR/migrations"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BOLD}${BLUE}==> $1${NC}"; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Supabase Warehouse Template - Setup           ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
# Step 1: Check prerequisites
# ============================================================
log_step "Step 1: Checking prerequisites"

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 is required but not installed."
        echo "  Install: $2"
        exit 1
    fi
    log_info "$1 found: $(command -v "$1")"
}

check_command "docker" "https://docs.docker.com/get-docker/"
check_command "openssl" "apt install openssl / brew install openssl"

# Check Docker is running
if ! docker info &>/dev/null; then
    log_error "Docker is not running. Please start Docker and try again."
    exit 1
fi
log_info "Docker is running"

# Check Docker Compose
if docker compose version &>/dev/null; then
    log_info "Docker Compose: $(docker compose version --short 2>/dev/null)"
else
    log_error "Docker Compose v2 is required. Install: https://docs.docker.com/compose/install/"
    exit 1
fi

# Optional: jq
if command -v jq &>/dev/null; then
    log_info "jq found (optional)"
else
    log_warn "jq not found (optional, install for better output)"
fi

# ============================================================
# Step 2: Check system resources
# ============================================================
log_step "Step 2: Checking system resources"

# Check RAM (need at least 4GB)
if command -v free &>/dev/null; then
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_RAM_MB" -lt 3500 ]; then
        log_warn "Only ${TOTAL_RAM_MB}MB RAM available. Recommended: 4GB+"
    else
        log_info "RAM: ${TOTAL_RAM_MB}MB"
    fi
fi

# Check disk space (need at least 10GB)
DISK_FREE_GB=$(df -BG "$SCRIPT_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
if [ "$DISK_FREE_GB" -lt 10 ]; then
    log_warn "Only ${DISK_FREE_GB}GB disk free. Recommended: 10GB+"
else
    log_info "Disk free: ${DISK_FREE_GB}GB"
fi

# ============================================================
# Step 3: Create .env from template
# ============================================================
log_step "Step 3: Setting up environment"

if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}  docker/.env already exists.${NC}"
    read -p "  Overwrite with fresh config? (y/N): " OVERWRITE
    if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
        log_info "Keeping existing .env"
    else
        cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
        log_info "Copied .env.example -> docker/.env"
    fi
else
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    log_info "Copied .env.example -> docker/.env"
fi

# ============================================================
# Step 4: Generate secrets
# ============================================================
log_step "Step 4: Generating secrets"

# Generate random string helper
rand_string() {
    openssl rand -hex "$1" 2>/dev/null | head -c "$2"
}

rand_base64() {
    openssl rand -base64 "$1" 2>/dev/null | tr -d '\n' | head -c "$2"
}

# Generate POSTGRES_PASSWORD
POSTGRES_PASS=$(rand_string 24 32)
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$POSTGRES_PASS|" "$ENV_FILE"
log_info "Generated POSTGRES_PASSWORD"

# Generate JWT_SECRET (32+ characters)
JWT_SECRET=$(rand_base64 48 64)
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$JWT_SECRET|" "$ENV_FILE"
log_info "Generated JWT_SECRET"

# Generate ANON_KEY and SERVICE_ROLE_KEY using JWT_SECRET
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
log_info "Generated ANON_KEY"
log_info "Generated SERVICE_ROLE_KEY"

# Generate DASHBOARD_PASSWORD
DASHBOARD_PASS=$(rand_base64 24 32)
sed -i "s|^DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=$DASHBOARD_PASS|" "$ENV_FILE"
log_info "Generated DASHBOARD_PASSWORD"

# Generate SECRET_KEY_BASE (64+ chars for Realtime/Supavisor)
SECRET_KEY_BASE=$(rand_string 64 128)
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$SECRET_KEY_BASE|" "$ENV_FILE"
log_info "Generated SECRET_KEY_BASE"

# Generate VAULT_ENC_KEY (exactly 32 hex chars)
VAULT_ENC_KEY=$(rand_string 16 32)
sed -i "s|^VAULT_ENC_KEY=.*|VAULT_ENC_KEY=$VAULT_ENC_KEY|" "$ENV_FILE"
log_info "Generated VAULT_ENC_KEY"

# Generate GRAFANA_ADMIN_PASS
GRAFANA_PASS=$(rand_base64 24 32)
sed -i "s|^GRAFANA_ADMIN_PASS=.*|GRAFANA_ADMIN_PASS=$GRAFANA_PASS|" "$ENV_FILE"
log_info "Generated GRAFANA_ADMIN_PASS"

# Generate CUPS_ADMIN_PASSWORD
CUPS_PASS=$(rand_base64 24 32)
sed -i "s|^CUPS_ADMIN_PASSWORD=.*|CUPS_ADMIN_PASSWORD=$CUPS_PASS|" "$ENV_FILE"
log_info "Generated CUPS_ADMIN_PASSWORD"

# Generate Logflare tokens
LOGFLARE_TOKEN=$(rand_string 32 64)
sed -i "s|^LOGFLARE_LOGGER_BACKEND_API_KEY=.*|LOGFLARE_LOGGER_BACKEND_API_KEY=$LOGFLARE_TOKEN|" "$ENV_FILE"
sed -i "s|^LOGFLARE_PUBLIC_ACCESS_TOKEN=.*|LOGFLARE_PUBLIC_ACCESS_TOKEN=$LOGFLARE_TOKEN|" "$ENV_FILE"
sed -i "s|^LOGFLARE_PRIVATE_ACCESS_TOKEN=.*|LOGFLARE_PRIVATE_ACCESS_TOKEN=$LOGFLARE_TOKEN|" "$ENV_FILE"
sed -i "s|^LOGFLARE_API_KEY=.*|LOGFLARE_API_KEY=$LOGFLARE_TOKEN|" "$ENV_FILE"
log_info "Generated Logflare tokens"

# Set secure file permissions
chmod 600 "$ENV_FILE"
log_info "Set .env permissions to 600"

# ============================================================
# Step 5: Generate kong.yml from template
# ============================================================
log_step "Step 5: Generating Kong configuration"

mkdir -p "$DOCKER_DIR/volumes/api"
cp "$DOCKER_DIR/kong.yml" "$DOCKER_DIR/volumes/api/kong.yml"
log_info "Copied kong.yml to volumes/api/"

# ============================================================
# Step 6: Copy edge functions
# ============================================================
log_step "Step 6: Copying edge functions"

mkdir -p "$FUNCTIONS_DST"
if [ -d "$FUNCTIONS_SRC" ]; then
    cp -r "$FUNCTIONS_SRC"/* "$FUNCTIONS_DST/"
    log_info "Copied edge functions to docker/volumes/functions/"
    # List functions
    for dir in "$FUNCTIONS_DST"/*/; do
        [ -d "$dir" ] && echo "  - $(basename "$dir")"
    done
else
    log_warn "No functions directory found"
fi

# ============================================================
# Step 7: Start containers
# ============================================================
log_step "Step 7: Starting Docker containers"

cd "$DOCKER_DIR"
docker compose -f docker-compose.yml -f docker-compose.override.yml --env-file .env up -d --remove-orphans 2>&1 | tail -5

log_info "Containers starting..."

# ============================================================
# Step 8: Wait for database and apply migrations
# ============================================================
log_step "Step 8: Waiting for database"

MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if docker exec supabase-db pg_isready -U postgres -h localhost &>/dev/null; then
        log_info "Database is ready"
        break
    fi
    WAITED=$((WAITED + 2))
    echo -n "."
    sleep 2
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
    log_error "Database did not become ready in ${MAX_WAIT}s"
    echo "  Check: docker logs supabase-db"
    exit 1
fi

# Apply migrations
log_step "Step 9: Applying database migrations"

for migration in "$MIGRATIONS_DIR"/*.sql; do
    if [ -f "$migration" ]; then
        MIGRATION_NAME=$(basename "$migration")
        echo -n "  Applying $MIGRATION_NAME... "
        if docker exec -i supabase-db psql -U postgres -d postgres < "$migration" &>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            log_warn "Migration $MIGRATION_NAME failed - check manually"
        fi
    fi
done

# ============================================================
# Step 10: Health check
# ============================================================
log_step "Step 10: Running health checks"

sleep 5

# Check containers
HEALTHY=0
TOTAL=0
for container in supabase-db supabase-kong supabase-rest supabase-studio supabase-storage supabase-edge-functions supabase-gotenberg; do
    TOTAL=$((TOTAL + 1))
    STATUS=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
    if [ "$STATUS" = "running" ]; then
        log_info "$container: running"
        HEALTHY=$((HEALTHY + 1))
    else
        log_warn "$container: $STATUS"
    fi
done

# Check API
sleep 3
API_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8000/rest/v1/" -H "apikey: $ANON_KEY" 2>/dev/null || echo "000")
if [ "$API_CODE" = "200" ]; then
    log_info "API Gateway: responding (HTTP $API_CODE)"
else
    log_warn "API Gateway: HTTP $API_CODE (may still be starting)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   Setup Complete!                                ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Services:${NC}"
echo "  API Gateway:     http://localhost:8000"
echo "  Supabase Studio: http://localhost:54323"
echo "  Database:        localhost:5433"
echo "  Gotenberg:       http://localhost:3100"
echo ""
echo -e "${BOLD}Studio Login:${NC}"
echo "  Username: supabase"
echo "  Password: $DASHBOARD_PASS"
echo ""
echo -e "${BOLD}Test the API:${NC}"
echo "  curl http://localhost:8000/functions/v1/hello \\"
echo "    -H 'Authorization: Bearer $ANON_KEY'"
echo ""
echo -e "${BOLD}Generate a PDF:${NC}"
echo "  curl -X POST http://localhost:8000/functions/v1/generate-sample-pdf \\"
echo "    -H 'Authorization: Bearer $ANON_KEY' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{}' --output sample.pdf"
echo ""
echo -e "${BOLD}Optional profiles:${NC}"
echo "  Printing:   docker compose --profile printing up -d"
echo "  Pooler:     docker compose --profile pooler up -d"
echo "  Monitoring: docker compose --profile monitoring up -d"
echo ""
echo -e "${BOLD}Files:${NC}"
echo "  Environment: docker/.env"
echo "  Compose:     docker/docker-compose.yml"
echo ""
echo -e "${BOLD}$HEALTHY/$TOTAL${NC} core containers running."
