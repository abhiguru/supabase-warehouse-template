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
| 400 | `INVALID_REQUEST_ID` | `request_id` is not a uuid. |
| 409 | `INVALID_STATUS`, `CANNOT_CANCEL` | `cancel-print-job` only: the job is finished, or cannot be stopped from here. |
| 502 | `CANCEL_FAILED` | `cancel-print-job` only: CUPS could not be reached. |
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
   `bash scripts/compose.sh up -d functions` (it recreates the container when `compose.env` changed; `restart` would keep the old environment), then a new `db:backup` (see the payments capability in
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
- `GET ${PRINTBRIDGE_URL}/health` with `X-Print-Token` and `X-Printer` answers 200
  `{"success": true, "printer": "<name>", "printer_found": true, "status": "<Windows spooler status>"}`, or 503
  `{"success": false, "printer_found": false, ...}` when the named Windows queue is not installed, or 401 for a wrong token.
  `get-printer-status` uses it and reports `transport: "bridge"`; it can say whether the bridge is reachable, whether the queue
  exists and the spooler's status text, not the printer's paper or ribbon state.
- `X-Printer` is always `PRINTER_NAME`; the bridge prints only to the one queue it was started with (`-Printer`) and answers 403
  for any other name. `PRINTER_NAME` in `compose.env` and `-Printer` must therefore be the same text (case does not matter).
- The bridge does not report when the job ends. A job sent to it is recorded as `unknown` ("sent to the print bridge"), never as
  `completed`.
- **Address.** The bridge binds the IPv4 address of Windows' `vEthernet (WSL...)` adapter and answers only requests whose `Host`
  is exactly that address. In WSL2's NAT mode that adapter's address is the distro's default gateway, so
  `scripts/print-bridge-url.sh` (the default gateway from `ip route`) yields the same address the bridge binds, with the port
  `PRINTBRIDGE_PORT` (default 6632). `scripts/compose.sh` works it out for every command and `start.sh` says what it found. The
  address can change at a Windows restart or `wsl --shutdown`, so it is not written to `compose.env`; but a container keeps the
  address it was created with, so `start.sh` compares it with the one just worked out and recreates the `functions` container when they
  differ. After a Windows restart, run `bash start.sh` (or `bash scripts/compose.sh up -d functions`). The bridge notices a changed address (it
  checks every 15 s), exits, and the scheduled task starts it again on the new one. A `PRINTBRIDGE_URL` in `compose.env`
  overrides the resolver; use the exact IP the bridge bound (the `start listen=` line in `%ProgramData%\Warehouse\logs`), never a
  name. That the two ends agree follows from how NAT mode is built and from the code; it has not been run on a Windows host.
  **Mirrored networking is not verified** (there is no `vEthernet (WSL)` adapter; the bridge stops with a message): use NAT mode.
  `start.sh` prints a warning when `wslinfo --networking-mode` says `mirrored`.
- **Printer name.** `PRINTER_NAME` may hold letters, digits, spaces and `_ . ( ) # / -`, so the Windows name can be used as it is,
  for example `EPSON LQ-1310 ESC/P2`.
- **The queue must spool.** In the printer's Properties > Advanced, leave "Spool print documents so program finishes printing faster"
  selected. With "Print directly to the printer" the bridge waits for the printer itself, and an off or paperless printer then blocks it.
- **What the bridge runs.** `register-tasks.ps1` copies `print-bridge.ps1` to `%ProgramData%\Warehouse\bin` (Administrators and SYSTEM
  may change it, the task account may only read and run it) and the task runs that copy, so the task does not depend on `\\wsl$` at boot.
  After an upgrade of the checkout, run `register-tasks.ps1` again (with `-Force`) to refresh the copy; it also stops the running bridge
  so a new token, queue or script takes effect at once.
- **Token.** `PRINTBRIDGE_TOKEN` is in `config/compose.env` (mode 0600). The functions refuse to send without one. The Windows side
  copies it with `register-tasks.ps1 -SetTokenFromWsl`, so it never appears on a command line, and the two cannot drift.
- **Windows firewall.** `register-tasks.ps1` adds an inbound rule "Warehouse Print" for the bridge port, limited to the WSL
  interface. Register after WSL has started once: with no WSL adapter yet the rule falls back to the address range 172.16.0.0/12. On Windows 11 22H2 and later the Hyper-V firewall for the WSL network may also need a rule. Not verified on a host.

Steps:

1. Install the printer in Windows as a local queue (any Epson driver: the bridge sends RAW and bypasses it) and print a Windows
   test page. Note the exact queue name (`Get-Printer | Format-Table Name`); put it as `PRINTER_NAME` in `config/compose.env`
   (default `LQ1310_RAW`: you may name the Windows printer that) and restart the functions later in step 4.
2. In an elevated PowerShell, in `scripts/windows` of the checkout (reach it through `\\wsl$`, or copy the folder to Windows), register
   the bridge. It asks once for the Windows password and registers the task "Warehouse Print" (at boot and every 2 minutes; a second
   copy is ignored), creates the token file, adds the firewall rule and reads them back:

       powershell -NoProfile -ExecutionPolicy Bypass -File .\register-tasks.ps1 -PrintOnly -Printer "<queue>" `
         -SetTokenFromWsl <distro> -ComposeEnv <state>/config/compose.env

   `<distro>` is the WSL distro name (`wsl -l`), `<state>` the installation's state directory inside it. The task runs as the
   install account (a SYSTEM task would not see its printer queues). Port: `-PrintPort` (default 6632); if you change it, set
   `PRINTBRIDGE_PORT` in `compose.env` too.
3. In Ubuntu: `bash start.sh` (it reports the bridge address), then
   `WAREHOUSE_STATE_DIR=<state> node scripts/set-capability.mjs printing on`, `bash scripts/compose.sh up -d functions` (not `restart`: only
   `up` re-reads `compose.env`) and a new `db:backup`.
4. Test without paper: pause the queue in Windows
   (`(Get-CimInstance Win32_Printer -Filter "Name='<queue>'") | Invoke-CimMethod -MethodName Pause`), tap Print on a GRN in the
   app, see the job with `Get-PrintJob -PrinterName "<queue>"`, remove it (`Get-PrintJob -PrinterName "<queue>" | Remove-PrintJob`) and
   resume the queue. Never test on a resumed printer with paper loaded unless you want it printed. The app then shows the job as
   `unknown` ("sent to the print bridge").

The full parameter list and the log location are in the header of `scripts/windows/print-bridge.ps1` and `register-tasks.ps1`.

## One print, one job: `request_id`

The app sends a `request_id` (uuid) with each print action and reuses it only for that action's retries after a lost answer. With one,
the function looks for a `print_jobs` row of the same user and id: found, it answers `200 {"duplicate": true}` and prints nothing;
not found, it inserts a `queued` row before sending, so two requests at once cannot both print (the unique index on
`(user_id, request_id)` stops the second). After the send the row becomes `printing`, `unknown` or `failed`. A request whose send
failed (nothing reached the printer) can be sent again with the same id. Without a `request_id`, or before migration 151, the
row is written after the send, as before.

## Cancel and stuck jobs

- `cancel-print-job` stops a job for real: IPP Cancel-Job on the CUPS queue first, and the row becomes `cancelled` only when CUPS
  cancelled it. Only a `queued` or `printing` job that has a CUPS job id can be cancelled. A bridge job (it is synchronous and has no
  id), an `unknown` job, or a `queued` row without an id answers `409 CANNOT_CANCEL`: the paper may already be printing.
- `sweep-print-jobs` (service-role key only; the 5-minute checker `scripts/watch.mjs` calls it) records a job still `queued` or
  `printing` more than 5 minutes after it was created as `unknown`, never `completed`, because nobody saw it finish.

## Operation notes

- **Staff may print** (owner decision, 2026-11-07). The print functions read documents with the server's key, so a staff member can
  print any customer's documents, as staff can already see them in the app.
- **Cancel.** "Cancel" in the app's print-jobs sheet calls `cancel-print-job` (see above); a job on the Windows bridge cannot be cancelled.
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
