# Builds the whisper.cpp shim for Windows (x64 or arm64) into native/windows.
#
# Usage:
#   pwsh -File tool/build_whispercpp.ps1 <whisper.cpp-source> [output-dir]
#
# Requirements: CMake + a Visual Studio C++ toolchain (`cl.exe`). Run from a
# "Developer PowerShell" or after `vcvarsall.bat` so cl.exe is on PATH.
#
# The daemon loads sanad_whisper.dll through dart:ffi; whisper.dll and the
# ggml-*.dll backends must sit beside it. Metal is macOS-only, so Windows uses
# the CPU backend (a CUDA/Vulkan backend can be added later the same way).
param(
    [Parameter(Mandatory = $true)][string]$WhisperSrc,
    [string]$OutDir = "native/windows"
)

$ErrorActionPreference = "Stop"
# Make the source path absolute before pushing into it: a relative path is
# resolved twice once the working directory changes, which silently points the
# include directories at whisper.cpp\whisper.cpp and breaks the shim build.
$WhisperSrc = (Resolve-Path -LiteralPath $WhisperSrc).Path
$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$out = Join-Path $here $OutDir

Push-Location $WhisperSrc
try {
    cmake -B build -DCMAKE_BUILD_TYPE=Release `
        -DBUILD_SHARED_LIBS=ON `
        -DGGML_METAL=OFF `
        -DWHISPER_BUILD_TESTS=OFF `
        -DWHISPER_BUILD_EXAMPLES=OFF
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

    Write-Host "built: $out\sanad_whisper.dll"
}
finally {
    Pop-Location
}
