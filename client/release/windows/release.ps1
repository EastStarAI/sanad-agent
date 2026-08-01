param(
    [string]$EnvConfig = "config/prod.json"
)

$ErrorActionPreference = "Stop"
$ClientRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$RepositoryRoot = (Resolve-Path (Join-Path $ClientRoot "..")).Path
$VersionName = ((Get-Content (Join-Path $ClientRoot "pubspec.yaml") |
    Select-String "^version:") -split ": ")[1].Trim().Split("+")[0]
$Installer = Join-Path $ClientRoot "build\sanad-client-$VersionName-windows-x64.exe"
$PrivateKeyPath = $env:WINSPARKLE_PRIVATE_KEY_PATH

Push-Location (Join-Path $RepositoryRoot "agent")
try {
    & fvm dart run tool/release_tool.dart validate-contract --repo-root ..
    if ($LASTEXITCODE -ne 0) { throw "Release contract validation failed." }
} finally {
    Pop-Location
}

Push-Location $ClientRoot
try {
    & "$PSScriptRoot\build_installer.ps1" -EnvConfig $EnvConfig
    if (-not $PrivateKeyPath -or -not (Test-Path -LiteralPath $PrivateKeyPath)) {
        throw "WINSPARKLE_PRIVATE_KEY_PATH is required."
    }
    $TemporaryKey = Join-Path $ClientRoot "dsa_priv.pem"
    Copy-Item -LiteralPath $PrivateKeyPath -Destination $TemporaryKey -Force
    try {
        $SignOutput = & fvm dart run auto_updater:sign_update $Installer 2>&1
        $Match = [regex]::Match(($SignOutput -join "`n"), 'sparkle:dsaSignature="([^"]*)"')
        if (-not $Match.Success) { throw "WinSparkle update signing failed." }
        Set-Content -LiteralPath "$Installer.update-signature" `
            -Value $Match.Groups[1].Value -NoNewline
    } finally {
        if (Test-Path -LiteralPath $TemporaryKey) {
            Remove-Item -LiteralPath $TemporaryKey -Force
        }
    }
} finally {
    Pop-Location
}

Write-Host "Prepared unsigned Windows artifact with WinSparkle update signature." -ForegroundColor Green
