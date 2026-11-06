# Printing

An Epson LQ-1310 (or a similar dot-matrix printer taking raw ESC/P2) prints GRN, dispatch and invoice forms on pre-printed
continuous stationery. Admin, supervisor and staff users may print; customers may not.

The functions build the printer bytes and hand them to **one transport**, chosen by `PRINT_TRANSPORT` in `config/compose.env`
(`functions/_shared/print-transport.ts`):

| Host | Transport | What prints |
| --- | --- | --- |
| Linux with the printer on USB | `cups` | The `cups` container (Compose profile `printing`) holds one raw queue, `LQ1310_RAW`. |
| Windows (backend in Ubuntu under WSL2) | `bridge` | A small PowerShell service on Windows receives the bytes and writes them raw to the Windows printer. No CUPS. |

Setup writes `PRINT_TRANSPORT` (`bridge` when the host is WSL, else `cups`), `PRINTER_NAME` (`LQ1310_RAW`) and, for the bridge, a
random `PRINTBRIDGE_TOKEN`. An installation that existed before gets the missing values added when `setup.sh` is rerun.

Printing is **off until you turn it on**: while the `printing` capability is false every print route answers 503
`{"success": false, "code": "PRINTING_OFF", "error": "Printing is not set up for this facility"}`, and the app hides the print
actions. The install steps below end with turning it on.

## Answers the app can rely on

Each print answer that is not a success carries a `code`:

| Status | `code` | Meaning |
| --- | --- | --- |
| 503 | `PRINTING_OFF` | The capability is off. |
| 403 | `PRINT_FORBIDDEN` | The role may not print. |
| 502 | `PRINTER_FAILED` | Nothing was printed: CUPS or the bridge could not be reached, refused, or failed. |
| 502 | `PRINT_UNCONFIRMED` | No confirmation arrived in time (`"unconfirmed": true`); the paper may or may not come out. Check the printer before printing again; the job is never resubmitted automatically. |

## Linux host: CUPS

1. Plug the printer in by USB and switch it on.
2. Find out whether the host's `usblp` kernel module holds it (see "The usblp conflict" below). On most hosts nothing is needed.
3. Optional: name the device. Without it the container uses the first `usb://` Epson that `lpinfo -v` lists, and when there is
   none it stops and prints the list it saw in `docker logs`. To pin one device, put its URI in `config/compose.env`:
   `PRINTER_URI=usb://EPSON/LQ-1310?serial=...`.
4. Start the container: `bash scripts/compose.sh --profile printing up -d --build --wait cups`. It fails (and says why in
   `docker logs`) when no USB Epson is found or the queue cannot be created; it is healthy only while the queue `LQ1310_RAW`
   exists (`lpstat -p`). Changing `PRINTER_URI` later and recreating the container changes the queue's device.
5. Turn printing on and tell the app: `WAREHOUSE_STATE_DIR=<state> node scripts/set-capability.mjs printing on`, then
   `bash scripts/compose.sh restart functions`, then a new `db:backup` (see the payments capability in
   [OPERATOR_INSTALL.md](OPERATOR_INSTALL.md) for why).
6. Check it: sign in to the app as an administrator, open a GRN, tap Print, and confirm one form with the paper in place.
   Every print needs a person at the printer.

CUPS has no published host port; only the other containers of the project reach it, and `docker/cups/config/cupsd.conf` allows
job submission from the private Docker ranges only. Its spool is a project-scoped Docker volume that the core backup does not yet
include.

### USB access of the container

The `cups` service is `privileged` and binds `/dev/bus/usb`. A printer plugged in after the container started is visible through
the bind. On a host without `/dev/bus/usb` (a VM, WSL2) Docker creates an empty directory and the container stops with "No USB Epson
printer was found". The narrower `device_cgroup_rules: ["c 189:* rmw"]` instead of `privileged` was considered and is not verified
with this image.

### The usblp conflict

Linux can bind a USB printer to the kernel's `usblp` driver. CUPS in the container reaches the printer through libusb, which then
reports the device busy, or `lpinfo -v` lists no `usb://` line. Symptom: the container fails with "No USB Epson printer was found"
although the printer is plugged in. Fix on the host: `lsmod | grep usblp`; if it is loaded, `sudo rmmod usblp`, and to keep it off
after a reboot add `blacklist usblp` to a file in `/etc/modprobe.d/` and run `sudo update-initramfs -u`. Not verified on a real
LQ-1310 host. An alternative is a `PRINTER_URI` of the form `file:/dev/usb/lp0` with the device passed in; that is also not verified.

## Windows host: the print bridge

On a Windows host the printer belongs to Windows, and the backend runs in Ubuntu under WSL2 without a USB path to it. The
**print bridge** is a small PowerShell HTTP service on Windows that the functions call: `POST /print/raw` writes the bytes to the
Windows printer unchanged. There is no CUPS container.

How it works:

- The functions send `POST ${PRINTBRIDGE_URL}/print/raw` with `Content-Type: application/octet-stream`, the printer name in
  `X-Printer`, a document name in `X-Doc-Name` and the shared secret in `X-Print-Token`. The body is the raw printer bytes
  (binary-clean: page-length parameters contain the bytes 0A and 0C). The user's own session token is never forwarded. The bridge
  answers JSON; `{"success": true}` with a 2xx status is a success.
- `GET ${PRINTBRIDGE_URL}/health` with `X-Print-Token` answers `{"success": true}` (optionally `"printer_found": false` when the
  named Windows printer is not installed). `get-printer-status` uses it and reports `transport: "bridge"`; it can say whether the
  bridge is reachable, not the printer's paper or queue state.
- The bridge does not report when the job ends. A job sent to it is recorded as `unknown` ("sent to the print bridge"), never as
  `completed`.
- **Address.** The Windows host is the distro's default gateway in WSL2's NAT mode. That address can change at a Windows restart,
  so `scripts/compose.sh` works out `http://<gateway>:9631` (`scripts/print-bridge-url.sh`, port `PRINTBRIDGE_PORT`) for every
  command, and `start.sh` says what it found. A `PRINTBRIDGE_URL` written in `compose.env` overrides it. **Mirrored networking is not
  verified**; use NAT mode or set `PRINTBRIDGE_URL`.
- **Token.** `PRINTBRIDGE_TOKEN` is in `config/compose.env`. The functions refuse to send without one. Give the Windows side the same
  value through a file, never on a command line.
- **Windows firewall.** An inbound rule for the bridge port, scoped to the WSL subnet (and, on Windows 11 22H2 and later, the Hyper-V
  firewall for the WSL network), is needed. Not verified on a host.

Steps:

1. Install the printer in Windows with the Epson driver and print a Windows test page. Note its exact name; use it as
   `PRINTER_NAME` in `compose.env` (default `LQ1310_RAW`: you can name the Windows printer that).
2. On Windows, register the bridge: `scripts/windows/register-tasks.ps1 -Printer` (it runs `scripts/windows/print-bridge.ps1` as a
   scheduled task of the install user, who sees the user's printers, with the token read from a file). (These two scripts are added with the
   bridge itself; until they are in `scripts/windows/`, there is no bridge to register.)
3. Open the port in the Windows firewall for the WSL subnet.
4. In Ubuntu: `bash start.sh` (it reports the bridge address), then
   `WAREHOUSE_STATE_DIR=<state> node scripts/set-capability.mjs printing on`, `bash scripts/compose.sh restart functions` and a new
   `db:backup`.
5. Check it as in step 6 of the Linux host.

## Operation notes

- **Staff may print** (owner decision, 2026-11-07). The print functions read documents with the server's key, so a staff member can
  print any customer's documents, as staff can already see them in the app.
- **Cancel.** "Cancel" in the app's print-jobs sheet marks the row; it does not stop a job that CUPS or the bridge already has.
- A disappeared job is not proof of physical output; an uncertain job is never resubmitted automatically.
- Keep CUPS administration and the bridge token private to the server.

## What the code guarantees (tests that run without a printer)

- **Invoice pages by printed rows.** A page holds at most 20 item rows, the GRN group header rows included; a group that goes on to
  the next page repeats its header there, marked `contd.` (`functions/_shared/invoice-print-layout.ts`).
- **Server line amounts.** Each invoice line's storage amount is the one `get_invoice_range_for_print` returns (`storage_amount`,
  `pricing_mode`, `labour_amount`); the print never computes an amount (`functions/_shared/invoice-print-amounts.ts`).
- **Validated IPP replies.** On the CUPS path a print is submitted only when the reply has a successful status and a positive
  integer job id; otherwise the job is `unknown` and the caller gets 502 `PRINT_UNCONFIRMED`
  (`functions/_shared/ipp-validate.ts`).
- **`unknown` outcomes.** The status monitor records completed, cancelled or failed only from a final state CUPS reports; a job CUPS
  no longer lists, or one still running after 35 s, is `unknown`. The submission is given up after 8 s
  (`functions/_shared/print-monitor-rule.ts`).
- **Indian financial year.** An invoice print without `inv_fin_year` uses the current Indian financial year (1 April to 31 March).

## Still physical acceptance

Nothing here replaces a paper run (every print needs the owner's permission):

- GRN, dispatch and a multi-page invoice on the LQ-1310 continuous form, the totals and the next form on their printed fields;
- a USB printer under Linux CUPS, including `usblp`, unplug and replug, paper out, and an unattended reboot;
- the bridge on a real Windows host: address, firewall, the task after a restart, a printer that is off;
- the shape of `ipp`'s decoded replies on a real CUPS for Print-Job, Get-Job-Attributes and Get-Printer-Attributes;
- a procedure for staff to check `unknown` jobs at the printer before anyone prints again.
