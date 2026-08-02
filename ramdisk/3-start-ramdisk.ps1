<#
.SYNOPSIS
    Start MySQL on RAM disk.
.DESCRIPTION
    Creates a 4 GB RAM disk (R:), creates a VHD on it, attaches as S:,
    restores MySQL data from SSD backup, and starts MySQL.
    Run as Administrator on every boot (or via Task Scheduler).
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# === Configuration ===
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackupDir = "$RepoRoot\mysql-data-backup"
$ImDiskExe = (Get-Command imdisk.exe -ErrorAction SilentlyContinue).Source
if (-not $ImDiskExe) { $ImDiskExe = "${env:ProgramFiles}\ImDisk\imdisk.exe" }
$DiskPartScript = "$env:TEMP\ramdisk-diskpart.txt"

$RamDiskDrive = "R:"
$RamDiskSizeMB = 4096        # 4 GB
$VhdDriveLetter = "S"
$VhdDrive = "${VhdDriveLetter}:"
$VhdFilePath = "$RamDiskDrive\mysql-data.vhd"
$VhdSizeMB = 3072            # 3 GB VHD inside 4 GB RAM disk
$ServiceName = "MySQL80"

Write-Host "=== MySQL RAM Disk Startup ===" -ForegroundColor Cyan
Write-Host "  RAM Disk: ${RamDiskDrive} (${RamDiskSizeMB} MB)" -ForegroundColor Gray
Write-Host "  VHD: ${VhdFilePath} (${VhdSizeMB} MB) -> ${VhdDrive}" -ForegroundColor Gray
Write-Host "  Backup: $BackupDir" -ForegroundColor Gray
Write-Host ""

# --- Step 1: Verify ImDisk is installed ---
Write-Host "[1/5] Checking ImDisk driver..." -ForegroundColor Cyan
if (-not (Test-Path $ImDiskExe)) {
    Write-Host "  ERROR: ImDisk not found at $ImDiskExe" -ForegroundColor Red
    Write-Host "  Run 1-install-driver.ps1 first." -ForegroundColor Red
    exit 1
}

# Load ImDisk driver if needed
$imdiskCheck = & $ImDiskExe -l 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ImDisk driver not loaded. Attempting to start..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath "sc" -ArgumentList "start imdisk" -Wait -NoNewWindow
        Start-Sleep -Seconds 2
        & $ImDiskExe -l 2>&1 | Out-Null
        Write-Host "  Driver started." -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: Could not start ImDisk driver. Try rebooting." -ForegroundColor Red
        exit 1
    }
}
Write-Host "  ImDisk: ready" -ForegroundColor Green

# --- Step 2: Create RAM disk ---
Write-Host "[2/5] Creating ${RamDiskSizeMB} MB RAM disk on ${RamDiskDrive}..." -ForegroundColor Cyan

$ramDiskExists = Test-Path $RamDiskDrive
if ($ramDiskExists) {
    Write-Host "  ${RamDiskDrive} already exists — skipping creation." -ForegroundColor Yellow
    $ramDiskInfo = & $ImDiskExe -l | Select-String $RamDiskDrive
    if ($ramDiskInfo) { Write-Host "  $($ramDiskInfo.ToString().Trim())" -ForegroundColor Gray }
} else {
    # Create RAM disk, format as NTFS, mount as R:
    & $ImDiskExe -a -s ${RamDiskSizeMB}M -m ${RamDiskDrive} -p "/fs:ntfs /q /y" 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to create RAM disk." -ForegroundColor Red
        exit 1
    }
    Write-Host "  RAM disk created on ${RamDiskDrive}" -ForegroundColor Green
}

# --- Step 3: Create and attach VHD ---
Write-Host "[3/5] Creating VHD (${VhdSizeMB} MB) on ${RamDiskDrive} and mounting as ${VhdDrive}..." -ForegroundColor Cyan

$vhdExists = Test-Path $VhdDrive
if ($vhdExists) {
    Write-Host "  ${VhdDrive} already mounted — skipping VHD creation." -ForegroundColor Yellow
} else {
    # Build diskpart script
    @"
create vdisk file="$VhdFilePath" maximum=$VhdSizeMB type=fixed
select vdisk file="$VhdFilePath"
attach vdisk
create partition primary
format fs=ntfs quick label=MySQL_Data
assign letter=$VhdDriveLetter
"@ | Set-Content -Path $DiskPartScript -Encoding ASCII

    Write-Host "  Running diskpart..." -ForegroundColor Gray
    $diskpartOutput = & diskpart /s $DiskPartScript 2>&1
    $diskpartExit = $LASTEXITCODE

    # Clean up script
    Remove-Item $DiskPartScript -Force -ErrorAction SilentlyContinue

    if ($diskpartExit -ne 0) {
        Write-Host "  diskpart output:" -ForegroundColor Yellow
        Write-Host "  $($diskpartOutput -join "`n  ")" -ForegroundColor Gray
        Write-Host "  ERROR: diskpart exited with code $diskpartExit" -ForegroundColor Red
        exit 1
    }

    # Verify drive appeared
    if (-not (Test-Path $VhdDrive)) {
        Write-Host "  ERROR: VHD drive ${VhdDrive} not found after diskpart." -ForegroundColor Red
        Write-Host "  diskpart output: $($diskpartOutput -join "`n  ")" -ForegroundColor Gray
        exit 1
    }
    Write-Host "  VHD created and mounted at ${VhdDrive}" -ForegroundColor Green
}

# --- Step 4: Restore MySQL data from backup ---
Write-Host "[4/5] Restoring MySQL data from SSD backup..." -ForegroundColor Cyan

if (-not (Test-Path $BackupDir)) {
    Write-Host "  ERROR: Backup directory not found: $BackupDir" -ForegroundColor Red
    Write-Host "  Run 2-prepare-backup.ps1 first." -ForegroundColor Red
    exit 1
}

# Check if backup has data
$backupHasData = (Get-ChildItem $BackupDir -ErrorAction SilentlyContinue | Measure-Object).Count
if ($backupHasData -eq 0) {
    Write-Host "  WARNING: Backup directory is empty!" -ForegroundColor Yellow
    Write-Host "  MySQL will start but databases will need to be initialized." -ForegroundColor Yellow
}

# Restore — copy all files from backup to VHD
Write-Host "  Copying: $BackupDir -> ${VhdDrive}\" -ForegroundColor Gray
$robocopyArgs = @(
    $BackupDir,
    $VhdDrive,
    "/MIR",           # Mirror directory tree (restores backup state)
    "/R:3",           # Retry 3 times
    "/W:5",           # Wait 5 seconds between retries
    "/NP",            # No progress
    "/NDL",           # No directory list
    "/XD", "tmp"      # Exclude temp directories
)
$robocopyResult = & robocopy @robocopyArgs
$robocopyExitCode = $LASTEXITCODE
if ($robocopyExitCode -ge 8) {
    Write-Host "  ERROR: robocopy failed with exit code $robocopyExitCode" -ForegroundColor Red
    exit 1
}
Write-Host "  Restore complete (robocopy exit: $robocopyExitCode)." -ForegroundColor Green

# --- Step 5: Start MySQL ---
Write-Host "[5/5] Starting MySQL service..." -ForegroundColor Cyan

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "  ERROR: Service '$ServiceName' not found." -ForegroundColor Red
    Write-Host "  If your MySQL service has a different name, update `$ServiceName in this script." -ForegroundColor Red
    exit 1
}

if ($svc.Status -eq 'Running') {
    Write-Host "  MySQL already running." -ForegroundColor Yellow
} else {
    try {
        Start-Service -Name $ServiceName
        Write-Host "  MySQL started." -ForegroundColor Green
    } catch {
        Write-Host "  ERROR: Failed to start MySQL: $_" -ForegroundColor Red
        Write-Host "  Check MySQL error log at: ${VhdDrive}\*.err" -ForegroundColor Yellow
        exit 1
    }
}

# Verify datadir
Write-Host ""
Write-Host "=== RAM Disk Startup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "  RAM Disk:  ${RamDiskDrive} ($([math]::Round((Get-PSDrive $RamDiskDrive[0]).Free / 1MB, 0)) MB free)" -ForegroundColor Gray
Write-Host "  VHD:       ${VhdDrive} ($([math]::Round((Get-PSDrive $VhdDriveLetter).Free / 1MB, 0)) MB free)" -ForegroundColor Gray
Write-Host "  MySQL:     Running (datadir=${VhdDrive}\)" -ForegroundColor Gray
Write-Host ""
Write-Host "Verify:  Test-Path S:\ibdata1  ->  $(Test-Path ${VhdDrive}\ibdata1)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: Run 4-setup-tasks.ps1 to automate boot-time startup." -ForegroundColor Cyan
