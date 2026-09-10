#!/bin/bash
# Start Supabase services

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"

echo "Starting Supabase services..."

if [ ! -f "$DOCKER_DIR/.env" ]; then
    echo "ERROR: docker/.env not found. Run ./setup.sh first."
    exit 1
fi

cd "$DOCKER_DIR"
docker compose -f docker-compose.yml -f docker-compose.override.yml --env-file .env up -d --remove-orphans

echo ""
echo "Services started."
echo "  API:    http://localhost:8000"
echo "  Studio: http://localhost:54323"
echo ""
echo "Check status: ./health-check.sh"
