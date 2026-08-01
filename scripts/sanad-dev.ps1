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

$command = if ($SanadArgs.Count -gt 0) { $SanadArgs[0].ToLowerInvariant() } else { '' }
$force = $SanadArgs -contains '--force'
$verboseSetup = $SanadArgs -contains '--verbose'
$needsSetup = $SanadArgs.Count -eq 0 -or $command -eq 'setup'

function Write-Stage([string] $Name, [string] $Status) {
  Write-Host ("{0,-38} {1}" -f $Name, $Status)
}

function Invoke-SetupProcess([string] $Executable, [string[]] $Arguments, [string] $WorkingDirectory) {
  Push-Location $WorkingDirectory
  try {
    if ($verboseSetup) {
      & $Executable @Arguments | Out-Host
    } else {
      $output = & $Executable @Arguments 2>&1
      if ($LASTEXITCODE -ne 0) { $output | Write-Error }
    }
    return [int]$LASTEXITCODE
  } finally {
    Pop-Location
  }
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
  if ($existing) {
    Write-Stage 'Checking FVM' 'ready'
    return $existing.Source
  }

  $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
  $platform = "windows-$arch"
  $checksum = $FvmChecksums[$platform]
  if (-not $checksum) { throw "Unsupported Windows architecture: $arch" }

  $installRoot = Join-Path $env:LOCALAPPDATA 'SanadDev/fvm'
  $binRoot = Join-Path $env:LOCALAPPDATA 'SanadDev/bin'
  $archive = Join-Path ([System.IO.Path]::GetTempPath()) "fvm-$FvmVersion-$platform.zip"
  $url = "https://github.com/leoafarias/fvm/releases/download/$FvmVersion/fvm-$FvmVersion-$platform.zip"
  Write-Stage 'Installing verified FVM' "downloading $FvmVersion"
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
  Write-Stage 'Installing verified FVM' 'ready'
  return (Join-Path $binRoot 'fvm.exe')
}

function Install-Shim([string] $FvmPath) {
  $binRoot = Join-Path $env:LOCALAPPDATA 'SanadDev/bin'
  New-Item -ItemType Directory -Force -Path $binRoot | Out-Null
  Ensure-UserBinPath $binRoot
  $shim = Join-Path $binRoot 'sanad-dev.cmd'
  $expected = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$ProjectDir\scripts\sanad-dev.ps1`" %*`r`n"
  if (Test-Path $shim) {
    $current = Get-Content -Raw $shim
    if ($current -ne $expected -and -not $force) {
      throw "sanad-dev already belongs to another checkout: $shim. Re-run setup --force to replace it."
    }
  }
  Set-Content -NoNewline -Encoding Ascii -Path $shim -Value $expected
  Write-Stage 'Installing sanad-dev command' 'ready'
}

function Invoke-Setup([string] $FvmPath) {
  $flutterPin = (Get-Content -Raw (Join-Path $ProjectDir '.fvmrc') | ConvertFrom-Json).flutter
  $flutterExecutable = Join-Path $ProjectDir '.fvm/flutter_sdk/bin/flutter.bat'
  if (Test-Path $flutterExecutable) {
    Write-Stage "Installing Flutter $flutterPin" 'skipped'
  } else {
    Write-Stage "Installing Flutter $flutterPin" 'running'
    $code = Invoke-SetupProcess $FvmPath @('install', $flutterPin) $ProjectDir
    if ($code -ne 0) { throw 'Pinned Flutter SDK installation failed.' }
  }

  $stampRoot = Join-Path $ProjectDir '.dart_tool/sanad-dev'
  New-Item -ItemType Directory -Force -Path $stampRoot | Out-Null
  $lockFiles = @((Join-Path $ProjectDir 'agent/pubspec.lock'), (Join-Path $ProjectDir 'client/pubspec.lock'))
  $fingerprintText = ($flutterPin + ':' + (($lockFiles | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_).Hash }) -join ':'))
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fingerprint = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintText)) | ForEach-Object { $_.ToString('x2') })
  } finally {
    $sha.Dispose()
  }
  $stamp = Join-Path $stampRoot 'setup.stamp'
  $packagesReady = (Test-Path (Join-Path $ProjectDir 'agent/.dart_tool/package_config.json')) -and (Test-Path (Join-Path $ProjectDir 'client/.dart_tool/package_config.json'))
  if ((Test-Path $stamp) -and (Get-Content -Raw $stamp) -eq $fingerprint -and $packagesReady) {
    Write-Stage 'Resolving package dependencies' 'skipped'
  } else {
    Write-Stage 'Resolving Agent dependencies' 'running'
    $code = Invoke-SetupProcess $FvmPath @('dart', 'pub', 'get') (Join-Path $ProjectDir 'agent')
    if ($code -ne 0) { throw 'Agent dependency setup failed.' }
    Write-Stage 'Resolving Client dependencies' 'running'
    $code = Invoke-SetupProcess $FvmPath @('flutter', 'pub', 'get') (Join-Path $ProjectDir 'client')
    if ($code -ne 0) { throw 'Client dependency setup failed.' }
    Set-Content -NoNewline -Path $stamp -Value $fingerprint
  }
  Install-Shim $FvmPath
}

try {
  $fvm = Ensure-Fvm
  if ($needsSetup) {
    Invoke-Setup $fvm
    if ($command -eq 'setup') { exit 0 }
    $SanadArgs = @('run', 'all')
  }
  $env:SANAD_DEV_CALLER_DIR = $CallerDir
  Push-Location (Join-Path $ProjectDir 'client')
  try { & $fvm dart (Join-Path $ProjectDir 'scripts/sanad_dev.dart') @SanadArgs; exit $LASTEXITCODE }
  finally { Pop-Location }
} catch {
  Write-Error "sanad-dev bootstrap failed: $($_.Exception.Message)"
  exit 1
}
