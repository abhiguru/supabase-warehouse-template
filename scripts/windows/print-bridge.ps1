<#
.SYNOPSIS
Windows print bridge: lets the warehouse backend (in WSL2, no CUPS) send raw printer bytes (ESC/P for an Epson LQ-1310 or
similar dot-matrix printer) to a local Windows print queue.

.DESCRIPTION
Windows PowerShell 5.1 or later. Listens with System.Net.HttpListener on one address and port and writes each job to the Windows
spooler with the RAW datatype (winspool.drv OpenPrinter, StartDocPrinter, WritePrinter, EndDocPrinter), so the printer driver is
bypassed and every byte 0x00-0xFF reaches the printer unchanged.

  POST /print/raw   body = raw printer bytes (application/octet-stream, at most 2 MB)
                    headers: X-Printer (queue name, must equal -Printer, case-insensitive), X-Doc-Name, X-Print-Token
                    200 {"success":true} once the job is in the spooler; otherwise 4xx/5xx {"success":false,"error":"..."}
  GET  /health      {"success":true,"printer":"<name>","printer_found":true,"status":"<spooler status>"}
                    (queue missing: 503 {"success":false,"printer":"<name>","printer_found":false,"error":"..."})   (token required too)

Rules: the only queue it prints to is -Printer (any other X-Printer answers 403); the token is read from -TokenFile at start
(the bridge refuses to start when the file is missing or empty) and compared in constant time; one job at a time; a request
read timeout of 30 seconds; no body is logged and the token never is. It never prints anything by itself on start.

Log: one line per request in %ProgramData%\Warehouse\logs\print-bridge-YYYYMMDD.log (one file per day, files older than 14
days are deleted at start and at midnight): time, remote address, method, path, status, bytes, queue, document name, note.

Listen address: by default the IPv4 address of the "vEthernet (WSL...)" adapter, so only the WSL side can reach it. That adapter
appears when WSL runs; the bridge waits up to 2 minutes for it, then stops with a clear message. -ListenAddress overrides this
(use an explicit IPv4 address of this PC, firewalled by you; wildcards such as 0.0.0.0, + or * are not accepted). http.sys
matches the Host header: the client must use exactly the bound IP in its URL (PRINTBRIDGE_URL), not a name or another address of
this PC. With the automatic address the bridge re-checks the adapter every 15 seconds and exits when the address changed
(wsl --shutdown, reboot); the scheduled task starts it again within 2 minutes on the new address, and the instance
re-resolves the Windows address at its next start.

Normally started by the scheduled task "Warehouse Print" that register-tasks.ps1 -Printer creates (the task runs as the install
account because a SYSTEM task does not see per-user printer queues). Binding a specific address needs an elevated account or a
urlacl; the task runs elevated.

Operator steps (Windows host, backend installed in WSL2):
 1. Install the LQ-1310 on Windows as a LOCAL queue (USB or parallel port). Any driver works: RAW bypasses it.
 2. Find the queue name:   Get-Printer | Format-Table Name, DriverName, PortName, PrinterStatus
 3. From an elevated PowerShell, in this folder, register the bridge task (asks once for the Windows password):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\register-tasks.ps1 -PrintOnly -Printer "EPSON LQ-1310" `
        -SetTokenFromWsl Ubuntu-24.04 -ComposeEnv /path/to/state/config/compose.env
    -SetTokenFromWsl copies PRINTBRIDGE_TOKEN from the instance's compose.env into the token file (see register-tasks.ps1).
 4. Make sure the instance uses the bridge (PRINT_TRANSPORT, PRINTBRIDGE_URL, PRINTER_NAME as the install docs say) and restart it.
 5. Test with no paper: pause the queue, send a job, look at the queue, remove the job.
      Pause:       (Get-CimInstance Win32_Printer -Filter "Name='EPSON LQ-1310'") | Invoke-CimMethod -MethodName Pause
      (or printui: rundll32 printui.dll,PrintUIEntry /o /n"EPSON LQ-1310", then Printer > Pause Printing)
      Send a job from the app (or POST some bytes to /print/raw), then:   Get-PrintJob -PrinterName "EPSON LQ-1310"
      Remove it:   Get-PrintJob -PrinterName "EPSON LQ-1310" | Remove-PrintJob
      Resume:      (Get-CimInstance Win32_Printer -Filter "Name='EPSON LQ-1310'") | Invoke-CimMethod -MethodName Resume
    Never test by sending a job to a resumed printer with paper loaded unless you want it printed.

.PARAMETER Printer
Name of the local Windows print queue (as Get-Printer shows it). The only queue this bridge prints to.

.PARAMETER Port
TCP port. Default 6632.

.PARAMETER TokenFile
File that holds the shared token (one line, hex). Default %ProgramData%\Warehouse\print-bridge.token.

.PARAMETER ListenAddress
IPv4 address to bind. Default: the vEthernet (WSL) adapter's IPv4 address.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\print-bridge.ps1 -Printer "EPSON LQ-1310"

Runs the bridge in the foreground on the WSL adapter, port 6632 (stop with Ctrl+C). Normally the scheduled task does this.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\print-bridge.ps1 -Printer "EPSON LQ-1310" -Port 6700 -ListenAddress 172.20.80.1

Explicit address and port.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Printer,
    [ValidateRange(1024, 65535)][int]$Port = 6632,
    [string]$TokenFile = (Join-Path $env:ProgramData 'Warehouse\print-bridge.token'),
    [string]$ListenAddress
)

$ErrorActionPreference = 'Stop'
$MaxBody = 2MB
$LogDir = Join-Path $env:ProgramData 'Warehouse\logs'

function Stop-Bridge([string]$Message) {
    [Console]::Error.WriteLine("print-bridge: $Message")
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Printer)) { Stop-Bridge '-Printer must not be empty.' }

# ---- Token ----
if (-not (Test-Path -LiteralPath $TokenFile -PathType Leaf)) { Stop-Bridge "Token file '$TokenFile' does not exist. Create it with register-tasks.ps1 -Printer ... first." }
$token = ([IO.File]::ReadAllText($TokenFile)).Trim()
if ([string]::IsNullOrEmpty($token)) { Stop-Bridge "Token file '$TokenFile' is empty." }
$tokenHash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($token))
$token = $null

# ---- Listen address ----
function Get-WslAddress {
    try {
        $f = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.InterfaceAlias -like 'vEthernet (WSL*' } | Select-Object -First 1
        if ($f) { return $f.IPAddress }
    } catch { }
    return $null
}
$autoAddress = -not $ListenAddress
if ($autoAddress) {
    $deadline = (Get-Date).AddSeconds(120)
    do {
        $ListenAddress = Get-WslAddress
        if ($ListenAddress) { break }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    if (-not $ListenAddress) {
        Stop-Bridge 'No "vEthernet (WSL)" adapter with an IPv4 address was found (WSL is not running, or WSL uses mirrored networking). Start WSL, or pass -ListenAddress explicitly.'
    }
}
$parsedAddress = $null
if (-not [Net.IPAddress]::TryParse($ListenAddress, [ref]$parsedAddress) -or $parsedAddress.AddressFamily -ne 'InterNetwork') {
    Stop-Bridge "-ListenAddress '$ListenAddress' is not an IPv4 address."
}
if ($parsedAddress.Equals([Net.IPAddress]::Any)) { Stop-Bridge '-ListenAddress 0.0.0.0 is not accepted; give a specific IPv4 address.' }

# ---- Spooler access (inline C#, winspool.drv) ----
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class WarehouseRawPrinter
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private class DOC_INFO_1
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
        [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
        [MarshalAs(UnmanagedType.LPWStr)] public string pDatatype;
    }

    [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool OpenPrinter(string pPrinterName, out IntPtr phPrinter, IntPtr pDefault);
    [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern int StartDocPrinter(IntPtr hPrinter, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOC_INFO_1 di);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool StartPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool WritePrinter(IntPtr hPrinter, IntPtr pBytes, int dwCount, out int dwWritten);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool EndPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool EndDocPrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool AbortPrinter(IntPtr hPrinter);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr hPrinter);

    private static Exception Fail(string step)
    {
        int code = Marshal.GetLastWin32Error();
        return new Win32Exception(code, step + " failed: " + new Win32Exception(code).Message + " (Win32 error " + code + ")");
    }

    // Writes data as ONE RAW job. Throws Win32Exception on any failure.
    public static void SendRaw(string printer, string docName, byte[] data)
    {
        IntPtr h;
        if (!OpenPrinter(printer, out h, IntPtr.Zero)) throw Fail("OpenPrinter");
        bool docStarted = false, pageStarted = false;
        IntPtr buffer = IntPtr.Zero;
        bool ok = false;
        try
        {
            DOC_INFO_1 di = new DOC_INFO_1();
            di.pDocName = docName;
            di.pOutputFile = null;
            di.pDatatype = "RAW";
            if (StartDocPrinter(h, 1, di) == 0) throw Fail("StartDocPrinter");
            docStarted = true;
            if (!StartPagePrinter(h)) throw Fail("StartPagePrinter");
            pageStarted = true;
            buffer = Marshal.AllocHGlobal(data.Length > 0 ? data.Length : 1);
            Marshal.Copy(data, 0, buffer, data.Length);
            int offset = 0;
            while (offset < data.Length)
            {
                int written;
                if (!WritePrinter(h, IntPtr.Add(buffer, offset), data.Length - offset, out written)) throw Fail("WritePrinter");
                if (written <= 0) throw new Win32Exception(0, "WritePrinter wrote 0 bytes");
                offset += written;
            }
            if (!EndPagePrinter(h)) throw Fail("EndPagePrinter");
            pageStarted = false;
            if (!EndDocPrinter(h)) throw Fail("EndDocPrinter");
            docStarted = false;
            ok = true;
        }
        finally
        {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            // On any failure the partial job is deleted, never closed normally (it would print).
            if (!ok && docStarted) AbortPrinter(h);
            ClosePrinter(h);
        }
    }
}
'@

# ---- Logging ----
$script:logDay = ''
function Write-BridgeLog([string]$Line) {
    try {
        $now = Get-Date
        $day = $now.ToString('yyyyMMdd')
        if (-not (Test-Path -LiteralPath $LogDir)) { $null = New-Item -ItemType Directory -Path $LogDir -Force }
        if ($script:logDay -ne $day) {
            $script:logDay = $day
            Get-ChildItem -LiteralPath $LogDir -Filter 'print-bridge-*.log' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $now.AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        [IO.File]::AppendAllText((Join-Path $LogDir "print-bridge-$day.log"), ($now.ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $Line + "`r`n"))
    } catch { }
}

function Clean-Text([string]$Text, [int]$Max) {
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace '[\x00-\x1F\x7F]', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

function Test-Token([string]$Given) {
    if ([string]::IsNullOrEmpty($Given)) { return $false }
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Given))
    $diff = 0
    for ($i = 0; $i -lt $h.Length; $i++) { $diff = $diff -bor ($h[$i] -bxor $tokenHash[$i]) }
    return ($diff -eq 0)
}

function Send-Json($Context, [int]$Status, [hashtable]$Body) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
        $r = $Context.Response
        $r.StatusCode = $Status
        if ($Status -ge 400) { $r.KeepAlive = $false }   # Connection: close; the body may not have been read
        $r.ContentType = 'application/json; charset=utf-8'
        $r.ContentLength64 = $bytes.Length
        $r.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch { } finally {
        try { $Context.Response.Close() } catch { }
    }
}

function Get-SpoolerStatus {
    try {
        $p = Get-Printer -Name $Printer -ErrorAction Stop
        return @{ ok = $true; found = $true; status = [string]$p.PrinterStatus }
    } catch {
        return @{ ok = $false; found = $false; status = "queue '$Printer' not found" }
    }
}

# ---- Listener ----
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://${ListenAddress}:$Port/")
try {
    $listener.TimeoutManager.EntityBody = [TimeSpan]::FromSeconds(30)
    $listener.TimeoutManager.HeaderWait = [TimeSpan]::FromSeconds(15)
    $listener.TimeoutManager.IdleConnection = [TimeSpan]::FromSeconds(60)
    $listener.TimeoutManager.MinSendBytesPerSecond = 150
} catch { }
try {
    $listener.Start()
} catch {
    Stop-Bridge "Could not listen on ${ListenAddress}:$Port ($($_.Exception.Message)). Run elevated, and check that the port is free."
}
Write-BridgeLog "start listen=${ListenAddress}:$Port printer='$Printer'"

try {
    while ($listener.IsListening) {
        # One request at a time: jobs are serialized. Wake every 15 s to notice a changed WSL address.
        $pending = $listener.GetContextAsync()
        while ($true) {
            $done = $true
            try { $done = $pending.Wait(15000) } catch { }
            if ($done) { break }
            if (-not $listener.IsListening) { break }
            if ($autoAddress) {
                $now = Get-WslAddress
                if ($now -and $now -ne $ListenAddress) {
                    Write-BridgeLog "address changed $ListenAddress -> $now, exiting so the task restarts the bridge"
                    exit 1
                }
            }
        }
        if (-not $listener.IsListening) { break }
        try { $ctx = $pending.Result } catch {
            Write-BridgeLog ('accept failed: ' + (Clean-Text $_.Exception.Message 200))
            if (-not $listener.IsListening) { break }
            Start-Sleep -Milliseconds 200
            continue
        }
        $req = $ctx.Request
        $remote = "$($req.RemoteEndPoint.Address)"
        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod
        $queue = Clean-Text $req.Headers['X-Printer'] 200
        $doc = Clean-Text $req.Headers['X-Doc-Name'] 127
        $status = 500; $bytesIn = 0; $note = ''
        try {
            if ($path -ne '/print/raw' -and $path -ne '/health') {
                $status = 404; $note = 'not found'
                Send-Json $ctx $status @{ success = $false; error = 'Not found' }
            } elseif (($path -eq '/print/raw' -and $method -ne 'POST') -or ($path -eq '/health' -and $method -ne 'GET')) {
                $status = 405; $note = 'method not allowed'
                Send-Json $ctx $status @{ success = $false; error = 'Method not allowed' }
            } elseif (-not (Test-Token $req.Headers['X-Print-Token'])) {
                $status = 401; $note = 'bad token'
                Send-Json $ctx $status @{ success = $false; error = 'Unauthorized' }
            } elseif ($path -eq '/health') {
                $s = Get-SpoolerStatus
                if ($s.ok) { $status = 200; Send-Json $ctx $status @{ success = $true; printer = $Printer; printer_found = $true; status = $s.status } }
                else { $status = 503; $note = $s.status; Send-Json $ctx $status @{ success = $false; printer = $Printer; printer_found = $false; error = $s.status } }
            } elseif (-not [string]::Equals($queue, $Printer, [StringComparison]::OrdinalIgnoreCase)) {
                $status = 403; $note = 'queue not allowed'
                Send-Json $ctx $status @{ success = $false; error = 'This bridge does not print to that queue' }
            } elseif ($req.ContentLength64 -gt $MaxBody) {
                $status = 413; $note = 'too large'
                Send-Json $ctx $status @{ success = $false; error = 'Body larger than 2 MB' }
            } else {
                # Read at most 2 MB + 1 byte (also covers chunked bodies with no Content-Length).
                $ms = New-Object IO.MemoryStream
                $buf = New-Object byte[] 65536
                $tooBig = $false
                $in = $req.InputStream
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $ms.Write($buf, 0, $n)
                    if ($ms.Length -gt $MaxBody) { $tooBig = $true; break }
                }
                $bytesIn = $ms.Length
                if (-not $tooBig -and $req.ContentLength64 -ge 0 -and $ms.Length -ne $req.ContentLength64) {
                    $status = 400; $note = 'length mismatch'
                    Send-Json $ctx $status @{ success = $false; error = 'Body length does not match Content-Length' }
                } elseif ($tooBig) {
                    $status = 413; $note = 'too large'
                    Send-Json $ctx $status @{ success = $false; error = 'Body larger than 2 MB' }
                } elseif ($ms.Length -eq 0) {
                    $status = 400; $note = 'empty body'
                    Send-Json $ctx $status @{ success = $false; error = 'Empty body' }
                } else {
                    $name = if ($doc) { "Warehouse $doc" } else { 'Warehouse document' }
                    try {
                        [WarehouseRawPrinter]::SendRaw($Printer, $name, $ms.ToArray())
                        $status = 200; $note = 'ok'
                        Send-Json $ctx $status @{ success = $true }
                    } catch {
                        $status = 502; $note = Clean-Text $_.Exception.Message 200
                        Send-Json $ctx $status @{ success = $false; error = "Spooler: $note" }
                    }
                }
            }
        } catch {
            $status = 500; $note = Clean-Text $_.Exception.Message 200
            Send-Json $ctx 500 @{ success = $false; error = 'Internal error' }
        }
        Write-BridgeLog "$remote $method $path $status bytes=$bytesIn queue='$queue' doc='$doc' $note"
    }
} finally {
    $listener.Close()
    Write-BridgeLog 'stop'
}
