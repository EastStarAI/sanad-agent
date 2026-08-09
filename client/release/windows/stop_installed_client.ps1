param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [int]$GraceSeconds = 8
)

$ErrorActionPreference = 'Stop'
$canonicalTarget = [System.IO.Path]::GetFullPath($TargetPath)
$deadline = (Get-Date).AddSeconds($GraceSeconds)

function Get-TargetProcesses {
    Get-CimInstance Win32_Process -Filter "Name = 'sanad-client.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            [string]::Equals(
                [System.IO.Path]::GetFullPath($_.ExecutablePath),
                $canonicalTarget,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
}

while ((Get-Date) -lt $deadline) {
    if (-not @(Get-TargetProcesses).Count) {
        exit 0
    }
    Start-Sleep -Milliseconds 250
}

# Compatibility fallback for clients released before the WinSparkle
# before-quit listener existed. Scope is the exact installed executable path;
# source runs and other installations are never selected by name alone.
foreach ($process in @(Get-TargetProcesses)) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
}

Start-Sleep -Milliseconds 250
if (@(Get-TargetProcesses).Count) {
    exit 1
}
exit 0
