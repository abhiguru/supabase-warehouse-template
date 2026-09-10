#!/bin/bash
# Supabase Health Check

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/docker"
ANON_KEY=$(grep "^ANON_KEY=" "$DOCKER_DIR/.env" 2>/dev/null | cut -d'=' -f2)

echo "=== Supabase Health Check ==="
echo "Date: $(date)"
echo ""

echo "=== Service Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(supabase|realtime)" | sort

echo ""
echo "=== Unhealthy/Restarting Services ==="
UNHEALTHY=$(docker ps --format "{{.Names}}: {{.Status}}" | grep -E "(unhealthy|Restarting)")
if [ -z "$UNHEALTHY" ]; then
    echo "All services healthy"
else
    echo "Issues detected:"
    echo "$UNHEALTHY"
fi

echo ""
echo "=== API Response ==="
if [ -n "$ANON_KEY" ]; then
    API_RESPONSE=$(curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s" \
      http://localhost:8000/rest/v1/ \
      -H "apikey: $ANON_KEY" 2>/dev/null)
    echo "API: $API_RESPONSE"
else
    echo "ANON_KEY not found in .env - skipping API check"
fi

echo ""
echo "=== Database ==="
docker exec -i supabase-db psql -U postgres -d postgres -c "SELECT count(*) as active_connections FROM pg_stat_activity;" 2>/dev/null | grep -E "^[[:space:]]*[0-9]+" || echo "Database not reachable"

echo ""
echo "=== Edge Functions ==="
if [ -n "$ANON_KEY" ]; then
    HELLO=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/functions/v1/hello -H "Authorization: Bearer $ANON_KEY" 2>/dev/null)
    echo "hello function: HTTP $HELLO"
else
    echo "Skipped (no ANON_KEY)"
fi

echo ""
echo "=== Gotenberg (PDF) ==="
GOTENBERG=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3100/health 2>/dev/null)
echo "Gotenberg: HTTP $GOTENBERG"

echo ""
echo "=== Done ==="
