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
$ServiceInstalledThisRun = $false
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("sanad-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $TempDirectory | Out-Null

# The packaged Agent carries its native dictation runtime beside the executable.
# These track whether this run replaced a previously installed runtime so a
# failed install can restore the exact previous layout.
$RuntimeDir = Join-Path $BinDir "native/windows-x64"
$RuntimeBackup = "$RuntimeDir.rollback"
$RuntimeReplaced = $false
$RuntimeInstalled = $false
# The packaged runtime is a dictation companion, not part of the Agent contract:
# a failure to fetch or verify it disables dictation only and never fails the
# install. The reason is recorded beside the runtime so the daemon's dictation
# readiness can name it until a later install or update succeeds.
$RuntimeFailureMarker = Join-Path $BinDir "native/.runtime-install-failed"
$RuntimeFailed = $false

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
    $RuntimeMatches = @(
        $Manifest.artifacts | Where-Object {
            $_.component -eq "agent-runtime" -and
            $_.platform -eq "windows" -and
            $_.architecture -eq "x64" -and
            $_.public -eq $true -and
            $_.format -eq "tar.gz"
        }
    )
    if ($RuntimeMatches.Count -gt 1) {
        throw "Manifest declares more than one Windows x64 Agent runtime."
    }
    $RuntimeArtifact = if ($RuntimeMatches.Count -eq 1) { $RuntimeMatches[0] } else { $null }
    if ($null -ne $RuntimeArtifact) {
        if ($RuntimeArtifact.filename -notmatch '^sanad-agent-runtime-\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?-windows-x64\.tar\.gz$') {
            throw "Manifest returned an invalid native runtime filename."
        }
        $ExpectedRuntimeUrl = "https://github.com/EastStarAI/sanad-agent/releases/download/$($Manifest.tag)/$($RuntimeArtifact.filename)"
        if ($RuntimeArtifact.url -ne $ExpectedRuntimeUrl -and
            $env:SANAD_INSTALL_ALLOW_TEST_URL -ne "1") {
            throw "Manifest returned an untrusted native runtime URL."
        }
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
    Write-Warning "Sanad $($Manifest.version) for Windows is intentionally unsigned. Origin, manifest URL, size, and SHA-256 were verified; Windows may display Defender or SmartScreen warnings."

    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
    if (Test-Path -LiteralPath $Target) {
        Move-Item -LiteralPath $Target -Destination $Backup -Force
    }
    try {
        Move-Item -LiteralPath $Staged -Destination $Target -Force
        if ($null -ne $RuntimeArtifact) {
            if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
                Write-Warning "tar is required to install the native dictation runtime; dictation stays unavailable."
            } else {
                try {
                    $RuntimeArchive = Join-Path $TempDirectory $RuntimeArtifact.filename
                    Invoke-WebRequest -Uri $RuntimeArtifact.url -OutFile $RuntimeArchive -UseBasicParsing
                    if ((Get-Item -LiteralPath $RuntimeArchive).Length -ne [int64]$RuntimeArtifact.size) {
                        throw "Native runtime size verification failed."
                    }
                    $RuntimeHash = (Get-FileHash -LiteralPath $RuntimeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                    if ($RuntimeHash -ne $RuntimeArtifact.sha256.ToLowerInvariant()) {
                        throw "Native runtime SHA-256 verification failed."
                    }
                    $Extract = Join-Path $TempDirectory "runtime"
                    New-Item -ItemType Directory -Path $Extract -Force | Out-Null
                    & tar.exe -xzf $RuntimeArchive -C $Extract
                    if ($LASTEXITCODE -ne 0) { throw "Native runtime extraction failed." }
                    $RuntimeRoot = Join-Path $Extract "native"
                    $ExpectedRuntime = Join-Path $RuntimeRoot "windows-x64"
                    $Unexpected = @(Get-ChildItem -LiteralPath $RuntimeRoot -Force |
                        Where-Object { $_.Name -ne "windows-x64" })
                    if (-not (Test-Path -LiteralPath $ExpectedRuntime -PathType Container) -or
                        $Unexpected.Count -ne 0) {
                        throw "Native runtime archive has an unexpected layout."
                    }
                    # The engine's sherpa subtree is the only allowed nesting; it
                    # mirrors the loader-relative paths `sherpa_onnx` appends to
                    # the directory it is handed. Windows keeps its libraries
                    # flat, so a nested directory there is still a defect.
                    $UnexpectedDirs = @(Get-ChildItem -LiteralPath $ExpectedRuntime -Recurse -Directory |
                        Where-Object { $_.Parent.FullName -ne $ExpectedRuntime -or $_.Name -ne "sherpa" })
                    if ($UnexpectedDirs.Count -ne 0) {
                        throw "Native runtime archive has an unexpected layout."
                    }
                    $RuntimeEntries = @(Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -Force)
                    if (@($RuntimeEntries | Where-Object { $_.Name -like '.*' }).Count -ne 0) {
                        throw "Native runtime archive contains a hidden entry."
                    }
                    if (@($RuntimeEntries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) {
                        throw "Native runtime archive contains a link or reparse point."
                    }
                    $Foreign = @(Get-ChildItem -LiteralPath $ExpectedRuntime -Recurse -File |
                        Where-Object { $_.Name -notmatch '\.(dll|dylib|so(\.\d+(\.\d+)*)?)$' })
                    if ($Foreign.Count -ne 0) {
                        throw "Native runtime archive contains a file outside the library allowlist."
                    }
                    New-Item -ItemType Directory -Path (Join-Path $BinDir "native") -Force | Out-Null
                    if (Test-Path -LiteralPath $RuntimeDir) {
                        if (Test-Path -LiteralPath $RuntimeBackup) {
                            Remove-Item -LiteralPath $RuntimeBackup -Recurse -Force
                        }
                        Move-Item -LiteralPath $RuntimeDir -Destination $RuntimeBackup -Force
                        $RuntimeReplaced = $true
                    }
                    Move-Item -LiteralPath $ExpectedRuntime -Destination $RuntimeDir -Force
                    $RuntimeInstalled = $true
                    # The previous runtime stays in $RuntimeBackup until every later
                    # step (pairing, sign-in, service, cloud health) has committed.
                } catch {
                    # Dictation only: the verified Agent is installed, so the
                    # installation continues and readiness names the reason.
                    $RuntimeFailed = $true
                    if ($RuntimeReplaced -and (Test-Path -LiteralPath $RuntimeBackup) -and
                        -not (Test-Path -LiteralPath $RuntimeDir)) {
                        # This run moved the predecessor aside and could not install
                        # its successor: restore it so a transient failure never
                        # costs a working runtime.
                        Move-Item -LiteralPath $RuntimeBackup -Destination $RuntimeDir -Force
                    }
                    $RuntimeReplaced = $false
                    New-Item -ItemType Directory -Path (Join-Path $BinDir "native") -Force | Out-Null
                    Set-Content -LiteralPath $RuntimeFailureMarker -Value "runtime_install_failed"
                    Write-Warning "Native dictation runtime installation failed ($($_.Exception.Message)); the Agent is installed and runs, and dictation stays unavailable until the next install or update re-fetches it."
                }
            }
        } else {
            if (Test-Path -LiteralPath $RuntimeDir) {
                Write-Warning "This release publishes no native dictation runtime for Windows x64; keeping the runtime already installed in $RuntimeDir."
            } else {
                Write-Warning "This release publishes no native dictation runtime for Windows x64 and none is installed; dictation stays unavailable."
            }
            if (Test-Path -LiteralPath $RuntimeFailureMarker) {
                Remove-Item -LiteralPath $RuntimeFailureMarker -Force
            }
        }
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
        $ServiceInstalledThisRun = -not $ServiceWasInstalled
        if ($ServiceWasRunning) {
            & $Target service restart
            if ($LASTEXITCODE -ne 0) { throw "Existing service refresh failed." }
        }
    } catch {
        $Failure = $_
        if ($ServiceInstalledThisRun) {
            try {
                Unregister-ScheduledTask -TaskName "SanadAgent" -Confirm:$false -ErrorAction Stop
            } catch {
                Write-Warning "Failed to remove the partially installed SanadAgent task."
            }
        }
        $RollbackIncomplete = $false
        if ($RuntimeInstalled -and (Test-Path -LiteralPath $RuntimeDir)) {
            try {
                Remove-Item -LiteralPath $RuntimeDir -Recurse -Force -ErrorAction Stop
            } catch {
                # A locked directory must not abort the rollback before the
                # executable is restored and the truthful result is reported.
                $RollbackIncomplete = $true
                Write-Warning "The runtime this run installed could not be removed; it is kept at $RuntimeDir."
            }
        }
        if ($RuntimeReplaced -and (Test-Path -LiteralPath $RuntimeBackup)) {
            if (Test-Path -LiteralPath $RuntimeDir) {
                # A forced move into a directory that could not be cleared would
                # nest the backup and leave the only predecessor copy buried.
                $RollbackIncomplete = $true
                Write-Warning "The previous native runtime could not be restored; it is kept at $RuntimeBackup."
            } else {
                try {
                    Move-Item -LiteralPath $RuntimeBackup -Destination $RuntimeDir -Force
                } catch {
                    $RollbackIncomplete = $true
                    Write-Warning "The previous native runtime could not be restored; it is kept at $RuntimeBackup."
                }
            }
        }
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
        if (Test-Path -LiteralPath $Backup) {
            try {
                Move-Item -LiteralPath $Backup -Destination $Target -Force
            } catch {
                $RollbackIncomplete = $true
                Write-Warning "The previous executable could not be restored; it is kept at $Backup."
            }
        }
        if ($RollbackIncomplete) {
            throw "Installation failed; the previous installation could not be fully restored (*.rollback files remain beside $Target). $($Failure.Exception.Message)"
        }
        throw "Installation failed; rollback completed. $($Failure.Exception.Message)"
    }

    # Commit: every later step succeeded, so the replaced runtime is disposable.
    if (Test-Path -LiteralPath $RuntimeBackup) {
        if ($RuntimeFailed) {
            # The predecessor could not be restored; it is the only copy left.
            Write-Warning "The previous native runtime is kept at $RuntimeBackup."
        } else {
            Remove-Item -LiteralPath $RuntimeBackup -Recurse -Force
        }
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
