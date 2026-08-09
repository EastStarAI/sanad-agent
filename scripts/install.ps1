# Canonical Sanad Agent installer for Windows.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$PairingToken,

    [Parameter(Mandatory = $false)]
    [switch]$Login,

    [Parameter(Mandatory = $false)]
    [switch]$NoLogin
)

$ErrorActionPreference = "Stop"
if ($Login -and $NoLogin) {
    throw "Choose either -Login or -NoLogin, not both."
}
if (-not [string]::IsNullOrWhiteSpace($PairingToken) -and ($Login -or $NoLogin)) {
    throw "-PairingToken cannot be combined with -Login or -NoLogin."
}

$Repository = "EastStarAI/sanad-agent"
$ManifestUrl = if ($env:SANAD_RELEASE_MANIFEST_URL) {
    $env:SANAD_RELEASE_MANIFEST_URL
} else {
    "https://github.com/$Repository/releases/latest/download/release-manifest.json"
}

if ($ManifestUrl -notlike "https://github.com/EastStarAI/sanad-agent/*" -and
    $env:SANAD_INSTALL_ALLOW_TEST_URL -ne "1") {
    throw "Refusing an untrusted release manifest URL."
}

$SanadHome = if ($env:SANAD_HOME) { $env:SANAD_HOME } else { Join-Path $HOME ".sanad" }
$BinDir = Join-Path $SanadHome "bin"
$Target = Join-Path $BinDir "sanad.exe"
$Backup = "$Target.rollback"
$ExistingService = Get-ScheduledTask -TaskName "SanadAgent" -ErrorAction SilentlyContinue
$ServiceWasInstalled = $null -ne $ExistingService
$ServiceWasRunning = $ServiceWasInstalled -and $ExistingService.State -eq "Running"
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sanad-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TempDirectory | Out-Null

try {
    $ManifestPath = Join-Path $TempDirectory "release-manifest.json"
    Invoke-WebRequest -Uri $ManifestUrl -OutFile $ManifestPath -UseBasicParsing
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.repository -ne "EastStarAI/sanad-agent") {
        throw "Manifest repository is not trusted."
    }
    $Matches = @(
        $Manifest.artifacts | Where-Object {
            $_.component -eq "agent" -and
            $_.platform -eq "windows" -and
            $_.architecture -eq "x64" -and
            $_.public -eq $true -and
            $_.signature_type -eq "unsigned+github-attestation"
        }
    )
    if ($Matches.Count -ne 1) {
        throw "Manifest does not contain exactly one Windows x64 agent."
    }
    $Artifact = $Matches[0]
    if ($Artifact.filename -notmatch '^sanad-agent-\d+\.\d+\.\d+-windows-x64\.exe$') {
        throw "Manifest returned an invalid filename."
    }
    $ExpectedUrl = "https://github.com/EastStarAI/sanad-agent/releases/download/$($Manifest.tag)/$($Artifact.filename)"
    if ($Artifact.url -ne $ExpectedUrl -and
        $env:SANAD_INSTALL_ALLOW_TEST_URL -ne "1") {
        throw "Manifest returned an untrusted download URL."
    }

    $Staged = Join-Path $TempDirectory $Artifact.filename
    Invoke-WebRequest -Uri $Artifact.url -OutFile $Staged -UseBasicParsing
    $File = Get-Item -LiteralPath $Staged
    if ($File.Length -ne [int64]$Artifact.size) {
        throw "Downloaded artifact size verification failed."
    }
    $ActualHash = (Get-FileHash -LiteralPath $Staged -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualHash -ne $Artifact.sha256.ToLowerInvariant()) {
        throw "Downloaded artifact SHA-256 verification failed."
    }
    Write-Warning "Sanad 1.0.1 for Windows is intentionally unsigned. Origin, manifest URL, size, and SHA-256 were verified; Windows may display Defender or SmartScreen warnings."

    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
    if (Test-Path -LiteralPath $Target) {
        Move-Item -LiteralPath $Target -Destination $Backup -Force
    }
    try {
        Move-Item -LiteralPath $Staged -Destination $Target -Force
        $PortalLogin = $Login.IsPresent
        if (-not [string]::IsNullOrWhiteSpace($PairingToken)) {
            & $Target login --token $PairingToken
            if ($LASTEXITCODE -ne 0) { throw "Device pairing setup failed." }
        } elseif (-not $Login -and -not $NoLogin) {
            if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
                $Response = Read-Host "Connect this device to your Sanad account now? [Y/n]"
                $PortalLogin = [string]::IsNullOrWhiteSpace($Response) -or $Response -match '^(?i:y|yes)$'
            } else {
                Write-Host "No interactive terminal detected; continuing in local-only mode."
            }
        }
        if ($PortalLogin) {
            & $Target login --portal
            if ($LASTEXITCODE -ne 0) { throw "Account sign-in failed." }
        }
        & $Target service install
        if ($LASTEXITCODE -ne 0) { throw "Service installation failed." }
        if ($ServiceWasRunning) {
            & $Target service restart
            if ($LASTEXITCODE -ne 0) { throw "Existing service refresh failed." }
        }
    } catch {
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
        if (Test-Path -LiteralPath $Backup) {
            Move-Item -LiteralPath $Backup -Destination $Target -Force
        }
        throw "Installation failed; rollback completed. $($_.Exception.Message)"
    }

    Write-Host "Sanad Agent installed successfully." -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($PairingToken)) {
        Write-Host "Device pairing started. Sanad will appear online automatically."
    } elseif ($PortalLogin) {
        Write-Host "Account connected. Sanad Agent is running in the background."
    } else {
        Write-Host "Sanad Agent is running in local-only mode."
        Write-Host "Connect it later with:"
        Write-Host "  $Target login"
        Write-Host "  $Target service restart"
    }
} finally {
    if (Test-Path -LiteralPath $TempDirectory) {
        Remove-Item -LiteralPath $TempDirectory -Recurse -Force
    }
}
