$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

Set-Location "$repoRoot\client"
if (Get-Command fvm -ErrorAction SilentlyContinue) {
    & fvm dart run bin/sanad_client.dart @args
} else {
    & dart run bin/sanad_client.dart @args
}
