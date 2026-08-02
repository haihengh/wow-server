<#
.SYNOPSIS
    Incremental sync of MySQL data from RAM disk to SSD.
.DESCRIPTION
    Robocopy incremental sync: copies newer/changed files from S:\ (VHD on RAM)
    to the SSD backup directory. Runs every 15 minutes via Task Scheduler.
    Does NOT stop MySQL — safe for live sync during gameplay.
    Runs as SYSTEM from Task Scheduler — no manual invocation needed.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"   # Don't fail on transient issues

# === Configuration ===
$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackupDir = "$RepoRoot\mysql-data-backup"
$VhdDrive = "S:"
$LogFile = "$RepoRoot\ramdisk\sync-log.txt"
$MaxLogLines = 200

# === Guards ===
# Check S: is mounted
if (-not (Test-Path $VhdDrive)) {
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  SKIP  S: not mounted (RAM disk not started?)"
    Add-Content -Path $LogFile -Value $msg
    exit 0
}

# Verify backup directory exists
if (-not (Test-Path $BackupDir)) {
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  ERROR Backup dir missing: $BackupDir"
    Add-Content -Path $LogFile -Value $msg
    exit 1
}

# === Sync ===
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$robocopyArgs = @(
    $VhdDrive,
    $BackupDir,
    "/MIR",           # Mirror (incremental — only copies newer/changed files)
    "/R:2",           # Retry 2 times
    "/W:3",           # Wait 3 seconds
    "/NP",            # No progress
    "/NDL",           # No directory list
    "/NJH",           # No job header
    "/NJS",           # No job summary
    "/XD", "tmp",     # Exclude temp directories
    "/XF", "*.tmp", "*.log", "*.err"  # Exclude logs (they grow fast)
)

$output = & robocopy @robocopyArgs 2>&1 | Out-String
$robocopyExit = $LASTEXITCODE

# Robocopy exit codes 0-7 are OK (0=no changes, 1+=files copied)
if ($robocopyExit -ge 8) {
    $msg = "$timestamp  ERROR robocopy exit=$robocopyExit"
    Add-Content -Path $LogFile -Value $msg
    exit 1
}

# Count changed files
$changedLines = ($output -split "`n" | Where-Object { $_ -match "^\s+(New File|Newer|Modified)" }).Count

if ($changedLines -gt 0) {
    $msg = "$timestamp  SYNC  ${changedLines} changed file(s) -> SSD"
} else {
    $msg = "$timestamp  OK    no changes"
}

Add-Content -Path $LogFile -Value $msg

# Trim log to last N lines
$lines = Get-Content $LogFile -ErrorAction SilentlyContinue
if ($lines.Count -gt $MaxLogLines) {
    $lines[-$MaxLogLines..-1] | Set-Content $LogFile
}

exit 0
