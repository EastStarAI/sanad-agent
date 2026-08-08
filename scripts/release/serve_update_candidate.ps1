param(
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [int]$Port = 58168
)

$ErrorActionPreference = 'Stop'
$rootPath = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path $rootPath -PathType Container)) {
    throw "Candidate root does not exist: $rootPath"
}
if ($Port -lt 1024 -or $Port -gt 65535) {
    throw 'Port must be between 1024 and 65535.'
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "Serving isolated update candidate on http://127.0.0.1:$Port/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $name = [System.IO.Path]::GetFileName(
                $context.Request.Url.AbsolutePath
            )
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = 'appcast.xml'
            }
            $path = Join-Path $rootPath $name
            if (-not (Test-Path $path -PathType Leaf)) {
                $context.Response.StatusCode = 404
                continue
            }

            $bytes = [System.IO.File]::ReadAllBytes($path)
            $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
            $contentType = switch ($extension) {
                '.xml' { 'application/xml; charset=utf-8' }
                '.json' { 'application/json; charset=utf-8' }
                '.exe' { 'application/octet-stream' }
                default { 'application/octet-stream' }
            }
            $context.Response.StatusCode = 200
            $context.Response.ContentType = $contentType
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.Headers['Cache-Control'] = 'no-store'
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $context.Response.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
