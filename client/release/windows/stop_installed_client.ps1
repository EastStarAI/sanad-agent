param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [ValidateRange(0, 60)]
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

function Test-FileIsWritable {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $true }
    try {
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ($stream) {
            $stream.Close()
            $stream.Dispose()
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Test-DirectoryFilesWritable {
    param([string]$DirectoryPath)
    if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) { return $true }
    $files = Get-ChildItem -LiteralPath $DirectoryPath -Include "*.exe", "*.dll" -File -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if (-not (Test-FileIsWritable -FilePath $file.FullName)) {
            return $false
        }
    }
    return $true
}

$targetDir = [System.IO.Path]::GetDirectoryName($canonicalTarget)

while ((Get-Date) -lt $deadline) {
    if (-not @(Get-TargetProcesses).Count) {
        if (Test-DirectoryFilesWritable -DirectoryPath $targetDir) {
            exit 0
        }
    }
    Start-Sleep -Milliseconds 250
}

# Compatibility fallback for clients released before the WinSparkle
# before-quit listener existed. Scope is the exact installed executable path;
# source runs and other installations are never selected by name alone.
foreach ($process in @(Get-TargetProcesses)) {
    try {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    } catch {}
}

# Wait after force stop for process termination and handle release
$forceDeadline = (Get-Date).AddSeconds(3)
while ((Get-Date) -lt $forceDeadline) {
    if (-not @(Get-TargetProcesses).Count) {
        if (Test-DirectoryFilesWritable -DirectoryPath $targetDir) {
            exit 0
        }
    }
    Start-Sleep -Milliseconds 250
}

if (@(Get-TargetProcesses).Count -or -not (Test-DirectoryFilesWritable -DirectoryPath $targetDir)) {
    exit 1
}
exit 0
