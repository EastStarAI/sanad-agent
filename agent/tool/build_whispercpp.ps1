# Builds the whisper.cpp shim for one Windows CPU architecture.
#
# Usage:
#   pwsh -File tool/build_whispercpp.ps1 <whisper.cpp-source> [output-dir]
#       [-Arch x64|arm64]
#
# Requirements: CMake + a Visual Studio C++ toolchain (`cl.exe`). Run from a
# "Developer PowerShell" or after `vcvarsall.bat` so cl.exe is on PATH.
#
# The daemon loads sanad_whisper.dll through dart:ffi; whisper.dll and the
# ggml-*.dll backends must sit beside it. Metal is macOS-only, so Windows uses
# the CPU backend (a CUDA/Vulkan backend can be added later the same way).
#
# The architecture is explicit because the output directory is
# architecture-qualified (`native/windows-x64`, `native/windows-arm64`, …). A
# cross-architecture build is refused: the MSVC toolchain here targets the host,
# so publishing the other slice under this directory name would be a lie the
# daemon can only discover at load time.
param(
    [Parameter(Mandatory = $true)][string]$WhisperSrc,
    [string]$OutDir = "",
    [string]$Arch = ""
)

$ErrorActionPreference = "Stop"

switch -Regex ($env:PROCESSOR_ARCHITECTURE) {
    '^(AMD64|x86)$' { $hostArch = "x64" }
    '^ARM64$' { $hostArch = "arm64" }
    default { throw "Unsupported host CPU: $env:PROCESSOR_ARCHITECTURE" }
}
if ([string]::IsNullOrEmpty($Arch)) { $Arch = $hostArch }
if ($Arch -ne $hostArch) {
    throw "Refusing to build $Arch on a $hostArch host: the artifact would not run on the machines its directory name claims."
}
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = "native/windows-$Arch" }

# Make the source path absolute before pushing into it: a relative path is
# resolved twice once the working directory changes, which silently points the
# include directories at whisper.cpp\whisper.cpp and breaks the shim build.
$WhisperSrc = (Resolve-Path -LiteralPath $WhisperSrc).Path
$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$out = Join-Path $here $OutDir

Push-Location $WhisperSrc
try {
    # A restored cache, or a developer's earlier build, can hold a CMakeCache
    # configured for a different generator platform. CMake then refuses to
    # reconfigure ("does not match the platform used previously") instead of
    # reusing the tree, which fails the build on a warm cache. Discard such a
    # tree so the requested architecture always wins.
    $buildDir = Join-Path $WhisperSrc "build"
    $cacheFile = Join-Path $buildDir "CMakeCache.txt"
    if (Test-Path -LiteralPath $cacheFile) {
        $cached = Select-String -LiteralPath $cacheFile -Pattern '^CMAKE_GENERATOR_PLATFORM:[^=]*=(.*)$' |
            Select-Object -First 1
        $cachedPlatform = if ($null -ne $cached) { $cached.Matches[0].Groups[1].Value.Trim() } else { "" }
        if ($cachedPlatform -ne $Arch) {
            Write-Host "Discarding a CMake cache configured for platform '$cachedPlatform' (requested '$Arch')."
            Remove-Item -Recurse -Force -LiteralPath $buildDir
        }
    }
    cmake -B build -DCMAKE_BUILD_TYPE=Release `
        -DBUILD_SHARED_LIBS=ON `
        -DGGML_METAL=OFF `
        -DWHISPER_BUILD_TESTS=OFF `
        -DWHISPER_BUILD_EXAMPLES=OFF -A $Arch
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
    cmake --build build --config Release
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

    New-Item -ItemType Directory -Force -Path $out | Out-Null

    # MSVC's import libraries and DLLs do not share one directory (for example
    # build\src\Release\whisper.lib versus build\bin\Release\whisper.dll), and
    # the layout differs per generator. Search the build tree once instead of
    # hardcoding paths.
    function Find-BuildFile([string]$name) {
        Get-ChildItem -Path "$WhisperSrc\build" -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }

    $importLibs = @("whisper.lib", "ggml.lib", "ggml-base.lib", "ggml-cpu.lib") |
        ForEach-Object { Find-BuildFile $_ }
    if ($importLibs -contains $null -or $importLibs.Count -ne 4) {
        throw "missing import libraries: $($importLibs -join ', ')"
    }

    $includeArgs = @("/I", "$WhisperSrc\include", "/I", "$WhisperSrc\ggml\include")
    $linkArgs = $importLibs + @("/OUT:$out\sanad_whisper.dll")

    cl.exe /nologo /O2 /LD @includeArgs "$here\native\whispercpp\sanad_whisper.c" /link @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "shim build failed" }

    foreach ($lib in @("whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")) {
        $src = Find-BuildFile $lib
        if ($src) { Copy-Item -Force $src $out }
    }

    Write-Host "built: $out\sanad_whisper.dll (windows-$Arch)"
}
finally {
    Pop-Location
}
