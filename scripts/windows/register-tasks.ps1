<#
.SYNOPSIS
Registers the scheduled tasks a Windows (WSL2) warehouse host needs: "Warehouse WSL" (keep the distro running) and,
optionally, "Warehouse USB" (attach the backup drive again after every restart).

.DESCRIPTION
Run from an elevated Windows PowerShell 5.1 or later. It asks once for the password of the Windows account that owns the
distro (Get-Credential) and registers both tasks with it. The password is never accepted as a parameter, never written to
disk and never printed. Nothing is changed until every check has passed.

"Warehouse WSL": at boot and every 2 minutes, forever, runs "wsl.exe -d <Distro> --exec /usr/bin/sleep infinity" as that
account whether or not anyone is signed in; new instances are ignored while one runs; no time limit; runs on battery.

"Warehouse USB" (only with -BusId): the same triggers and settings, running
"usbipd attach --wsl <Distro> --busid <BusId> --auto-attach --unplugged". Run "usbipd bind --busid <BusId>" first.

.PARAMETER Distro
Name of the WSL distro that holds the installation. Default: Ubuntu-24.04.

.PARAMETER BusId
USB bus id of the backup drive, as "usbipd list" shows it (for example 2-4). When given, "Warehouse USB" is registered too.

.PARAMETER Force
Replace tasks that already exist. Without it the script refuses when a task it would register exists.

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
    [switch]$UsbOnly
)

$ErrorActionPreference = 'Stop'

$KeepAliveName = 'Warehouse WSL'
$UsbName = 'Warehouse USB'
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

$names = @()
if (-not $UsbOnly) { $names += $KeepAliveName }
if ($BusId) { $names += $UsbName }
if (-not $Force) {
    foreach ($n in $names) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            Stop-Script "The task '$n' already exists. Run again with -Force to replace it."
        }
    }
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

function Register-WarehouseTask([string]$Name, $Action, $Settings) {
    $parameters = @{
        TaskName = $Name
        Action   = $Action
        Trigger  = New-RepeatingTriggers
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
