<#
.SYNOPSIS
    Shutdown sync: stop MySQL, sync data to SSD, detach VHD, dismount RAM disk.
.DESCRIPTION
    MUST be run before shutting down or restarting the system.
    Otherwise, all database changes since the last 15-minute sync are LOST.
    WARNING: Data lives on RAM disk — it vanishes when power is lost.
    Must be run as Administrator. Run manually before shutdown/restart.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# === Configuration ===
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackupDir = "$RepoRoot\mysql-data-backup"
$ImDiskExe = (Get-Command imdisk.exe -ErrorAction SilentlyContinue).Source
if (-not $ImDiskExe) { $ImDiskExe = "${env:ProgramFiles}\ImDisk\imdisk.exe" }
$DiskPartScript = "$env:TEMP\ramdisk-shutdown-diskpart.txt"

$VhdFilePath = "R:\mysql-data.vhd"
$ServiceName = "MySQL80"

Write-Host ""
Write-Host "========== MySQL RAM Disk Shutdown Sync ==========" -ForegroundColor Cyan
Write-Host "WARNING: This will stop MySQL and dismount the RAM disk." -ForegroundColor Yellow
Write-Host "         Make sure mangosd and realmd are already stopped!" -ForegroundColor Yellow
Write-Host ""

# --- Step 1: Verify game servers are stopped ---
Write-Host "[1/5] Checking game servers are stopped..." -ForegroundColor Cyan
$mangosProcesses = Get-Process -Name "mangosd", "realmd" -ErrorAction SilentlyContinue
if ($mangosProcesses) {
    Write-Host "  WARNING: Game servers still running!" -ForegroundColor Red
    Write-Host "  Running processes: $($mangosProcesses.Name -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Stop mangosd first (Ctrl+C in its terminal), then realmd (Ctrl+C)." -ForegroundColor Yellow
    Write-Host "  Then re-run this script." -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-Host "  Force continue anyway? (type YES to proceed)"
    if ($continue -ne "YES") {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "  Forcing shutdown despite running game servers..." -ForegroundColor Red
} else {
    Write-Host "  Game servers: stopped" -ForegroundColor Green
}

# --- Step 2: Stop MySQL ---
Write-Host "[2/5] Stopping MySQL service..." -ForegroundColor Cyan
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Stop-Service -Name $ServiceName -Force
    Write-Host "  MySQL stopped." -ForegroundColor Green
} elseif ($svc -and $svc.Status -eq 'Stopped') {
    Write-Host "  MySQL already stopped." -ForegroundColor Yellow
} else {
    Write-Host "  MySQL service not found — continuing." -ForegroundColor Yellow
}

# Brief pause to let MySQL fully flush
Start-Sleep -Seconds 3

# --- Step 3: Final full sync S: -> SSD ---
Write-Host "[3/5] Final sync: S:\ (VHD/RAM) -> SSD backup..." -ForegroundColor Cyan

if (-not (Test-Path "S:\")) {
    Write-Host "  WARNING: S: drive not found. Skipping sync." -ForegroundColor Yellow
} else {
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }

    Write-Host "  Syncing S:\ -> $BackupDir" -ForegroundColor Gray
    $robocopyArgs = @(
        "S:\",
        $BackupDir,
        "/MIR",           # Mirror (copies everything to ensure completeness)
        "/R:3",           # Retry 3 times
        "/W:5",           # Wait 5 seconds
        "/NP",            # No progress
        "/NDL",           # No directory list
        "/XD", "tmp"      # Exclude temp directories
    )
    $robocopyResult = & robocopy @robocopyArgs
    $robocopyExit = $LASTEXITCODE

    if ($robocopyExit -ge 8) {
        Write-Host "  ERROR: robocopy failed with exit code $robocopyExit" -ForegroundColor Red
        Write-Host "  $($robocopyResult -join "`n  ")" -ForegroundColor Gray
        Write-Host "  DO NOT SHUT DOWN until this is resolved!" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Final sync complete (robocopy exit: $robocopyExit)." -ForegroundColor Green
}

# --- Step 4: Detach VHD from S: ---
Write-Host "[4/5] Detaching VHD from S:..." -ForegroundColor Cyan

if (Test-Path "S:\") {
    # Build diskpart detach script
    @"
select vdisk file="$VhdFilePath"
detach vdisk
"@ | Set-Content -Path $DiskPartScript -Encoding ASCII

    $diskpartOutput = & diskpart /s $DiskPartScript 2>&1
    $diskpartExit = $LASTEXITCODE
    Remove-Item $DiskPartScript -Force -ErrorAction SilentlyContinue

    # Exit 0 = success. Non-zero is OK if VHD already detached
    # (e.g. after a prior failed shutdown attempt).
    if ($diskpartExit -ne 0) {
        if ($diskpartOutput -match "已经分离|already detached|already been detached") {
            Write-Host "  VHD already detached." -ForegroundColor Green
        } else {
            Write-Host "  WARNING: diskpart detach exit code: $diskpartExit" -ForegroundColor Yellow
            Write-Host "  $($diskpartOutput -join "`n  ")" -ForegroundColor Gray
        }
    } else {
        Write-Host "  VHD detached from S:" -ForegroundColor Green
    }
} else {
    Write-Host "  S: already dismounted — skipping VHD detach." -ForegroundColor Yellow
}

# --- Step 5: Dismount RAM disk ---
Write-Host "[5/5] Dismounting RAM disk (R:)..." -ForegroundColor Cyan

if (Test-Path "R:\") {
    if (Test-Path $ImDiskExe) {
        # Use -D (force) instead of -d because the VHD file on R: may
        # still have a lingering handle from diskpart even after detach.
        & $ImDiskExe -D -m R: 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  RAM disk R: dismounted." -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Failed to dismount R: (imdisk exit: $LASTEXITCODE)" -ForegroundColor Yellow
            Write-Host "  You may need to dismount manually: imdisk -D -m R:" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ImDisk not found — cannot cleanly dismount R:" -ForegroundColor Yellow
    }
} else {
    Write-Host "  R: already dismounted." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========== Shutdown Sync Complete ==========" -ForegroundColor Green
Write-Host ""
Write-Host "  MySQL:     stopped" -ForegroundColor Gray
Write-Host "  Data:      synced to $BackupDir" -ForegroundColor Gray
Write-Host "  VHD:       detached" -ForegroundColor Gray
Write-Host "  RAM disk:  dismounted" -ForegroundColor Gray
Write-Host ""
Write-Host "It is now safe to restart or shut down." -ForegroundColor Cyan
Write-Host ""
Write-Host "Next boot:  3-start-ramdisk.ps1 runs automatically (via Task Scheduler)" -ForegroundColor Gray
Write-Host "            Or run it manually:  3-start-ramdisk.ps1  as Administrator" -ForegroundColor Gray
