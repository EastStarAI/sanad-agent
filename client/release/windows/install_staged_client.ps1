param(
    [Parameter(Mandatory = $true)]
    [string]$TargetDirectory,
    [Parameter(Mandatory = $true)]
    [string]$StagedDirectory
)

$ErrorActionPreference = 'Stop'
$target = [System.IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
$staged = [System.IO.Path]::GetFullPath($StagedDirectory).TrimEnd('\')
$backup = Join-Path $target '.sanad-install-backup'

function Get-FileDigest {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ManagedPayload {
    param([string]$Directory)

    $items = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    $executable = Join-Path $Directory 'sanad-client.exe'
    if (Test-Path -LiteralPath $executable -PathType Leaf) {
        $items.Add((Get-Item -LiteralPath $executable))
    }
    foreach ($dll in @(Get-ChildItem -LiteralPath $Directory -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
        $items.Add($dll)
    }
    $data = Join-Path $Directory 'data'
    if (Test-Path -LiteralPath $data -PathType Container) {
        $items.Add((Get-Item -LiteralPath $data))
    }
    $items
}

if (-not (Test-Path -LiteralPath $staged -PathType Container)) {
    throw 'The staged client payload does not exist.'
}

$stagedExecutable = Join-Path $staged 'sanad-client.exe'
$stagedDlls = @(Get-ChildItem -LiteralPath $staged -Filter '*.dll' -File -ErrorAction Stop)
$stagedData = Join-Path $staged 'data'
if (-not (Test-Path -LiteralPath $stagedExecutable -PathType Leaf) -or
    (Get-Item -LiteralPath $stagedExecutable).Length -le 0 -or
    $stagedDlls.Count -eq 0 -or
    @($stagedDlls | Where-Object Length -le 0).Count -ne 0 -or
    -not (Test-Path -LiteralPath $stagedData -PathType Container)) {
    throw 'The staged client payload is incomplete.'
}

$expectedDigests = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $staged -File -Recurse -ErrorAction Stop)) {
    $relativePath = $file.FullName.Substring($staged.Length + 1)
    $expectedDigests[$relativePath] = Get-FileDigest -Path $file.FullName
}

if (Test-Path -LiteralPath $backup) {
    throw "A previous installer backup still exists at '$backup'."
}
New-Item -ItemType Directory -Path $target -Force | Out-Null
New-Item -ItemType Directory -Path $backup | Out-Null

$installedNames = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($item in @(Get-ManagedPayload -Directory $target)) {
        Move-Item -LiteralPath $item.FullName -Destination (Join-Path $backup $item.Name)
    }

    foreach ($item in @(Get-ManagedPayload -Directory $staged)) {
        Move-Item -LiteralPath $item.FullName -Destination (Join-Path $target $item.Name)
        $installedNames.Add($item.Name)
    }

    foreach ($entry in $expectedDigests.GetEnumerator()) {
        $installedPath = Join-Path $target $entry.Key
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf) -or
            (Get-FileDigest -Path $installedPath) -ne $entry.Value) {
            throw "Installed payload verification failed for '$($entry.Key)'."
        }
    }
} catch {
    $replacementError = $_
    foreach ($name in $installedNames) {
        $installedPath = Join-Path $target $name
        if (Test-Path -LiteralPath $installedPath) {
            Remove-Item -LiteralPath $installedPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (Test-Path -LiteralPath $backup) {
        foreach ($item in @(Get-ChildItem -LiteralPath $backup -Force)) {
            $restorePath = Join-Path $target $item.Name
            if (-not (Test-Path -LiteralPath $restorePath)) {
                Move-Item -LiteralPath $item.FullName -Destination $restorePath -ErrorAction SilentlyContinue
            }
        }
    }
    if ((Test-Path -LiteralPath $backup) -and
        @(Get-ChildItem -LiteralPath $backup -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
    Write-Error "Client payload replacement failed and rollback was attempted: $($replacementError.Exception.Message)"
    exit 1
}

# Cleanup happens only after the installed payload passed complete hash
# verification. Cleanup failure must not roll back a valid installation.
Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath $staged)) {
    Write-Error 'The new client payload is valid, but installer cleanup did not complete.'
    exit 1
}
exit 0
