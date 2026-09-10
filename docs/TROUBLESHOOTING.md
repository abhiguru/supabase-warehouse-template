# Troubleshooting

## Common Issues

### Services won't start
```bash
# Check which containers are running
docker ps --format "table {{.Names}}\t{{.Status}}" | grep supabase

# Check logs for a specific service
docker logs supabase-db
docker logs supabase-kong
docker logs supabase-rest
```

### API returns 502/503
```bash
# Check if Kong is healthy
docker logs supabase-kong --tail 20

# Check if PostgREST is connected to DB
docker logs supabase-rest --tail 20

# Restart Kong
docker restart supabase-kong
```

### Database connection issues
```bash
# Check DB health
docker exec supabase-db pg_isready -U postgres

# Check active connections
docker exec supabase-db psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

# Check for long-running queries
docker exec supabase-db psql -U postgres -c "
  SELECT pid, now() - pg_stat_activity.query_start AS duration, query
  FROM pg_stat_activity
  WHERE state != 'idle'
  ORDER BY duration DESC
  LIMIT 5;"
```

### Edge functions not working
```bash
# Check edge function logs
docker logs supabase-edge-functions --tail 50

# Verify functions are mounted
docker exec supabase-edge-functions ls /home/deno/functions/

# Restart edge functions
docker restart supabase-edge-functions
```

### Slow API responses
```bash
# Check container resource usage
docker stats --no-stream | grep supabase

# Check for restarting containers (crash loops)
docker ps | grep -i restarting

# Check PostgREST connection pool
docker logs supabase-rest 2>&1 | grep -i pool
```

### Printer not responding
```bash
# Check CUPS container
docker logs supabase-cups

# Check CUPS web UI
curl http://localhost:6310/

# List printers
docker exec supabase-cups lpstat -p
```

### PDF generation fails
```bash
# Check Gotenberg health
curl http://localhost:3100/health

# Check Gotenberg logs
docker logs supabase-gotenberg --tail 20

# Restart Gotenberg (clears Chromium memory)
docker restart supabase-gotenberg
```

## Reset Everything

```bash
./stop.sh
cd docker
docker compose down -v --remove-orphans
rm -rf volumes/db/data
cd ..
./setup.sh
```

**Warning**: This destroys all data. Back up first if needed.
