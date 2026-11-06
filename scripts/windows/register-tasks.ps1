<#
.SYNOPSIS
Registers the scheduled tasks a Windows (WSL2) warehouse host needs: "Warehouse WSL" (keep the distro running) and,
optionally, "Warehouse USB" (attach the backup drive again after every restart) and "Warehouse Print" (the print bridge for the LQ-1310).

.DESCRIPTION
Run from an elevated Windows PowerShell 5.1 or later. It asks once for the password of the Windows account that owns the
distro (Get-Credential) and registers both tasks with it. The password is never accepted as a parameter, never written to
disk and never printed. Nothing is changed until every check has passed.

"Warehouse WSL": at boot and every 2 minutes, forever, runs "wsl.exe -d <Distro> --exec /usr/bin/sleep infinity" as that
account whether or not anyone is signed in; new instances are ignored while one runs; no time limit; runs on battery.

"Warehouse USB" (only with -BusId): the same triggers and settings, running
"usbipd attach --wsl <Distro> --busid <BusId> --auto-attach --unplugged". Run "usbipd bind --busid <BusId>" first.

Best effort, with -Checkout and -State: "Warehouse WSL stop" runs when Windows starts a shutdown or restart (System log event 1074, source
User32) and stops the stack cleanly: "wsl.exe -d <Distro> -- env WAREHOUSE_STATE_DIR=<State> bash <Checkout>/stop.sh --on-host-shutdown", with a 90 second
limit. Windows may kill WSL before it finishes; PostgreSQL then recovers its log on the next start, as without the task. It does not hold the
stack down after the restart (stop.sh --on-host-shutdown leaves no stopped-by-operator file). It is not started when it is registered.

.PARAMETER Distro
Name of the WSL distro that holds the installation. Default: Ubuntu-24.04.

.PARAMETER BusId
USB bus id of the backup drive, as "usbipd list" shows it (for example 2-4). When given, "Warehouse USB" is registered too.

.PARAMETER Force
Replace tasks that already exist. Without it the script refuses when a task it would register exists.

.PARAMETER Printer
Name of the local Windows print queue for the LQ-1310 (any driver; the bridge sends RAW and bypasses it), as "Get-Printer" shows it.
When given, "Warehouse Print" is registered: it runs print-bridge.ps1 (next to this script) at boot and every 2 minutes (a second
copy is ignored), as the same account as the other tasks. The script also creates the token file, adds the firewall rule and
shows the read-back. See print-bridge.ps1 for the protocol and for how to test without paper.

.PARAMETER PrintPort
TCP port of the bridge. Default 6632. The firewall rule "Warehouse Print" allows inbound TCP on this port from the WSL side only
(the "vEthernet (WSL)" interface; when that adapter does not exist yet, the WSL address range 172.16.0.0/12).

.PARAMETER PrintOnly
Register only "Warehouse Print" (with -Printer). Same idea as -UsbOnly.

.PARAMETER SetTokenFromWsl
Distro name. Copies PRINTBRIDGE_TOKEN from the instance into the token file (%ProgramData%\Warehouse\print-bridge.token) by running
"wsl.exe -d <distro> -- sed -n s/^PRINTBRIDGE_TOKEN=//p <ComposeEnv>". The token is generated once by the instance's configure step
and lives in its compose.env (mode 0600); this is the one place it is created, so the Windows side follows it and the two cannot
drift. The token appears only in this script's memory: not on any command line, not on the screen, not in a log. Needs -ComposeEnv.
Without this switch the script creates a random token only when the file does not exist, and then the operator must put the same
value into the instance (Get-Content the file in an elevated shell, paste it as PRINTBRIDGE_TOKEN in compose.env, restart the
instance); that is the fallback, -SetTokenFromWsl is the supported way.

.PARAMETER ComposeEnv
Absolute Linux path of the instance's compose.env inside the distro (<state dir>/config/compose.env). Used by -SetTokenFromWsl.

.PARAMETER UsbOnly
Register only "Warehouse USB" (to add it later, or after the drive moved to another port). Requires -BusId.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-tasks.ps1

Registers the keep-alive task only.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-tasks.ps1 -BusId 2-4

Registers the keep-alive task and the USB task for bus id 2-4.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\register-tasks.ps1 -UsbOnly -BusId 2-5 -Force

Replaces the USB task after the drive moved to bus id 2-5.
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [string]$BusId,
    [switch]$Force,
    [switch]$UsbOnly,
    [string]$Checkout,
    [string]$State,
    [string]$Printer,
    [ValidateRange(1024, 65535)][int]$PrintPort = 6632,
    [switch]$PrintOnly,
    [string]$SetTokenFromWsl,
    [string]$ComposeEnv
)

$ErrorActionPreference = 'Stop'

$KeepAliveName = 'Warehouse WSL'
$UsbName = 'Warehouse USB'
$StopName = 'Warehouse WSL stop'
$PrintName = 'Warehouse Print'
$TokenFile = Join-Path $env:ProgramData 'Warehouse\print-bridge.token'
$BridgeScript = Join-Path $PSScriptRoot 'print-bridge.ps1'
$DefaultUsbipd = 'C:\Program Files\usbipd-win\usbipd.exe'

function Stop-Script([string]$Message) {
    [Console]::Error.WriteLine("register-tasks: $Message")
    exit 1
}

# ---- Checks (nothing is changed before all of them pass) ----

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-Script 'Run this from an elevated PowerShell (Run as administrator).'
}

if ($UsbOnly -and -not $BusId) { Stop-Script '-UsbOnly needs -BusId.' }
if ($PrintOnly -and -not $Printer) { Stop-Script '-PrintOnly needs -Printer.' }
if ($PrintOnly -and ($UsbOnly -or $Checkout)) { Stop-Script '-PrintOnly cannot be combined with -UsbOnly or -Checkout.' }
if ($UsbOnly -and $Printer) { Stop-Script '-UsbOnly cannot be combined with -Printer.' }
if (($SetTokenFromWsl -or $ComposeEnv) -and -not $Printer) { Stop-Script '-SetTokenFromWsl and -ComposeEnv need -Printer.' }
if ($Printer) {
    if ($Printer -match '["`$\x00-\x1F]') { Stop-Script "-Printer '$Printer' contains a character this script does not accept (double quote, backtick, dollar sign or control character)." }
    if (-not (Test-Path -LiteralPath $BridgeScript -PathType Leaf)) { Stop-Script "print-bridge.ps1 was not found next to this script ($BridgeScript)." }
    if (-not (Get-Command Get-Printer -ErrorAction SilentlyContinue)) { Stop-Script 'Get-Printer is not available (the PrintManagement module).' }
    if (-not (Get-Printer -Name $Printer -ErrorAction SilentlyContinue)) {
        $have = (@(Get-Printer | ForEach-Object { $_.Name }) -join '; ')
        Stop-Script "No local print queue named '$Printer'. Queues on this PC: $have"
    }
    if ($SetTokenFromWsl) {
        if ($SetTokenFromWsl -notmatch '^[A-Za-z0-9._-]+$') { Stop-Script "-SetTokenFromWsl '$SetTokenFromWsl' is not a distro name." }
        if (-not $ComposeEnv) { Stop-Script '-SetTokenFromWsl needs -ComposeEnv (the Linux path of the instance compose.env).' }
        if ($ComposeEnv -notmatch '^/[A-Za-z0-9._/-]+$') { Stop-Script "-ComposeEnv '$ComposeEnv' is not a plain absolute Linux path (letters, digits, . _ - / only)." }
    } elseif ($ComposeEnv) { Stop-Script '-ComposeEnv goes with -SetTokenFromWsl.' }
}
if ($Distro -notmatch '^[A-Za-z0-9._-]+$') { Stop-Script "-Distro '$Distro' is not a distro name (letters, digits, . _ - only)." }

# wsl.exe -l -q prints UTF-16; strip NULs, carriage returns and a byte order mark whatever the console decoded.
$previousEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [Text.Encoding]::Unicode
    $listing = @(& wsl.exe -l -q)
    $wslExit = $LASTEXITCODE
} catch {
    Stop-Script "wsl.exe could not be run: $($_.Exception.Message)"
} finally {
    [Console]::OutputEncoding = $previousEncoding
}
if ($wslExit -ne 0) { Stop-Script "wsl.exe -l -q failed (exit $wslExit)." }
$distros = @($listing | ForEach-Object { ("$_" -replace "`0", '' -replace "`r", '' -replace [string][char]0xFEFF, '').Trim() } | Where-Object { $_ })
if ($distros -notcontains $Distro) {
    Stop-Script "WSL distro '$Distro' was not found (wsl.exe -l -q lists: $($distros -join ', ')). Pass -Distro with the right name."
}

$usbipd = $null
if ($BusId) {
    if ($BusId -notmatch '^\d+-\d+$') { Stop-Script "-BusId '$BusId' is not a bus id (digits-digits, for example 2-4)." }
    $usbipd = (Get-Command usbipd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $usbipd -and (Test-Path -LiteralPath $DefaultUsbipd)) { $usbipd = $DefaultUsbipd }
    if (-not $usbipd) { Stop-Script 'usbipd was not found. Install usbipd-win, then open a new PowerShell and run this again.' }
    # No 2>&1 here: on Windows PowerShell 5.1 that would turn a stderr line into a terminating error.
    $usbList = @(& $usbipd list)
    if ($LASTEXITCODE -ne 0) { Stop-Script "usbipd list failed (exit $LASTEXITCODE)." }
    $row = @($usbList | Where-Object { $_ -match "^\s*$([regex]::Escape($BusId))\s" }) | Select-Object -First 1
    if (-not $row) { Stop-Script "usbipd list does not show bus id $BusId. Plug the drive in and check the id with 'usbipd list'." }
    if ($row -notmatch '\s{2}(?<st>Not shared|Shared \(forced\)|Shared|Attached|Allowed|Incompatible hub)\s*$') { Stop-Script "Bus id $BusId has a state this script does not know: $($row.Trim())" }
    if ($Matches.st -eq 'Not shared') { Stop-Script "Bus id $BusId is not shared. Run 'usbipd bind --busid $BusId' first." }
    if ($Matches.st -eq 'Allowed') { Stop-Script "Bus id $BusId is only allowed (not bound for sharing). Run 'usbipd bind --busid $BusId' first." }
    if ($Matches.st -eq 'Incompatible hub') { Stop-Script "Bus id $BusId is behind a hub usbipd cannot share. Plug the drive into another port and check 'usbipd list'." }
}

if (($Checkout -and -not $State) -or ($State -and -not $Checkout)) { Stop-Script '-Checkout and -State go together (both are Linux paths inside the distro).' }
foreach ($p in @($Checkout, $State)) {
    if ($p -and $p -notmatch '^/[A-Za-z0-9._/-]+$') { Stop-Script "'$p' is not a plain absolute Linux path (letters, digits, . _ - / only)." }
}
if ($Checkout -and $UsbOnly) { Stop-Script '-UsbOnly cannot be combined with -Checkout.' }

$names = @()
if (-not $UsbOnly -and -not $PrintOnly) { $names += $KeepAliveName }
if ($BusId) { $names += $UsbName }
if ($Checkout) { $names += $StopName }
if ($Printer) { $names += $PrintName }
if (-not $Force) {
    foreach ($n in $names) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Stop-Script "The task '$n' already exists. Run again with -Force to replace it."
        }
    }
    if ($Printer -and (Get-NetFirewallRule -DisplayName $PrintName -ErrorAction SilentlyContinue)) {
        Stop-Script "The firewall rule '$PrintName' already exists. Run again with -Force to replace it."
    }
}

# Read the token from the instance before anything is changed (nothing is printed; only a hex string is accepted).
$newToken = $null
if ($SetTokenFromWsl) {
    $raw = $null
    try {
        $raw = @(& wsl.exe -d $SetTokenFromWsl -- sed -n 's/^PRINTBRIDGE_TOKEN=//p' $ComposeEnv)
        $sedExit = $LASTEXITCODE
    } catch {
        Stop-Script "wsl.exe could not be run: $($_.Exception.Message)"
    }
    if ($sedExit -ne 0) { Stop-Script "Reading $ComposeEnv in distro '$SetTokenFromWsl' failed (exit $sedExit). Check the path." }
    $candidate = (@($raw | ForEach-Object { ("$_" -replace "`0", '' -replace "`r", '').Trim() } | Where-Object { $_ }) | Select-Object -Last 1)
    if (-not $candidate -or $candidate -notmatch '^[0-9a-fA-F]{32,128}$') {
        Stop-Script "No valid PRINTBRIDGE_TOKEN (32 to 128 hex characters) in $ComposeEnv. Run the instance's configure step first (it generates it)."
    }
    $newToken = $candidate
    $candidate = $null; $raw = $null
}

# ---- Credential: asked once, used for both tasks, never stored ----

try {
    $credential = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Windows account that owns the distro (the account running this; type its password)'
} catch {
    Stop-Script 'No credential was given.'
}
if (-not $credential) { Stop-Script 'No credential was given.' }
if (($credential.UserName -split '\\')[-1] -ne $env:USERNAME) { Stop-Script "Run this elevated from the account that owns the distro ($env:USERNAME is running it; the credential names $($credential.UserName))." }

# ---- Registration ----

function New-RepeatingTriggers {
    @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2)))
}

# System log event 1074 (source User32): Windows is about to shut down or restart, for an update or by request.
function New-ShutdownTrigger {
    $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $trigger = New-CimInstance -CimClass $class -ClientOnly
    $trigger.Enabled = $true
    $trigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''User32''] and EventID=1074]]</Select></Query></QueryList>'
    $trigger
}

function Register-WarehouseTask([string]$Name, $Action, $Settings, $Trigger = $null, [switch]$NoStart) {
    if (-not $Trigger) { $Trigger = New-RepeatingTriggers }
    $parameters = @{
        TaskName = $Name
        Action   = $Action
        Trigger  = $Trigger
        Settings = $Settings
        User     = $credential.UserName
        Password = $credential.GetNetworkCredential().Password
        RunLevel = 'Highest'
    }
    if ($Force) { $parameters.Force = $true }
    try {
        $null = Register-ScheduledTask @parameters
    } catch {
        $other = if ($Name -eq $KeepAliveName) { $UsbName } else { $KeepAliveName }
        Stop-Script "Registering '$Name' failed: $($_.Exception.Message) The other task ('$other') may already be registered; check with Get-ScheduledTask 'Warehouse*'."
    } finally {
        $parameters.Password = $null
    }
    if ($NoStart) { return }
    try {
        Start-ScheduledTask -TaskName $Name
    } catch {
        Stop-Script "Registered '$Name' but could not start it: $($_.Exception.Message)"
    }
}

if (-not $UsbOnly) {
    $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wsl.exe' -Argument "-d $Distro --exec /usr/bin/sleep infinity"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-WarehouseTask $KeepAliveName $action $settings
    Write-Host "Registered and started '$KeepAliveName'."
}

if ($BusId) {
    $action = New-ScheduledTaskAction -Execute $usbipd -Argument "attach --wsl $Distro --busid $BusId --auto-attach --unplugged"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-WarehouseTask $UsbName $action $settings
    Write-Host "Registered and started '$UsbName'."
}

if ($Checkout) {
    $stopArguments = "-d $Distro -- env WAREHOUSE_STATE_DIR=$State bash $Checkout/stop.sh --on-host-shutdown"
    $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\wsl.exe' -Argument $stopArguments
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 90) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-WarehouseTask $StopName $action $settings (New-ShutdownTrigger) -NoStart
    Write-Host "Registered '$StopName' (best effort: it runs when Windows starts a shutdown or restart; Windows may kill WSL before it finishes)."
}

if ($Printer) {
    # Token file: created empty with a restricted ACL before any secret is written to it.
    $tokenDir = Split-Path -Parent $TokenFile
    if (-not (Test-Path -LiteralPath $tokenDir)) { $null = New-Item -ItemType Directory -Path $tokenDir -Force }
    $tokenCreated = $false
    if (-not (Test-Path -LiteralPath $TokenFile)) {
        $null = New-Item -ItemType File -Path $TokenFile -Force
        $tokenCreated = $true
    }
    $sid = New-Object Security.Principal.SecurityIdentifier($identity.User.Value)
    $admins = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $system = New-Object Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($who in @($sid, $admins, $system)) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $TokenFile -AclObject $acl
    if ($newToken) {
        [IO.File]::WriteAllText($TokenFile, $newToken + "`n")
        Write-Host "Token file '$TokenFile' set from $ComposeEnv in distro '$SetTokenFromWsl'."
        $newToken = $null
    } elseif ($tokenCreated) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        $rng.Dispose()
        [IO.File]::WriteAllText($TokenFile, (($bytes | ForEach-Object { $_.ToString('x2') }) -join '') + "`n")
        Write-Host "Token file '$TokenFile' created with a random token. Put the same value into the instance as PRINTBRIDGE_TOKEN (see -SetTokenFromWsl)."
    } else {
        Write-Host "Token file '$TokenFile' already exists and was left as it is (its ACL was reset to this account, Administrators and SYSTEM)."
    }
    if ((Get-Item -LiteralPath $TokenFile).Length -eq 0) { Stop-Script "Token file '$TokenFile' is empty." }

    # Firewall: TCP <PrintPort> inbound from the WSL side only.
    $existingRule = Get-NetFirewallRule -DisplayName $PrintName -ErrorAction SilentlyContinue
    if ($existingRule) { $existingRule | Remove-NetFirewallRule }
    $wslAdapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'vEthernet (WSL*' } | Select-Object -First 1
    $rule = @{ DisplayName = $PrintName; Direction = 'Inbound'; Action = 'Allow'; Protocol = 'TCP'; LocalPort = $PrintPort; Profile = 'Any' }
    if ($wslAdapter) { $rule.InterfaceAlias = $wslAdapter.Name } else { $rule.RemoteAddress = '172.16.0.0/12' }
    $null = New-NetFirewallRule @rule
    if ($wslAdapter) { Write-Host "Firewall rule '$PrintName': TCP $PrintPort inbound on interface '$($wslAdapter.Name)'." }
    else { Write-Host "Firewall rule '$PrintName': TCP $PrintPort inbound from 172.16.0.0/12 (the WSL adapter does not exist yet; WSL was not running). Re-run with -Force once WSL runs to tie it to the interface." }

    $bridgeArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$BridgeScript`" -Printer `"$Printer`" -Port $PrintPort -TokenFile `"$TokenFile`""
    $action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument $bridgeArguments
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-WarehouseTask $PrintName $action $settings
    Write-Host "Registered and started '$PrintName'."
}

$credential = $null

# ---- Read-back ----

Start-Sleep -Seconds 3
foreach ($n in $names) {
    $task = Get-ScheduledTask -TaskName $n
    $info = $task | Get-ScheduledTaskInfo
    $s = $task.Settings
    Write-Host ''
    Write-Host "== $n =="
    Write-Host "State:                $($task.State)"
    Write-Host "LastRunTime:          $($info.LastRunTime)"
    Write-Host "LastTaskResult:       $($info.LastTaskResult)"
    foreach ($tr in $task.Triggers) {
        $kind = $tr.CimClass.CimClassName -replace '^MSFT_Task', ''
        $repeat = if ($tr.Repetition -and $tr.Repetition.Interval) { "repeats every $($tr.Repetition.Interval)" } else { 'no repeat' }
        Write-Host "Trigger:              $kind, $repeat, enabled=$($tr.Enabled), duration '$($tr.Repetition.Duration)'"
    }
    Write-Host "MultipleInstances:    $($s.MultipleInstances)"
    Write-Host "DisallowStartIfOnBatteries: $($s.DisallowStartIfOnBatteries)   StopIfGoingOnBatteries: $($s.StopIfGoingOnBatteries)"
    Write-Host "RunLevel:             $($task.Principal.RunLevel)"
    Write-Host "User/LogonType:       $($task.Principal.UserId) / $($task.Principal.LogonType)"
    Write-Host "Restart:              $($s.RestartCount) every $($s.RestartInterval); TimeLimit $($s.ExecutionTimeLimit); StartWhenAvailable $($s.StartWhenAvailable)"
    Write-Host "Action:               $($task.Actions.Execute) $($task.Actions.Arguments)"
}

if ($Checkout) {
    Write-Host ''
    Write-Host "Note: '$StopName' is not started now; its State is Ready until a shutdown or restart runs it."
}

if ($Printer) {
    Write-Host ''
    Write-Host "== $PrintName (extras) =="
    $fw = Get-NetFirewallRule -DisplayName $PrintName -ErrorAction SilentlyContinue
    if ($fw) {
        $pf = $fw | Get-NetFirewallPortFilter
        Write-Host "Firewall rule:        enabled=$($fw.Enabled), $($fw.Direction), $($fw.Action), TCP $($pf.LocalPort), interface: $(($fw | Get-NetFirewallInterfaceFilter).InterfaceAlias)"
    } else { Write-Host 'Firewall rule:        MISSING' }
    Write-Host "Token file:           $TokenFile ($((Get-Item -LiteralPath $TokenFile).Length) bytes)"
    (Get-Acl -LiteralPath $TokenFile).Access | ForEach-Object { Write-Host "  ACL: $($_.IdentityReference) $($_.FileSystemRights) $($_.AccessControlType)" }
    $logs = Join-Path $env:ProgramData 'Warehouse\logs'
    Write-Host "Bridge log:           $logs\print-bridge-<date>.log (the 'start listen=' line shows the address; if the task is Ready with result 1, read the task's last run and start the bridge by hand to see the message)"
    Write-Host 'Windows 11: the Hyper-V firewall (Get-NetFirewallHyperVVMSetting -Name ''{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'') filters traffic INTO the WSL VM, not from WSL to the host, so nothing is changed. If the instance cannot reach the bridge in mirrored networking mode, check it and the Windows firewall profile first.'
    Write-Host "Test with no paper: see print-bridge.ps1 (pause the queue, send, look at Get-PrintJob, remove the job). Nothing was printed."
}

if ($BusId) {
    Write-Host ''
    Write-Host "== usbipd list (bus id $BusId) =="
    & $usbipd list | Where-Object { $_ -match "^\s*$([regex]::Escape($BusId))\s" }
}

Write-Host ''
Write-Host 'Check: each task shows State Running. Ready means it is not running: look at LastTaskResult. An empty trigger duration means the repeat has no end.'
Write-Host 'LastTaskResult 267009 (0x41301) means running now; 2147946720 (0x800710E0) means a start was ignored because one instance already runs; both are expected. 1 on the USB task means usbipd attach failed (for example the distro was down).'
if ($BusId) {
    Write-Host "Check: with the drive plugged in, 'usbipd list' shows bus id $BusId as Attached within 2 minutes once the distro is up."
}
