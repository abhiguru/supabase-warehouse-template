# CUPS Printing Integration

## Overview

The template includes a containerized CUPS print server accessible via IPP (Internet Printing Protocol) from edge functions.

## Enable Printing

```bash
docker compose --profile printing up -d
```

CUPS Web UI: http://localhost:6310

## Architecture

```
Edge Function → IPP Protocol → CUPS Container → USB Printer
(print-via-ipp)                 (cups:631)
```

## Configuration

Set printer details in `docker/.env`:
```
CUPS_ADMIN_USER=admin
CUPS_ADMIN_PASSWORD=changeme
```

Configure the printer in `docker/cups/entrypoint.sh` via environment variables:
```
PRINTER_NAME=MyPrinter
PRINTER_URI=usb://Manufacturer/Model
PRINTER_DRIVER=raw
```

## Edge Functions

### Get Printer Status
```bash
curl -X POST http://localhost:8000/functions/v1/get-printer-status \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"printer_name": "default"}'
```

### Print via IPP
```bash
curl -X POST http://localhost:8000/functions/v1/print-via-ipp \
  -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"content": "Hello World\n", "printer_name": "default", "title": "Test Print"}'
```

## Shared Libraries

- `_shared/ipp-client.ts` — CUPS IPP client wrapper
- `_shared/ipp-types.ts` — IPP type definitions and state mapping

## Troubleshooting

1. **Printer not found**: Check CUPS Web UI at http://localhost:6310
2. **Connection refused**: Verify CUPS container is running: `docker ps | grep cups`
3. **USB not detected**: Container needs `privileged: true` and USB device mounts
