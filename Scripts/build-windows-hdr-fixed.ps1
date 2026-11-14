[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$KernelRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$VcVarsPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    [string]$LibClangPath = $env:LIBCLANG_PATH,
    [string]$CargoCacheRoot = $env:CARGO_HOME,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows x64 is required.' }
$repoRoot = Split-Path -Parent $PSScriptRoot
$kernelBase = 'd9334c6f8dcc87d4131d056ef4692f643b231c6c'
$patch = Join-Path $repoRoot 'patches\liberika\d9334c6-windows-hdr.patch'
$kernelSource = (Resolve-Path -LiteralPath $KernelRoot).Path
$buildOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $buildOutput) { throw 'Choose a new output directory; existing output is never overwritten.' }
if (!(Test-Path -LiteralPath $patch -PathType Leaf)) { throw "Missing patch: $patch" }
$nativeDist = Join-Path $kernelSource 'third_party\dist'
$ffmpegHeader = Join-Path $nativeDist 'x86_64-pc-windows-msvc\lgpl\ffmpeg\include\libavformat\avformat.h'
if (!(Test-Path -LiteralPath $ffmpegHeader -PathType Leaf)) { throw 'The kernel checkout must have its compatible bundled Windows x64 LGPL native dependencies.' }
$availableBase = & git -c "safe.directory=$kernelSource" -C $kernelSource rev-parse "$kernelBase^{commit}"
if ($LASTEXITCODE -ne 0 -or $availableBase.Trim() -ne $kernelBase) { throw 'The required native kernel base is unavailable.' }
if (!$PrepareOnly) {
    if (!(Test-Path -LiteralPath $VcVarsPath -PathType Leaf)) { throw 'Pass -VcVarsPath for the MSVC x64 environment script.' }
    if (!$LibClangPath -or !(Test-Path -LiteralPath (Join-Path $LibClangPath 'libclang.dll') -PathType Leaf)) { throw 'Pass -LibClangPath for the existing LLVM directory containing libclang.dll.' }
}
New-Item -ItemType Directory -Path $buildOutput | Out-Null
$stagedSource = Join-Path $buildOutput 'KernelSource'
& git -c "safe.directory=$kernelSource" clone --local --no-hardlinks --no-checkout -- $kernelSource $stagedSource
if ($LASTEXITCODE -ne 0) { throw 'Native kernel clone failed.' }
& git -C $stagedSource checkout --detach $kernelBase
if ($LASTEXITCODE -ne 0) { throw 'Native kernel base checkout failed.' }
& git -C $stagedSource apply --check $patch
if ($LASTEXITCODE -ne 0) { throw 'Versioned Windows HDR patch check failed.' }
& git -C $stagedSource apply $patch
if ($LASTEXITCODE -ne 0) { throw 'Versioned Windows HDR patch application failed.' }
# Reuse the existing native dependencies without copying them or changing the input checkout.
New-Item -ItemType Junction -Path (Join-Path $stagedSource 'third_party\dist') -Target $nativeDist | Out-Null
$receipt = [ordered]@{
    coreCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
    kernelBase = $kernelBase
    kernelVersion = 'v0.1.7+windows.hdr.dev'
    patchSha256 = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash
    architecture = 'x86_64-pc-windows-msvc'
    source = $stagedSource
    preparedOnly = [bool]$PrepareOnly
}
if ($PrepareOnly) {
    $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $buildOutput 'build-receipt.json') -Encoding utf8
    Write-Output $stagedSource
    return
}
$buildEnvironment = & $env:COMSPEC /d /s /c ('"' + $VcVarsPath + '" >nul && set')
if ($LASTEXITCODE -ne 0) { throw 'MSVC environment initialization failed.' }
foreach ($entry in $buildEnvironment) {
    if ($entry -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    }
}
$env:LIBCLANG_PATH = (Resolve-Path -LiteralPath $LibClangPath).Path
$env:PATH = $env:LIBCLANG_PATH + ';' + $env:PATH
if ($CargoCacheRoot) { $env:CARGO_HOME = (Resolve-Path -LiteralPath $CargoCacheRoot).Path }
$env:ERIKA_NATIVE_TARGET = 'x86_64-pc-windows-msvc'
$env:ERIKA_NATIVE_PROFILE = 'lgpl'
$targetDirectory = Join-Path $buildOutput 'KernelTarget'
Push-Location -LiteralPath $stagedSource
try {
    & cargo test --locked --target x86_64-pc-windows-msvc --target-dir $targetDirectory -p erika --no-default-features --lib renderer::d3d11::tests -- --nocapture 2>&1 | Tee-Object -FilePath (Join-Path $buildOutput 'd3d11-tests.log')
    if ($LASTEXITCODE -ne 0) { throw 'D3D11 regression tests failed.' }
    & cargo build --locked --target x86_64-pc-windows-msvc --target-dir $targetDirectory -p windows_native_demo 2>&1 | Tee-Object -FilePath (Join-Path $buildOutput 'kernel-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Windows native demo build failed.' }
} finally {
    Pop-Location
}
$binary = Join-Path $targetDirectory 'x86_64-pc-windows-msvc\debug\windows_native_demo.exe'
$receipt.binarySha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
$receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $buildOutput 'build-receipt.json') -Encoding utf8
Write-Output $binary
