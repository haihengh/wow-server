<#
.SYNOPSIS
    Register Task Scheduler jobs for RAM disk automation.
.DESCRIPTION
    Creates two scheduled tasks:
      1. "WoW Server - RAM Disk Start" — runs 3-start-ramdisk.ps1 on system boot
      2. "WoW Server - RAM Disk Sync"  — runs sync-to-disk.ps1 every 15 minutes
    Must be run as Administrator. Run once during initial setup.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ScriptDir = "$RepoRoot\ramdisk"
$StartScript = "$ScriptDir\3-start-ramdisk.ps1"
$SyncScript  = "$ScriptDir\sync-to-disk.ps1"

$TaskStartName = "WoW Server - RAM Disk Start"
$TaskSyncName  = "WoW Server - RAM Disk Sync"

Write-Host "=== Task Scheduler Setup ===" -ForegroundColor Cyan
Write-Host "  Scripts dir: $ScriptDir" -ForegroundColor Gray
Write-Host ""

# --- Verify scripts exist ---
if (-not (Test-Path $StartScript)) {
    Write-Host "ERROR: Start script not found: $StartScript" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $SyncScript)) {
    Write-Host "ERROR: Sync script not found: $SyncScript" -ForegroundColor Red
    exit 1
}

# PowerShell action arguments for Task Scheduler
$psExe = "PowerShell.exe"
$startArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartScript`""
$syncArgs  = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SyncScript`""

# --- Remove existing tasks if present ---
$existingStart = Get-ScheduledTask -TaskName $TaskStartName -ErrorAction SilentlyContinue
if ($existingStart) {
    Write-Host "Removing existing task: $TaskStartName" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskStartName -Confirm:$false
}

$existingSync = Get-ScheduledTask -TaskName $TaskSyncName -ErrorAction SilentlyContinue
if ($existingSync) {
    Write-Host "Removing existing task: $TaskSyncName" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskSyncName -Confirm:$false
}

# --- Task 1: Boot-time RAM disk start ---
Write-Host "[1/2] Creating boot-time task: $TaskStartName" -ForegroundColor Cyan

$startAction = New-ScheduledTaskAction -Execute $psExe -Argument $startArgs

$startTrigger = New-ScheduledTaskTrigger -AtStartup

$startPrincipal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$startSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
    -TaskName $TaskStartName `
    -Action $startAction `
    -Trigger $startTrigger `
    -Principal $startPrincipal `
    -Settings $startSettings `
    -Description "Creates RAM disk (R:), VHD (S:), restores MySQL data, and starts MySQL80. Runs at system boot." `
    -Force | Out-Null

Write-Host "  Boot task registered." -ForegroundColor Green

# --- Task 2: Periodic sync (every 15 minutes) ---
Write-Host "[2/2] Creating sync task: $TaskSyncName (every 15 min)" -ForegroundColor Cyan

$syncAction = New-ScheduledTaskAction -Execute $psExe -Argument $syncArgs

$syncTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) `
    -RepetitionDuration ([TimeSpan]::FromDays(3650))

$syncPrincipal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$syncSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskSyncName `
    -Action $syncAction `
    -Trigger $syncTrigger `
    -Principal $syncPrincipal `
    -Settings $syncSettings `
    -Description "Incremental sync of MySQL data from RAM disk (S:) to SSD backup. Runs every 15 minutes." `
    -Force | Out-Null

Write-Host "  Sync task registered." -ForegroundColor Green

Write-Host ""
Write-Host "=== Task Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Scheduled tasks:" -ForegroundColor White
Write-Host "  '$TaskStartName'" -ForegroundColor Gray
Write-Host "    Trigger: At system startup" -ForegroundColor DarkGray
Write-Host "    Action:  3-start-ramdisk.ps1" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  '$TaskSyncName'" -ForegroundColor Gray
Write-Host "    Trigger: Every 15 minutes" -ForegroundColor DarkGray
Write-Host "    Action:  sync-to-disk.ps1" -ForegroundColor DarkGray
Write-Host ""
Write-Host "IMPORTANT: These tasks run as SYSTEM. When your password changes," -ForegroundColor Yellow
Write-Host "re-run this script to update the credentials." -ForegroundColor Yellow
Write-Host ""
Write-Host "You can view tasks in: taskschd.msc" -ForegroundColor Gray
