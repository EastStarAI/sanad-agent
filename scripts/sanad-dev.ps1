[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $SanadArgs
)

$ErrorActionPreference = 'Stop'
$FvmVersion = '4.1.2'
$FvmChecksums = @{
  'windows-x64' = '9a18b4daac98dac3c3230ff67ccc644d5a7875d1fc09fb7d848cb2900b9478b8'
  'windows-arm64' = '05f8aba2e8d96c26eef054396e7c24c6ace6ca0758c2e0eed1921c18e17202da'
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$CallerDir = (Get-Location).Path
$gitRoot = $null
$gitRootResolved = $false
try {
  $gitRoot = (& git -C $CallerDir rev-parse --show-toplevel 2>$null)
  $gitRootResolved = $LASTEXITCODE -eq 0 -and $gitRoot
} catch {
  $gitRoot = $null
}
if ($gitRootResolved) {
  if (Test-Path (Join-Path $gitRoot 'sanad-agent/scripts/sanad_dev.dart')) {
    $ProjectDir = Join-Path $gitRoot 'sanad-agent'
  } elseif (Test-Path (Join-Path $gitRoot 'scripts/sanad_dev.dart')) {
    $ProjectDir = $gitRoot
  }
}
$resolvedWrapper = Join-Path $ProjectDir 'scripts/sanad-dev.ps1'
if (-not [string]::Equals(
    [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path),
    [IO.Path]::GetFullPath($resolvedWrapper),
    [StringComparison]::OrdinalIgnoreCase
  ) -and (Test-Path $resolvedWrapper)) {
  & $resolvedWrapper @SanadArgs
  exit $LASTEXITCODE
}

$command = if ($SanadArgs.Count -gt 0) { $SanadArgs[0].ToLowerInvariant() } else { '' }
$force = $SanadArgs -contains '--force'

function Write-Stage([string] $Name, [string] $Status) {
  Write-Host ("{0,-38} {1}" -f $Name, $Status)
}

function Show-SanadHelp {
  Write-Host @'
Sanad development launcher

Usage:
  sanad-dev                         Show this help without changing the environment.
  sanad-dev install [--force]       Install/verify FVM, pinned Flutter, and the user command.
  sanad-dev setup [--force]         Ensure install, then resolve Contract, Agent, and Client packages.
  sanad-dev run [all|agent|client]  Ensure install/setup, then launch the requested runtime.
  sanad-dev <runtime-command>       Run status, logs, restart, reload, stop, doctor, or switch.

Official source run:
  sanad-dev run
'@
}

function Invoke-LiveProcessStage(
  [string] $Name,
  [string] $Executable,
  [string[]] $Arguments,
  [string] $WorkingDirectory
) {
  Write-Host "`n==> $Name"
  $watch = [Diagnostics.Stopwatch]::StartNew()
  Push-Location $WorkingDirectory
  try {
    & $Executable @Arguments | Out-Host
    $code = [int]$LASTEXITCODE
  } finally {
    Pop-Location
    $watch.Stop()
  }
  if ($code -ne 0) {
    Write-Stage $Name "failed ($([int]$watch.Elapsed.TotalSeconds)s)"
    throw "$Name failed with exit code $code."
  }
  Write-Stage $Name "ready ($([int]$watch.Elapsed.TotalSeconds)s)"
}

function Ensure-UserBinPath([string] $BinRoot) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @($userPath -split ';' | Where-Object { $_ })
  if ($parts -notcontains $BinRoot) {
    [Environment]::SetEnvironmentVariable('Path', (($parts + $BinRoot) -join ';'), 'User')
    Write-Host "PATH updated for new terminals: $BinRoot"
  }
  if (($env:Path -split ';') -notcontains $BinRoot) {
    $env:Path = "$BinRoot;$env:Path"
  }
}

function Ensure-Fvm {
  $existing = Get-Command fvm -ErrorAction SilentlyContinue
  if ($existing) { return $existing.Source }

  $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
  $platform = "windows-$arch"
  $checksum = $FvmChecksums[$platform]
  if (-not $checksum) { throw "Unsupported Windows architecture: $arch" }

  $installRoot = Join-Path $env:LOCALAPPDATA 'SanadDev/fvm'
  $binRoot = Join-Path $env:LOCALAPPDATA 'SanadDev/bin'
  $archive = Join-Path ([System.IO.Path]::GetTempPath()) "fvm-$FvmVersion-$platform.zip"
  $url = "https://github.com/leoafarias/fvm/releases/download/$FvmVersion/fvm-$FvmVersion-$platform.zip"
  $name = "Installing verified FVM $FvmVersion"
  Write-Host "`n==> $name"
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    if ($actual -ne $checksum) { throw 'FVM archive checksum verification failed.' }
    if (Test-Path $installRoot) { Remove-Item -Recurse -Force $installRoot }
    New-Item -ItemType Directory -Force -Path $installRoot, $binRoot | Out-Null
    Expand-Archive -Force -Path $archive -DestinationPath $installRoot
    Remove-Item -Force $archive
    $fvmExe = Get-ChildItem -Recurse -File $installRoot -Filter 'fvm.exe' | Select-Object -First 1
    if (-not $fvmExe) { throw 'The verified FVM archive did not contain fvm.exe.' }
    Copy-Item -Force $fvmExe.FullName (Join-Path $binRoot 'fvm.exe')
    Ensure-UserBinPath $binRoot
  } catch {
    $watch.Stop()
    Write-Stage $name "failed ($([int]$watch.Elapsed.TotalSeconds)s)"
    throw
  }
  $watch.Stop()
  Write-Stage $name "ready ($([int]$watch.Elapsed.TotalSeconds)s)"
  return (Join-Path $binRoot 'fvm.exe')
}

function Ensure-Flutter([string] $FvmPath) {
  $flutterPin = (Get-Content -Raw (Join-Path $ProjectDir '.fvmrc') | ConvertFrom-Json).flutter
  Push-Location $ProjectDir
  try {
    & $FvmPath spawn $flutterPin --version *> $null
    $ready = $LASTEXITCODE -eq 0
  } finally {
    Pop-Location
  }
  if ($ready) { return }
  Invoke-LiveProcessStage "Installing Flutter $flutterPin" $FvmPath @('install', $flutterPin) $ProjectDir
}

function Install-Shim([bool] $AllowExisting) {
  $binRoot = Join-Path $env:LOCALAPPDATA 'SanadDev/bin'
  New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
  $shim = Join-Path $binRoot 'sanad-dev.cmd'
  $expected = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$ProjectDir\scripts\sanad-dev.ps1`" %*`r`n"
  if (Test-Path $shim) {
    $current = Get-Content -Raw $shim
    if ($current -eq $expected) { return }
    if ($AllowExisting) { return }
    if (-not $force) {
      throw "sanad-dev already belongs to another checkout: $shim. Re-run install --force to replace it."
    }
  }
  $name = 'Installing sanad-dev command'
  Write-Host "`n==> $name"
  $watch = [Diagnostics.Stopwatch]::StartNew()
  Ensure-UserBinPath $binRoot
  Set-Content -NoNewline -Encoding Ascii -Path $shim -Value $expected
  $watch.Stop()
  Write-Stage $name "ready ($([int]$watch.Elapsed.TotalSeconds)s)"
}

function Ensure-Dependencies([string] $FvmPath) {
  $flutterPin = (Get-Content -Raw (Join-Path $ProjectDir '.fvmrc') | ConvertFrom-Json).flutter
  $stampRoot = Join-Path $ProjectDir '.dart_tool/sanad-dev'
  New-Item -ItemType Directory -Force -Path $stampRoot | Out-Null
  $lockFiles = @(
    (Join-Path $ProjectDir 'release/contract/pubspec.lock'),
    (Join-Path $ProjectDir 'agent/pubspec.lock'),
    (Join-Path $ProjectDir 'client/pubspec.lock')
  )
  $fingerprintText = ($flutterPin + ':' + (($lockFiles | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_).Hash }) -join ':'))
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fingerprint = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintText)) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha.Dispose()
  }
  $stamp = Join-Path $stampRoot 'setup.stamp'
  $packagesReady = (Test-Path (Join-Path $ProjectDir 'release/contract/.dart_tool/package_config.json')) -and
    (Test-Path (Join-Path $ProjectDir 'agent/.dart_tool/package_config.json')) -and
    (Test-Path (Join-Path $ProjectDir 'client/.dart_tool/package_config.json'))
  if ((Test-Path $stamp) -and (Get-Content -Raw $stamp) -eq $fingerprint -and $packagesReady) { return }

  Invoke-LiveProcessStage 'Resolving Release Contract dependencies' $FvmPath @('dart', 'pub', 'get') (Join-Path $ProjectDir 'release/contract')
  Invoke-LiveProcessStage 'Resolving Agent dependencies' $FvmPath @('dart', 'pub', 'get') (Join-Path $ProjectDir 'agent')
  Invoke-LiveProcessStage 'Resolving Client dependencies' $FvmPath @('flutter', 'pub', 'get') (Join-Path $ProjectDir 'client')
  Set-Content -NoNewline -Path $stamp -Value $fingerprint
}

function Invoke-Install([bool] $AllowExistingShim) {
  $fvm = Ensure-Fvm
  Ensure-Flutter $fvm
  Install-Shim $AllowExistingShim
  return $fvm
}

function Invoke-Setup([bool] $AllowExistingShim) {
  $fvm = Invoke-Install $AllowExistingShim
  Ensure-Dependencies $fvm
  return $fvm
}

function Require-RuntimeCli {
  $existing = Get-Command fvm -ErrorAction SilentlyContinue
  if (-not $existing) { throw 'FVM is not installed. Run: sanad-dev install' }
  $flutterPin = (Get-Content -Raw (Join-Path $ProjectDir '.fvmrc') | ConvertFrom-Json).flutter
  Push-Location $ProjectDir
  try {
    & $existing.Source spawn $flutterPin --version *> $null
    $flutterReady = $LASTEXITCODE -eq 0
  } finally {
    Pop-Location
  }
  if (-not $flutterReady) {
    throw 'Pinned Flutter is not installed. Run: sanad-dev install'
  }
  if (-not (Test-Path (Join-Path $ProjectDir 'client/.dart_tool/package_config.json'))) {
    throw 'Project packages are not ready. Run: sanad-dev setup'
  }
  return $existing.Source
}

try {
  if ($command -in @('', 'help', '-h', '--help')) {
    Show-SanadHelp
    exit 0
  }
  if ($command -eq 'install') {
    Invoke-Install $false | Out-Null
    exit 0
  }
  if ($command -eq 'setup') {
    Invoke-Setup $false | Out-Null
    exit 0
  }
  $fvm = if ($command -eq 'run') { Invoke-Setup $true } else { Require-RuntimeCli }
  $runtimeArgs = if ($command -eq 'run') {
    @($SanadArgs | Where-Object { $_ -ne '--force' })
  } else {
    $SanadArgs
  }
  $env:SANAD_DEV_CALLER_DIR = $CallerDir
  Push-Location (Join-Path $ProjectDir 'client')
  try { & $fvm dart (Join-Path $ProjectDir 'scripts/sanad_dev.dart') @runtimeArgs; exit $LASTEXITCODE }
  finally { Pop-Location }
} catch {
  Write-Error "sanad-dev failed: $($_.Exception.Message)"
  exit 1
}
