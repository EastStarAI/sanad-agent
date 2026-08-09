param(
    [string]$EnvConfig = "config/prod.json"
)

# Exit on error
$ErrorActionPreference = "Stop"

function Invoke-Flutter {
    param([string[]]$argsList)
    & fvm flutter $argsList
}

# Variables
$APP_NAME = "Sanad"
$VersionName = ((Get-Content "pubspec.yaml" | Select-String "^version:") -split ": ")[1].Trim().Split("+")[0]
# Temporary policy: every Windows release remains unsigned until the explicit
# signed-only Authenticode migration changes this build contract.
$UnsignedRelease = $true
$INSTALLER_NAME = "sanad-client-$VersionName-windows-x64.exe"
$UNVERSIONED_INSTALLER_NAME = "sanad-client-setup.exe"
$OUTPUT_DIR = "build"
$BUILD_PRODUCT_DIR = "build\windows\x64\runner\Release"
$INSTALLER_SCRIPTS_DIR = "release\windows"
$NSIS_PATH = "C:\Program Files (x86)\NSIS\makensis.exe"
if (-not (Test-Path $NSIS_PATH)) {
    $NSIS_PATH = "C:\Program Files\NSIS\makensis.exe"
}
if (-not (Test-Path $NSIS_PATH)) {
    $nsisFromPath = Get-Command makensis -ErrorAction SilentlyContinue
    if ($nsisFromPath) {
        $NSIS_PATH = $nsisFromPath.Source
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "Building Windows Installer for $APP_NAME"
Write-Host "========================================"
Write-Host ""

# Check if NSIS is installed
if (-not (Test-Path $NSIS_PATH)) {
    Write-Host "ERROR: NSIS not found. Checked default paths and system PATH." -ForegroundColor Red
    Write-Host "Please install NSIS from: https://nsis.sourceforge.io/" -ForegroundColor Yellow
    exit 1
}

# Step 1: Clean project
Write-Host "Cleaning project..." -ForegroundColor Cyan
Invoke-Flutter "clean"

# Step 2: Get dependencies
Write-Host ""
Write-Host "Getting dependencies..." -ForegroundColor Cyan
Invoke-Flutter "pub", "get"

# Step 3: Build Windows Release
Write-Host ""
Write-Host "Building Windows application (Release) with config: $EnvConfig..." -ForegroundColor Cyan
Invoke-Flutter "build", "windows", "--release", "--dart-define-from-file=$EnvConfig"

if (-not (Test-Path $BUILD_PRODUCT_DIR)) {
    Write-Host "ERROR: Build failed - Release folder not found" -ForegroundColor Red
    exit 1
}

Write-Host "Build completed successfully" -ForegroundColor Green

# The temporary Windows policy is intentionally unsigned for every release.
# The Authenticode helper remains dormant until a signed-only migration is approved.
$signingTargets = @(Get-ChildItem $BUILD_PRODUCT_DIR -Filter "*.exe" -File | ForEach-Object FullName)
if ($UnsignedRelease) {
    Write-Host "NOTICE: Creating the approved temporarily unsigned Windows $VersionName package." -ForegroundColor Yellow
} else {
    & "$PSScriptRoot\sign_windows.ps1" -Paths $signingTargets
}

# Step 3.5: Ensure Visual C++ Redistributable is available
Write-Host ""
$cacheDir = "release\shared"
$vcRedistCache = "$cacheDir\vc_redist.x64.exe"
$vcRedistDest = "$BUILD_PRODUCT_DIR\vc_redist.x64.exe"

# 1. Check if we need to download it to cache
if (-not (Test-Path $vcRedistCache)) {
    Write-Host "Downloading Visual C++ Redistributable to cache..." -ForegroundColor Cyan
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
    $vcRedistUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    Invoke-WebRequest -Uri $vcRedistUrl -OutFile $vcRedistCache
    Write-Host "Downloaded successfully to $vcRedistCache" -ForegroundColor Green
}

# 2. Copy from cache to build directory
Write-Host "Copying Visual C++ Redistributable to build directory..." -ForegroundColor Gray
Copy-Item $vcRedistCache $vcRedistDest -Force

# Step 4: Create output directory for installer
Write-Host ""
Write-Host "Preparing output directory..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null

# Step 5: Build NSIS Installer
Write-Host ""
Write-Host "Building NSIS installer..." -ForegroundColor Cyan
$installerScript = Join-Path -Path $INSTALLER_SCRIPTS_DIR -ChildPath "sanad_client_installer.nsi"

if (-not (Test-Path $installerScript)) {
    Write-Host "ERROR: Installer script not found at $installerScript" -ForegroundColor Red
    exit 1
}

# Run NSIS compiler with explicit metadata consumed by Installed Apps.
& $NSIS_PATH "/DAPP_VERSION=$VersionName" $installerScript

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: NSIS build failed" -ForegroundColor Red
    exit 1
}

# Step 6: Verify installer was created (now outputs directly to build/)
$unversionedInstallerPath = Join-Path -Path $OUTPUT_DIR -ChildPath $UNVERSIONED_INSTALLER_NAME
$installerPath = Join-Path -Path $OUTPUT_DIR -ChildPath $INSTALLER_NAME

if (Test-Path $unversionedInstallerPath) {
    Move-Item $unversionedInstallerPath $installerPath -Force
}

if ((Test-Path $installerPath) -and -not $UnsignedRelease) {
    & "$PSScriptRoot\sign_windows.ps1" -Paths @($installerPath)
}

if (Test-Path $installerPath) {
    # Get file size
    $fileSize = (Get-Item $installerPath).Length / 1MB
    Write-Host ""
    Write-Host "========================================"
    Write-Host "Installer created successfully!"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "Installer Details:" -ForegroundColor Cyan
    Write-Host "  Name: $INSTALLER_NAME"
    Write-Host "  Path: $(Resolve-Path $installerPath)"
    Write-Host "  Size: $([Math]::Round($fileSize, 2)) MB"
    Write-Host ""
    Write-Host "Ready for distribution!"
    Write-Host ""
}
else {
    Write-Host "ERROR: Installer file not found at $installerPath" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Build process completed successfully!"
