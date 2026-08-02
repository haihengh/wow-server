<#
.SYNOPSIS
    Prepare MySQL for RAM disk operation.
.DESCRIPTION
    1. Stops MySQL
    2. Backs up all MySQL data to local SSD backup directory
    3. Updates my.ini datadir to point at S:\
    4. Sets MySQL service to Manual start (we control it via scripts)
    Must be run as Administrator. Run once during initial setup.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# === Configuration ===
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackupDir = "$RepoRoot\mysql-data-backup"
$MySQLConfigPath = "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini"
$MySQLConfigBackup = "C:\ProgramData\MySQL\MySQL Server 8.0\my.ini.backup"
$MySQLDataOriginal = "C:\ProgramData\MySQL\MySQL Server 8.0\Data"
$ServiceName = "MySQL80"

Write-Host "=== MySQL RAM Disk Preparation ===" -ForegroundColor Cyan
Write-Host "  Backup dir: $BackupDir" -ForegroundColor Gray
Write-Host "  MySQL config: $MySQLConfigPath" -ForegroundColor Gray
Write-Host "  MySQL datadir: $MySQLDataOriginal" -ForegroundColor Gray
Write-Host ""

# --- Step 1: Stop MySQL ---
Write-Host "[1/4] Stopping MySQL service..." -ForegroundColor Cyan
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName -Force
    Write-Host "  MySQL stopped." -ForegroundColor Green
} elseif ($svc -and $svc.Status -eq 'Stopped') {
    Write-Host "  MySQL already stopped." -ForegroundColor Yellow
} else {
    Write-Host "  WARNING: Service '$ServiceName' not found." -ForegroundColor Yellow
    Write-Host "  If your MySQL service has a different name, update `$ServiceName in this script." -ForegroundColor Yellow
}

# --- Step 2: Backup MySQL data ---
Write-Host "[2/4] Backing up MySQL data to SSD..." -ForegroundColor Cyan
if (-not (Test-Path $MySQLDataOriginal)) {
    Write-Host "  ERROR: MySQL data directory not found: $MySQLDataOriginal" -ForegroundColor Red
    Write-Host "  Update `$MySQLDataOriginal in this script if your MySQL data is elsewhere." -ForegroundColor Red
    exit 1
}

# Create backup directory
if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

# Robocopy with retry for locked files
Write-Host "  Copying: $MySQLDataOriginal -> $BackupDir" -ForegroundColor Gray
$robocopyArgs = @(
    $MySQLDataOriginal,
    $BackupDir,
    "/MIR",           # Mirror directory tree
    "/R:3",           # Retry 3 times
    "/W:5",           # Wait 5 seconds between retries
    "/NP",            # No progress (cleaner output)
    "/NDL",           # No directory list
    "/XD", "tmp",     # Exclude temp directories
    "/XF", "*.tmp", "*.log"  # Exclude temp/log files
)
$robocopyResult = & robocopy @robocopyArgs
$robocopyExitCode = $LASTEXITCODE
# Robocopy exit codes: 0-7 are non-error (0=no changes, 1=files copied, 2=extra files, etc.)
if ($robocopyExitCode -ge 8) {
    Write-Host "  ERROR: robocopy failed with exit code $robocopyExitCode" -ForegroundColor Red
    Write-Host "  $($robocopyResult -join "`n")" -ForegroundColor Gray
    exit 1
}
Write-Host "  Backup complete (robocopy exit: $robocopyExitCode)." -ForegroundColor Green

# --- Step 3: Update MySQL config ---
Write-Host "[3/4] Updating MySQL config (datadir -> S:\)..." -ForegroundColor Cyan

if (-not (Test-Path $MySQLConfigPath)) {
    Write-Host "  ERROR: MySQL config not found: $MySQLConfigPath" -ForegroundColor Red
    exit 1
}

# Always keep a clean backup of the original config
if (-not (Test-Path $MySQLConfigBackup)) {
    Copy-Item $MySQLConfigPath $MySQLConfigBackup -Force
    Write-Host "  Original config backed up to: $MySQLConfigBackup" -ForegroundColor Green
} else {
    Write-Host "  Backup already exists: $MySQLConfigBackup" -ForegroundColor Yellow
    Write-Host "  Skipping backup (protecting original)." -ForegroundColor Yellow
}

# Read current config
$configContent = Get-Content $MySQLConfigPath -Raw
$configEncoding = if ([System.IO.File]::ReadAllText($MySQLConfigPath) -match "[^\x00-\x7F]") { "UTF8" } else { "ASCII" }

# Check if datadir already points to S:\
if ($configContent -match "datadir\s*=\s*S:\\\\?") {
    Write-Host "  datadir already points to S:\ — skipping config update." -ForegroundColor Yellow
} else {
    # Replace datadir path
    $newConfig = $configContent -replace 'datadir\s*=\s*.*', "datadir=S:\\"
    [System.IO.File]::WriteAllText($MySQLConfigPath, $newConfig)
    Write-Host "  datadir updated: -> S:\" -ForegroundColor Green
}

# --- Step 4: Set MySQL to Manual start ---
Write-Host "[4/4] Setting MySQL service to Manual start..." -ForegroundColor Cyan
$currentStartType = (Get-Service -Name $ServiceName).StartType
if ($currentStartType -ne 'Manual') {
    Set-Service -Name $ServiceName -StartupType Manual
    Write-Host "  MySQL startup changed: $currentStartType -> Manual" -ForegroundColor Green
} else {
    Write-Host "  MySQL already set to Manual." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Preparation Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "What was done:" -ForegroundColor White
Write-Host "  1. MySQL service stopped" -ForegroundColor Gray
Write-Host "  2. MySQL data backed up to: $BackupDir" -ForegroundColor Gray
Write-Host "  3. MySQL config updated: datadir=S:\" -ForegroundColor Gray
Write-Host "  4. MySQL startup type set to Manual" -ForegroundColor Gray
Write-Host ""
Write-Host "Next step: Run  3-start-ramdisk.ps1  as Administrator" -ForegroundColor Cyan
