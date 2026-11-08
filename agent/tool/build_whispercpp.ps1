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

    cl.exe /nologo /O2 /LD /I "$WhisperSrc\include" /I "$WhisperSrc\ggml\include" `
        "$here\native\whispercpp\sanad_whisper.c" `
        /link /LIBPATH:"$WhisperSrc\build\bin\Release" `
        whisper.lib ggml.lib ggml-base.lib ggml-cpu.lib `
        /OUT:"$out\sanad_whisper.dll"
    if ($LASTEXITCODE -ne 0) { throw "shim build failed" }

    $libs = @("whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll")
    foreach ($lib in $libs) {
        $src = Join-Path "$WhisperSrc\build\bin\Release" $lib
        if (Test-Path $src) { Copy-Item -Force $src $out }
    }

    Write-Host "built: $out\sanad_whisper.dll"
}
finally {
    Pop-Location
}
