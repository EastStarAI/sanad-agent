param(
    [switch]$UpgradeGuardOnly
)

# Verify the release payload and exercise the transactional Windows upgrade
# helpers without touching an installed Sanad Client.
$ErrorActionPreference = "Continue"

$clientDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$releaseDir = Join-Path $clientDir "build\windows\x64\runner\Release"
$installerDir = $PSScriptRoot
$versionName = ((Get-Content -LiteralPath (Join-Path $clientDir "pubspec.yaml") | Select-String "^version:") -split ": ")[1].Trim().Split("+")[0]
$builtInstaller = Join-Path $clientDir "build\sanad-client-$versionName-windows-x64.exe"

Write-Host ""
Write-Host "========================================="
Write-Host "Sanad Windows Installer Verification"
Write-Host "========================================="
Write-Host ""

function Test-UpgradeGuard {
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sanad-installer-test-" + [guid]::NewGuid().ToString("N"))
    $target = Join-Path $testRoot "Sanad"
    $staged = Join-Path $target ".sanad-install-staging"
    $lock = $null
    try {
        New-Item -ItemType Directory -Path (Join-Path $target "data") -Force | Out-Null

        # A copied PowerShell host has the exact installed executable name and
        # stays alive without child processes. This exercises the bounded
        # compatibility force-stop path without touching a real Sanad process.
        $testExecutable = Join-Path $target "sanad-client.exe"
        Copy-Item -LiteralPath ((Get-Command powershell.exe).Source) -Destination $testExecutable
        $targetProcess = Start-Process -FilePath $testExecutable `
            -ArgumentList "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30" `
            -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 300
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $installerDir "stop_installed_client.ps1") `
            -TargetPath $testExecutable -GraceSeconds 0 *> $null
        if ($LASTEXITCODE -ne 0 -or -not $targetProcess.WaitForExit(5000)) {
            throw "The stop helper did not terminate the exact target process."
        }

        Set-Content -LiteralPath $testExecutable -Value "old executable" -NoNewline
        Set-Content -LiteralPath (Join-Path $target "old.dll") -Value "old dll" -NoNewline
        Set-Content -LiteralPath (Join-Path $target "data\old.asset") -Value "old data" -NoNewline

        # Hold an installed DLL with exclusive access. The stop helper must fail
        # closed even though no process with the target executable name exists.
        $lockedDll = Join-Path $target "old.dll"
        $lock = [System.IO.File]::Open(
            $lockedDll,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $installerDir "stop_installed_client.ps1") `
            -TargetPath (Join-Path $target "sanad-client.exe") -GraceSeconds 0 *> $null
        if ($LASTEXITCODE -eq 0) {
            throw "The stop helper accepted a locked installed DLL."
        }
        $lock.Dispose()
        $lock = $null

        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $installerDir "stop_installed_client.ps1") `
            -TargetPath (Join-Path $target "sanad-client.exe") -GraceSeconds 0 *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "The stop helper rejected an unlocked isolated payload."
        }

        New-Item -ItemType Directory -Path (Join-Path $staged "data") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staged "sanad-client.exe") -Value "new executable" -NoNewline
        Set-Content -LiteralPath (Join-Path $staged "new.dll") -Value "new dll" -NoNewline
        Set-Content -LiteralPath (Join-Path $staged "data\new.asset") -Value "new data" -NoNewline

        # Force a mid-transaction move failure after the old payload has been
        # backed up. The helper must restore the complete old payload.
        $lock = [System.IO.File]::Open(
            (Join-Path $staged "new.dll"),
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $installerDir "install_staged_client.ps1") `
            -TargetDirectory $target -StagedDirectory $staged *> $null
        if ($LASTEXITCODE -eq 0) {
            throw "The replacement helper accepted a locked staged DLL."
        }
        $lock.Dispose()
        $lock = $null
        if ((Get-Content -LiteralPath (Join-Path $target "sanad-client.exe") -Raw) -ne "old executable" -or
            (Get-Content -LiteralPath (Join-Path $target "old.dll") -Raw) -ne "old dll" -or
            (Get-Content -LiteralPath (Join-Path $target "data\old.asset") -Raw) -ne "old data" -or
            (Test-Path -LiteralPath (Join-Path $target ".sanad-install-backup"))) {
            throw "The failed replacement did not restore the old payload."
        }

        Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path (Join-Path $staged "data") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staged "sanad-client.exe") -Value "new executable" -NoNewline
        Set-Content -LiteralPath (Join-Path $staged "new.dll") -Value "new dll" -NoNewline
        Set-Content -LiteralPath (Join-Path $staged "data\new.asset") -Value "new data" -NoNewline
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $installerDir "install_staged_client.ps1") `
            -TargetDirectory $target -StagedDirectory $staged *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "The staged payload replacement helper failed."
        }
        if ((Get-Content -LiteralPath (Join-Path $target "sanad-client.exe") -Raw) -ne "new executable" -or
            (Get-Content -LiteralPath (Join-Path $target "new.dll") -Raw) -ne "new dll" -or
            (Get-Content -LiteralPath (Join-Path $target "data\new.asset") -Raw) -ne "new data" -or
            (Test-Path -LiteralPath (Join-Path $target "old.dll")) -or
            (Test-Path -LiteralPath (Join-Path $target ".sanad-install-backup"))) {
            throw "The isolated upgrade did not produce the exact new payload."
        }
        return $true
    } catch {
        Write-Host "[FAIL] Running-client lock and staged replacement - $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        if ($lock) { $lock.Dispose() }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Running isolated upgrade guard verification..." -ForegroundColor Cyan
$upgradeGuardPassed = Test-UpgradeGuard
if ($upgradeGuardPassed) {
    Write-Host "[OK] Locked-file rejection and transactional payload replacement" -ForegroundColor Green
} elseif ($UpgradeGuardOnly) {
    exit 1
}
if ($UpgradeGuardOnly) {
    exit 0
}

# Check if release build exists
if (-not (Test-Path $releaseDir)) {
    Write-Host "ERROR: Release build not found at $releaseDir" -ForegroundColor Red
    Write-Host "Please run: fvm flutter build windows --release" -ForegroundColor Yellow
    exit 1
}

$checksPassed = 0
$checksFailed = 0
if ($upgradeGuardPassed) { $checksPassed++ } else { $checksFailed++ }

# Function to check file
function Check-File {
    param($path, $name)
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Item -LiteralPath $path).Length -gt 0) {
        $size = (Get-Item -LiteralPath $path).Length / 1MB
        Write-Host "[OK] $name ($([Math]::Round($size, 2)) MB)" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "[FAIL] $name - MISSING OR EMPTY" -ForegroundColor Red
        return $false
    }
}

# Function to check directory
function Check-Directory {
    param($path, $name)
    if (Test-Path $path) {
        Write-Host "[OK] $name (Directory exists)" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "[FAIL] $name - NOT FOUND" -ForegroundColor Red
        return $false
    }
}

Write-Host "1. Checking Main Executable:" -ForegroundColor Cyan
if (Check-File "$releaseDir\sanad-client.exe" "sanad-client.exe") { $checksPassed++ } else { $checksFailed++ }

Write-Host ""
Write-Host "2. Checking Flutter Runtime:" -ForegroundColor Cyan
if (Check-File "$releaseDir\flutter_windows.dll" "flutter_windows.dll") { $checksPassed++ } else { $checksFailed++ }

Write-Host ""
Write-Host "3. Checking Packaged DLLs:" -ForegroundColor Cyan
$packagedDlls = @(Get-ChildItem -LiteralPath $releaseDir -Filter "*.dll" -File)
if ($packagedDlls.Count -eq 0) {
    Write-Host "[FAIL] No packaged DLLs were produced" -ForegroundColor Red
    $checksFailed++
}
foreach ($dll in $packagedDlls) {
    if (Check-File $dll.FullName $dll.Name) { $checksPassed++ } else { $checksFailed++ }
}

Write-Host ""
Write-Host "4. Checking Data Directory:" -ForegroundColor Cyan
if (Check-Directory "$releaseDir\data" "data folder") { $checksPassed++ } else { $checksFailed++ }

Write-Host ""
Write-Host "5. Checking Critical Data Files:" -ForegroundColor Cyan
if (Check-File "$releaseDir\data\icudtl.dat" "icudtl.dat (Unicode)") { $checksPassed++ } else { $checksFailed++ }
if (Check-File "$releaseDir\data\app.so" "app.so (Dart Engine)") { $checksPassed++ } else { $checksFailed++ }

Write-Host ""
Write-Host "6. Checking Flutter Assets:" -ForegroundColor Cyan
if (Check-Directory "$releaseDir\data\flutter_assets" "flutter_assets") { $checksPassed++ } else { $checksFailed++ }
if (Check-File "$releaseDir\data\flutter_assets\AssetManifest.bin" "AssetManifest.bin") { $checksPassed++ } else { $checksFailed++ }

Write-Host ""
Write-Host "7. Checking Assets Folder:" -ForegroundColor Cyan
$assetsDir = "$releaseDir\data\flutter_assets\assets"
if (Test-Path $assetsDir) {
    $assetFiles = (Get-ChildItem $assetsDir -Recurse).Count
    if ($assetFiles -gt 0) {
        Write-Host "[OK] assets folder ($assetFiles files)" -ForegroundColor Green
        $checksPassed++
    }
    else {
        Write-Host "[FAIL] No assets found" -ForegroundColor Red
        $checksFailed++
    }
}
else {
    Write-Host "[FAIL] assets folder - NOT FOUND" -ForegroundColor Red
    $checksFailed++
}

Write-Host ""
Write-Host "8. Checking Fonts:" -ForegroundColor Cyan
$fontsDir = "$releaseDir\data\flutter_assets\fonts"
if (Test-Path $fontsDir) {
    $fontFiles = (Get-ChildItem $fontsDir -Recurse).Count
    Write-Host "[OK] fonts folder ($fontFiles font files)" -ForegroundColor Green
    $checksPassed++
}
else {
    Write-Host "[WARN] fonts folder not found (optional)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "9. Checking Installer Scripts:" -ForegroundColor Cyan
if (Check-File "$installerDir\sanad_client_installer.nsi" "sanad_client_installer.nsi") { $checksPassed++ } else { $checksFailed++ }
if (Check-File "$installerDir\sanad_client_installer.iss" "sanad_client_installer.iss") { $checksPassed++ } else { $checksFailed++ }
if (Check-File "$installerDir\stop_installed_client.ps1" "stop_installed_client.ps1") { $checksPassed++ } else { $checksFailed++ }
if (Check-File "$installerDir\install_staged_client.ps1" "install_staged_client.ps1") { $checksPassed++ } else { $checksFailed++ }

Write-Host ""
Write-Host "10. Checking Built Installer:" -ForegroundColor Cyan
if (Check-File $builtInstaller "sanad-client-$versionName-windows-x64.exe") { $checksPassed++ } else { $checksFailed++ }

Write-Host ""
Write-Host "========================================="
Write-Host "Verification Results:" -ForegroundColor Cyan
Write-Host "========================================="
Write-Host ""
Write-Host "Total Checks: $($checksPassed + $checksFailed)" -ForegroundColor White
Write-Host "[PASSED] $checksPassed" -ForegroundColor Green
Write-Host "[FAILED] $checksFailed" -ForegroundColor Red

Write-Host ""

if ($checksFailed -eq 0) {
    Write-Host "SUCCESS: All required files are present!" -ForegroundColor Green
    Write-Host ""
    Write-Host "The installer is ready for distribution." -ForegroundColor Green
    Write-Host "File: build\sanad-client-$versionName-windows-x64.exe" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "FAILURE: Some required files are missing!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please rebuild the Windows application:" -ForegroundColor Yellow
    Write-Host "  fvm flutter build windows --release" -ForegroundColor Yellow
    exit 1
}
