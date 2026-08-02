[CmdletBinding()]
param(
    [ValidateSet("Prepare", "Capture")]
    [string]$Phase = "Prepare",

    [ValidateSet("BeforeInstall", "AfterInstall", "AfterReboot", "AfterUninstall")]
    [string]$Checkpoint = "BeforeInstall",

    [long]$RunId = 30728515333,

    [string]$EvidenceDirectory = "sanad-12-windows-evidence"
)

$ErrorActionPreference = "Stop"
$Repository = "EastStarAI/sanad-agent"
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$EvidenceRoot = if ([System.IO.Path]::IsPathRooted($EvidenceDirectory)) {
    $EvidenceDirectory
} else {
    Join-Path $RepositoryRoot $EvidenceDirectory
}
$ArtifactRoot = Join-Path $EvidenceRoot "artifacts"

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $false)]
        [string]$OutputPath
    )

    $output = & $Command @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($OutputPath) {
        $output | Out-File -LiteralPath $OutputPath -Encoding utf8
    }
    if ($code -ne 0) {
        throw "$Command failed with exit code $code."
    }
    return $output
}

function Get-WindowsIdentity {
    $os = Get-CimInstance Win32_OperatingSystem
    $system = Get-CimInstance Win32_ComputerSystem
    if ($os.ProductType -ne 1) {
        throw "A Windows 10 or Windows 11 workstation is required; Windows Server is not accepted."
    }
    if ($os.Caption -notmatch "Windows (10|11)") {
        throw "Unsupported clean-machine target: $($os.Caption)."
    }
    if ($os.OSArchitecture -ne "64-bit") {
        throw "Windows x64 is required."
    }

    [ordered]@{
        caption = $os.Caption
        version = $os.Version
        build_number = $os.BuildNumber
        architecture = $os.OSArchitecture
        product_type = $os.ProductType
        manufacturer = $system.Manufacturer
        model = $system.Model
        captured_at_utc = [DateTime]::UtcNow.ToString("o")
    }
}

function Get-DefenderEvidence {
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        throw "Microsoft Defender cmdlets are unavailable. Do not disable protection to continue."
    }
    $status = Get-MpComputerStatus
    if (-not $status.AntivirusEnabled -or -not $status.RealTimeProtectionEnabled) {
        throw "Microsoft Defender Antivirus and real-time protection must remain enabled."
    }

    $preference = Get-MpPreference
    [ordered]@{
        antivirus_enabled = $status.AntivirusEnabled
        antispyware_enabled = $status.AntispywareEnabled
        behavior_monitor_enabled = $status.BehaviorMonitorEnabled
        ioav_protection_enabled = $status.IoavProtectionEnabled
        real_time_protection_enabled = $status.RealTimeProtectionEnabled
        tamper_protection_enabled = $status.IsTamperProtected
        smart_app_control_state = $status.SmartAppControlState
        antivirus_signature_version = $status.AntivirusSignatureVersion
        antivirus_signature_last_updated = $status.AntivirusSignatureLastUpdated
        pua_protection = $preference.PUAProtection
        network_protection = $preference.EnableNetworkProtection
        disable_realtime_monitoring = $preference.DisableRealtimeMonitoring
    }
}

function Save-JsonEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-WindowsArtifacts {
    $manifestPath = Join-Path $ArtifactRoot "release-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "release-manifest.json is missing from the downloaded candidate."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.repository -ne $Repository -or $manifest.commit -ne "c2bd6b3b81b3f7e75f1211798446870d98a867ff") {
        throw "The candidate manifest has an unexpected repository or source commit."
    }

    $matches = @($manifest.artifacts | Where-Object {
        $_.platform -eq "windows" -and $_.architecture -eq "x64" -and $_.public -eq $true
    })
    if ($matches.Count -ne 2) {
        throw "The candidate must contain exactly one public Windows Agent and one public Windows Client."
    }
    return [ordered]@{ manifest = $manifest; artifacts = $matches }
}

function Test-WindowsArtifacts {
    $candidate = Get-WindowsArtifacts
    $results = @()
    foreach ($artifact in $candidate.artifacts) {
        $path = Join-Path $ArtifactRoot $artifact.filename
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Missing Windows artifact: $($artifact.filename)."
        }
        $file = Get-Item -LiteralPath $path
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($file.Length -ne [int64]$artifact.size -or $hash -ne $artifact.sha256.ToLowerInvariant()) {
            throw "Size or SHA-256 verification failed for $($artifact.filename)."
        }

        $signature = Get-AuthenticodeSignature -FilePath $path
        if ($signature.Status -ne "NotSigned") {
            throw "$($artifact.filename) must be explicitly observed as NotSigned for the v1 policy."
        }

        $attestationPath = Join-Path $EvidenceRoot "$($artifact.filename).attestation.txt"
        Invoke-CheckedCommand -Command "gh" -Arguments @(
            "attestation", "verify", $path, "--repo", $Repository
        ) -OutputPath $attestationPath | Out-Null

        $zoneIdentifier = @"
[ZoneTransfer]
ZoneId=3
ReferrerUrl=https://github.com/$Repository/actions/runs/$RunId
HostUrl=https://github.com/$Repository/actions/runs/$RunId
"@
        Set-Content -LiteralPath $path -Stream Zone.Identifier -Value $zoneIdentifier -Encoding ascii
        $recordedZone = Get-Content -LiteralPath $path -Stream Zone.Identifier -Raw
        if ($recordedZone -notmatch "ZoneId=3") {
            throw "Failed to apply the Internet Zone mark to $($artifact.filename)."
        }

        $results += [ordered]@{
            component = $artifact.component
            filename = $artifact.filename
            path = $path
            size = $file.Length
            sha256 = $hash
            signature_type = $artifact.signature_type
            authenticode_status = $signature.Status.ToString()
            internet_zone_mark = "ZoneId=3"
            attestation_evidence = $attestationPath
        }
    }
    return $results
}

function Save-RuntimeSnapshot {
    param([string]$Name)

    $uninstallRoots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $installedApplications = @(
        $uninstallRoots |
            ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -match "sanad" } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation
    )

    $snapshot = [ordered]@{
        checkpoint = $Name
        captured_at_utc = [DateTime]::UtcNow.ToString("o")
        windows = Get-WindowsIdentity
        defender = Get-DefenderEvidence
        services = @(Get-Service | Where-Object {
            $_.Name -match "sanad" -or $_.DisplayName -match "sanad"
        } | Select-Object Name, DisplayName, Status, StartType)
        processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match "sanad"
        } | Select-Object ProcessName, Id, Path)
        installed_applications = $installedApplications
        sanad_home_exists = Test-Path -LiteralPath (Join-Path $HOME ".sanad")
    }
    Save-JsonEvidence -Value $snapshot -Path (Join-Path $EvidenceRoot "$Name.json")
}

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null

if ($Phase -eq "Prepare") {
    Get-WindowsIdentity | Out-Null
    Get-DefenderEvidence | Out-Null
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI is required. Install it and authenticate before retrying."
    }
    Invoke-CheckedCommand -Command "gh" -Arguments @("auth", "status") | Out-Null

    if (Test-Path -LiteralPath $ArtifactRoot) {
        Remove-Item -LiteralPath $ArtifactRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $ArtifactRoot | Out-Null
    Invoke-CheckedCommand -Command "gh" -Arguments @(
        "run", "download", $RunId.ToString(),
        "--repo", $Repository,
        "--name", "stable-release-candidate",
        "--dir", $ArtifactRoot
    ) | Out-Null

    $verified = Test-WindowsArtifacts
    foreach ($artifact in $verified) {
        Start-MpScan -ScanType CustomScan -ScanPath $artifact.path
    }
    Save-JsonEvidence -Value $verified -Path (Join-Path $EvidenceRoot "verified-windows-artifacts.json")
    Save-RuntimeSnapshot -Name "BeforeInstall"

    $template = @"
# SANAD-12 Windows clean-machine observations

- OS: record Windows 10 or Windows 11 edition/build
- VM or hardware:
- Snapshot identifier before install:
- Candidate run: $RunId
- Candidate commit: c2bd6b3b81b3f7e75f1211798446870d98a867ff

## SmartScreen and Defender

- Agent first-launch UI/result:
- Client installer first-launch UI/result:
- Displayed publisher text:
- SmartScreen action chosen after origin/hash verification:
- Defender scan result:
- Screenshot filenames (do not include credentials or tokens):

## Lifecycle

- Agent `--version` output:
- `service install` result:
- Service status before reboot:
- Service status after reboot:
- Client install and launch result:
- Client uninstall result:
- Agent `service uninstall` result:
- Sanad Home retained after uninstall:
- Errors or unexpected prompts:
"@
    Set-Content -LiteralPath (Join-Path $EvidenceRoot "manual-observations.md") -Value $template -Encoding utf8

    Write-Host "Candidate verified with Defender enabled. Continue interactively from:" -ForegroundColor Green
    $verified | ForEach-Object { Write-Host "  $($_.component): $($_.path)" }
    Write-Host "Do not disable Defender, SmartScreen, or Smart App Control."
    Write-Host "Capture each lifecycle checkpoint with -Phase Capture -Checkpoint <name>."
    exit 0
}

Save-RuntimeSnapshot -Name $Checkpoint
Write-Host "Captured $Checkpoint evidence in $EvidenceRoot." -ForegroundColor Green
