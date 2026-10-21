$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

$clientScript = Join-Path $repoRoot "client\bin\sanad_client.dart"

if (Get-Command fvm -ErrorAction SilentlyContinue) {
    & fvm dart run $clientScript @args
} else {
    & dart run $clientScript @args
}
