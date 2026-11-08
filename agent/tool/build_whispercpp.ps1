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

    # MSVC puts import libraries under build\lib\Release and DLLs under
    # build\bin\Release; search both so the link step does not depend on the
    # generator's layout.
    $includeArgs = @("/I", "$WhisperSrc\include", "/I", "$WhisperSrc\ggml\include")
    $libDirs = @("$WhisperSrc\build\bin\Release", "$WhisperSrc\build\lib\Release")
    $linkArgs = @()
    foreach ($dir in $libDirs) {
        if (Test-Path $dir) { $linkArgs += "/LIBPATH:$dir" }
    }
    $linkArgs += @("whisper.lib", "ggml.lib", "ggml-base.lib", "ggml-cpu.lib", "/OUT:$out\sanad_whisper.dll")

    cl.exe /nologo /O2 /LD @includeArgs "$here\native\whispercpp\sanad_whisper.c" /link @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "shim build failed" }

    $libs = @("whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")
    foreach ($dir in $libDirs) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($lib in $libs) {
            $src = Join-Path $dir $lib
            if (Test-Path $src) { Copy-Item -Force $src $out }
        }
    }

    Write-Host "built: $out\sanad_whisper.dll"
}
finally {
    Pop-Location
}
