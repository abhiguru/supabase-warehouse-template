#!/bin/bash
# CUPS container start: creates (or repairs) the one raw queue the print functions use, then runs cupsd in the foreground.
# Every step that matters fails the start: a container that is up without the queue would only look healthy (docs/PRINTING.md).
set -euo pipefail
: "${CUPS_ADMIN_PASSWORD:?Provide an owned CUPS administrator password}"

echo "========================================="
echo "CUPS Print Server Initialization"
echo "========================================="

# Copy custom cupsd.conf if it exists
if [ -f /etc/cups/cupsd.conf.custom ]; then
    echo "Using custom cupsd.conf..."
    cp /etc/cups/cupsd.conf.custom /etc/cups/cupsd.conf
fi

# Settings (docker-compose.yml passes PRINTER_NAME, PRINTER_URI and PRINTER_DRIVER from compose.env)
CUPS_ADMIN_USER="${CUPS_ADMIN_USER:-admin}"
PRINTER_NAME="${PRINTER_NAME:-LQ1310_RAW}"
PRINTER_URI="${PRINTER_URI:-}"
PRINTER_DRIVER="${PRINTER_DRIVER:-raw}"
PRINTER_LOCATION="${PRINTER_LOCATION:-Warehouse}"
PRINTER_DESCRIPTION="${PRINTER_DESCRIPTION:-Epson LQ-1310 (raw ESC/P2)}"
if [[ ! "$PRINTER_NAME" =~ ^[A-Za-z0-9_-]{1,127}$ ]]; then
    echo "PRINTER_NAME '$PRINTER_NAME' is not a valid CUPS queue name (letters, digits, _ and - only)." >&2
    exit 1
fi

# Create admin user if it doesn't exist
if ! id "$CUPS_ADMIN_USER" &>/dev/null; then
    echo "Creating CUPS admin user: $CUPS_ADMIN_USER"
    useradd -r -G lpadmin -M "$CUPS_ADMIN_USER"
fi
echo "$CUPS_ADMIN_USER:$CUPS_ADMIN_PASSWORD" | chpasswd
echo "CUPS admin user: $CUPS_ADMIN_USER"
echo ""

echo "USB devices the container sees (/dev/bus/usb):"
if [ -d /dev/bus/usb ] && [ -n "$(ls -A /dev/bus/usb 2>/dev/null)" ]; then
    ls -R /dev/bus/usb
else
    echo "  none (no /dev/bus/usb on the host, or no USB device)"
fi

echo ""
echo "========================================="
echo "Starting CUPS daemon..."
echo "========================================="

# Start CUPS in the background to configure the queue; wait until it answers instead of a fixed sleep.
# The entrypoint's CUPS commands (lpstat, lpadmin, cupsenable, cupsaccept) talk to the local domain socket as root.
mkdir -p /run/cups
export CUPS_SERVER=/run/cups/cups.sock
/usr/sbin/cupsd
for _ in $(seq 1 30); do
    if lpstat -r 2>/dev/null | grep -q 'is running'; then break; fi
    sleep 1
done
if ! lpstat -r 2>/dev/null | grep -q 'is running'; then
    echo "cupsd did not start within 30 seconds." >&2
    exit 1
fi

# The device URI: PRINTER_URI when set; else the first usb:// Epson that CUPS lists.
if [ -z "$PRINTER_URI" ]; then
    echo "PRINTER_URI is not set: looking for a USB Epson printer (lpinfo -v)..."
    devices="$(lpinfo -v 2>&1 || true)"
    PRINTER_URI="$(printf '%s\n' "$devices" | awk '$1 == "direct" && $2 ~ /^usb:\/\// && toupper($2) ~ /EPSON/ { print $2; exit }')"
    if [ -z "$PRINTER_URI" ]; then
        {
            echo "No USB Epson printer was found. Devices CUPS lists:"
            printf '%s\n' "$devices" | sed 's/^/  /'
            echo "Check the cable and the power. If the list has no usb:// line, the host's usblp kernel module may hold the"
            echo "printer (docs/PRINTING.md, 'usblp'). To name the device yourself, set PRINTER_URI in compose.env."
        } >&2
        exit 1
    fi
    echo "Found: $PRINTER_URI"
fi

echo "Configuring printer: $PRINTER_NAME ($PRINTER_URI)..."
if ! lpstat -p "$PRINTER_NAME" &>/dev/null; then
    echo "Adding printer $PRINTER_NAME..."
    lpadmin -p "$PRINTER_NAME" \
        -E \
        -v "$PRINTER_URI" \
        -m "$PRINTER_DRIVER" \
        -L "$PRINTER_LOCATION" \
        -D "$PRINTER_DESCRIPTION" \
        -o printer-error-policy=retry-current-job
else
    # The queue survives in /etc/cups only while the container does; when it exists with another device URI, apply the new one.
    current="$(lpstat -v "$PRINTER_NAME" 2>/dev/null | sed -n "s/^device for $PRINTER_NAME: //p")"
    if [ "$current" != "$PRINTER_URI" ]; then
        echo "Printer $PRINTER_NAME exists with the device '$current'; changing it to '$PRINTER_URI'."
        lpadmin -p "$PRINTER_NAME" -v "$PRINTER_URI"
    else
        echo "Printer $PRINTER_NAME already configured"
    fi
fi
lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true
cupsenable "$PRINTER_NAME"
cupsaccept "$PRINTER_NAME"

# A queue that is not there now is a failed start, whatever the commands above said.
if ! lpstat -p "$PRINTER_NAME" >/dev/null; then
    echo "The queue $PRINTER_NAME does not exist after configuration." >&2
    exit 1
fi
lpstat -p "$PRINTER_NAME" -v "$PRINTER_NAME"

# Stop the background CUPS
pkill cupsd
sleep 1

echo ""
echo "========================================="
echo "CUPS Configuration Complete"
echo "========================================="
echo "IPP Endpoint: http://cups:631 (from containers)"
echo "Printer: $PRINTER_NAME"
echo "========================================="

exec "$@"
