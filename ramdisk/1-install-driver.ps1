<#
.SYNOPSIS
    Install ImDisk Toolkit RAM disk driver.
.DESCRIPTION
    Downloads and silently installs ImDisk Toolkit (RAM disk driver for Windows).
    Must be run as Administrator.
    Run once during initial setup.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$InstallerUrl = "https://sourceforge.net/projects/imdisk-toolkit/files/latest/download"
$InstallerPath = "$env:TEMP\ImDiskTk-x64.exe"
$InstallDir = "${env:ProgramFiles}\ImDisk"

Write-Host "=== ImDisk RAM Disk Driver Installer ===" -ForegroundColor Cyan

# Check if already installed
if (Test-Path "$InstallDir\imdisk.exe") {
    Write-Host "ImDisk appears to be already installed at: $InstallDir" -ForegroundColor Yellow
    Write-Host "Current version info:" -ForegroundColor Yellow
    try {
        imdisk --version 2>&1 | Select-Object -First 3 | Write-Host
    } catch {
        Write-Host "  (could not determine version)" -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "If you want to re-install, uninstall from Control Panel first." -ForegroundColor Yellow
    Write-Host "Proceeding with existing installation." -ForegroundColor Green
    exit 0
}

Write-Host "Downloading ImDisk Toolkit from SourceForge..." -ForegroundColor Cyan
Write-Host "  URL: $InstallerUrl" -ForegroundColor Gray
Write-Host "  Save to: $InstallerPath" -ForegroundColor Gray

# Download with progress bar
$ProgressPreference = 'SilentlyContinue'
try {
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerPath -UseBasicParsing -MaximumRetryCount 3
} catch {
    Write-Host "ERROR: Failed to download ImDisk Toolkit." -ForegroundColor Red
    Write-Host "Trying alternate download URL..." -ForegroundColor Yellow
    $AlternateUrl = "https://downloads.sourceforge.net/project/imdisk-toolkit/20240126/ImDiskTk-x64.zip"
    $InstallerPath = "$env:TEMP\ImDiskTk-x64.zip"
    try {
        Invoke-WebRequest -Uri $AlternateUrl -OutFile $InstallerPath -UseBasicParsing
        Write-Host "Downloaded ZIP archive. Please extract and run install.cmd as Admin manually." -ForegroundColor Yellow
        Write-Host "  Archive: $InstallerPath" -ForegroundColor Gray
        exit 1
    } catch {
        Write-Host "ERROR: Both download attempts failed." -ForegroundColor Red
        Write-Host "Please download ImDisk Toolkit manually from: https://sourceforge.net/projects/imdisk-toolkit/" -ForegroundColor Yellow
        Write-Host "After installing, re-run this script to verify." -ForegroundColor Yellow
        exit 1
    }
}

if (-not (Test-Path $InstallerPath)) {
    Write-Host "ERROR: Download failed — installer not found at $InstallerPath" -ForegroundColor Red
    exit 1
}

Write-Host "Installing ImDisk Toolkit (silent)..." -ForegroundColor Cyan
try {
    $process = Start-Process -FilePath $InstallerPath -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Host "WARNING: Installer returned exit code $($process.ExitCode)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR: Installation failed: $_" -ForegroundColor Red
    exit 1
}

# Clean up installer
Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue

# Verify installation
if (Test-Path "$InstallDir\imdisk.exe") {
    Write-Host ""
    Write-Host "ImDisk Toolkit installed successfully!" -ForegroundColor Green
    Write-Host "  Path: $InstallDir" -ForegroundColor Gray

    # Test the driver
    try {
        $imdiskInfo = & "$InstallDir\imdisk.exe" -l 2>&1
        Write-Host "  Driver: responsive" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: imdisk.exe found but may need a reboot to load the driver." -ForegroundColor Yellow
        Write-Host "  If subsequent scripts fail, reboot and re-run from step 3." -ForegroundColor Yellow
    }
} else {
    Write-Host "ERROR: Installation verification failed — imdisk.exe not found at expected path." -ForegroundColor Red
    Write-Host "  Expected: $InstallDir\imdisk.exe" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Done. Proceed to: 2-prepare-backup.ps1" -ForegroundColor Cyan
