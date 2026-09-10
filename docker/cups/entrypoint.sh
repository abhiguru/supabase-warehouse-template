#!/bin/bash
set -e

echo "========================================="
echo "CUPS Print Server Initialization"
echo "========================================="

# Copy custom cupsd.conf if it exists
if [ -f /etc/cups/cupsd.conf.custom ]; then
    echo "Using custom cupsd.conf..."
    cp /etc/cups/cupsd.conf.custom /etc/cups/cupsd.conf
fi

# Configurable printer settings via environment variables
CUPS_ADMIN_USER="${CUPS_ADMIN_USER:-admin}"
CUPS_ADMIN_PASSWORD="${CUPS_ADMIN_PASSWORD:-admin}"
PRINTER_NAME="${PRINTER_NAME:-MyPrinter}"
PRINTER_URI="${PRINTER_URI:-usb://Unknown/Printer}"
PRINTER_DRIVER="${PRINTER_DRIVER:-raw}"
PRINTER_LOCATION="${PRINTER_LOCATION:-Office}"
PRINTER_DESCRIPTION="${PRINTER_DESCRIPTION:-Default Printer}"

# Create admin user if it doesn't exist
if ! id "$CUPS_ADMIN_USER" &>/dev/null; then
    echo "Creating CUPS admin user: $CUPS_ADMIN_USER"
    useradd -r -G lpadmin -M "$CUPS_ADMIN_USER" 2>/dev/null || true
fi

echo "$CUPS_ADMIN_USER:$CUPS_ADMIN_PASSWORD" | chpasswd

echo "CUPS admin user: $CUPS_ADMIN_USER"
echo ""

# List USB devices (for debugging)
echo "Checking for USB devices..."
if [ -d /dev/usb ]; then
    ls -la /dev/usb/ 2>/dev/null || echo "No USB devices found in /dev/usb/"
else
    echo "/dev/usb directory not mounted"
fi

echo ""
echo "========================================="
echo "Starting CUPS daemon..."
echo "========================================="

# Start CUPS in background to configure printer
/usr/sbin/cupsd
sleep 2

# Clear any stuck jobs from previous sessions
echo "Clearing any stuck print jobs..."
cancel -a 2>/dev/null || true
rm -f /var/spool/cups/d* /var/spool/cups/c* 2>/dev/null || true

echo "Configuring printer: $PRINTER_NAME..."
if ! lpstat -p "$PRINTER_NAME" &>/dev/null; then
    echo "Adding printer $PRINTER_NAME..."
    lpadmin -p "$PRINTER_NAME" \
        -E \
        -v "$PRINTER_URI" \
        -m "$PRINTER_DRIVER" \
        -L "$PRINTER_LOCATION" \
        -D "$PRINTER_DESCRIPTION" \
        -o printer-error-policy=retry-current-job 2>/dev/null || true

    lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true 2>/dev/null || true
    cupsenable "$PRINTER_NAME" 2>/dev/null || true
    cupsaccept "$PRINTER_NAME" 2>/dev/null || true
    echo "Printer $PRINTER_NAME configured"
else
    echo "Printer $PRINTER_NAME already configured"
    cupsenable "$PRINTER_NAME" 2>/dev/null || true
    cupsaccept "$PRINTER_NAME" 2>/dev/null || true
fi

# Stop the background CUPS
pkill cupsd
sleep 1

echo ""
echo "========================================="
echo "CUPS Configuration Complete"
echo "========================================="
echo "Web UI: http://localhost:6310 (external)"
echo "IPP Endpoint: http://cups:631 (from containers)"
echo "Printer: $PRINTER_NAME"
echo "========================================="

exec "$@"
