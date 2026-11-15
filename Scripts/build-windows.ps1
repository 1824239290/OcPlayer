[CmdletBinding()]
param(
    [string]$CoreRoot = (Join-Path $PSScriptRoot '..\..\OcPlayer-Core'),
    [string]$KernelRoot = $env:OCP_ERIKA_ROOT,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [string]$LibClangPath = $env:LIBCLANG_PATH,
    [string]$KernelCargoHome = $env:CARGO_HOME,
    [switch]$Offline,
    [switch]$SkipNative
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$coreSource = (Resolve-Path -LiteralPath $CoreRoot).Path
$nativeOutput = Join-Path $workspace "native\OcPlayerCore\$Platform"
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)." }
}
if (!$SkipNative) {
    if (!$KernelRoot) { throw 'Pass -KernelRoot for the HDR-fixed Erika checkout (see docs/core-integration.md).' }
    $kernelSource = (Resolve-Path -LiteralPath $KernelRoot).Path
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$installation) { throw 'Visual Studio C++ Build Tools are required.' }
    $vcvars = Join-Path $installation ('VC\Auxiliary\Build\' + $(if ($Platform -eq 'x64') { 'vcvars64.bat' } else { 'vcvarsamd64_arm64.bat' }))
    $buildEnvironment = & $env:COMSPEC /d /s /c ('"{0}" >nul && set' -f $vcvars)
    if ($LASTEXITCODE -ne 0) { throw 'MSVC environment initialization failed.' }
    foreach ($entry in $buildEnvironment) {
        if ($entry -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
    }
    $target = if ($Platform -eq 'x64') { 'x86_64-pc-windows-msvc' } else { 'aarch64-pc-windows-msvc' }
    $profile = $Configuration.ToLowerInvariant()
    # MSVC's C7 debug-record writer rejects ring's long generated command line
    # under this checkout. Keep dev builds unoptimized without native symbols;
    # managed Debug symbols are still emitted by dotnet.
    if ($Configuration -eq 'Debug') { $env:CARGO_PROFILE_DEV_DEBUG = '0' }
    $cargoOptions = @('--locked', '--target', $target, '--jobs', '2')
    if ($Offline) { $cargoOptions += '--offline' }
    if ($Configuration -eq 'Release') { $cargoOptions += '--release' }
    $coreTarget = Join-Path $workspace 'artifacts\core-target'
    Invoke-Checked cargo (@('build', '--manifest-path', "$coreSource\Cargo.toml", '--target-dir', $coreTarget, '-p', 'ocp-ffi') + $cargoOptions)
    if (!$LibClangPath -or !(Test-Path -LiteralPath (Join-Path $LibClangPath 'libclang.dll'))) { throw 'Pass -LibClangPath containing libclang.dll.' }
    $env:LIBCLANG_PATH = (Resolve-Path -LiteralPath $LibClangPath).Path
    $env:PATH = $env:LIBCLANG_PATH + ';' + $env:PATH
    $env:ERIKA_NATIVE_TARGET = $target
    $env:ERIKA_NATIVE_PROFILE = 'lgpl'
    $kernelTarget = Join-Path $workspace 'artifacts\kernel-target'
    $savedCargoHome = $env:CARGO_HOME
    try {
        if ($KernelCargoHome) { $env:CARGO_HOME = (Resolve-Path -LiteralPath $KernelCargoHome).Path }
        Invoke-Checked cargo (@('build', '--manifest-path', "$kernelSource\Cargo.toml", '--target-dir', $kernelTarget, '-p', 'erika_capi', '--no-default-features', '--features', 'libass') + $cargoOptions)
    } finally { $env:CARGO_HOME = $savedCargoHome }
    New-Item -ItemType Directory -Force -Path $nativeOutput | Out-Null
    Copy-Item -LiteralPath "$coreTarget\$target\$profile\ocp_ffi.dll" -Destination $nativeOutput
    Copy-Item -LiteralPath "$kernelTarget\$target\$profile\erika_capi.dll" -Destination $nativeOutput
    [ordered]@{
        coreCommit = (& git -C $coreSource rev-parse HEAD).Trim()
        kernelRoot = $kernelSource
        target = $target
        configuration = $Configuration
        coreSha256 = (Get-FileHash -LiteralPath "$nativeOutput\ocp_ffi.dll").Hash
        erikaSha256 = (Get-FileHash -LiteralPath "$nativeOutput\erika_capi.dll").Hash
    } | ConvertTo-Json | Set-Content -LiteralPath "$nativeOutput\build-receipt.json" -Encoding utf8
}
Invoke-Checked dotnet @('build', "$workspace\OcPlayer.sln", '-c', $Configuration, "-p:Platform=$Platform", "-p:OcpCoreRoot=$coreSource\", "-p:OcpNativeDirectory=$nativeOutput\")
