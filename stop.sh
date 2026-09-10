#!/bin/bash
# Stop Supabase services

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"

echo "Stopping Supabase services..."

cd "$DOCKER_DIR"
docker compose -f docker-compose.yml -f docker-compose.override.yml --env-file .env down

echo ""
echo "Services stopped."
echo "To restart: ./start.sh"
