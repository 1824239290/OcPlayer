[CmdletBinding()]
param(
    [string]$CoreRoot = (Join-Path $PSScriptRoot '..\..\..\core'),
    [string]$KernelRoot = $env:OCP_ERIKA_ROOT,
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [string]$LibClangPath = $env:LIBCLANG_PATH,
    [string]$KernelCargoHome = $env:CARGO_HOME,
    [switch]$Offline,
    [switch]$SkipNative,
    [switch]$SkipManaged
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
    if (!$KernelRoot) { throw 'Pass -KernelRoot for liberika v0.3.8 prepared with Scripts/prepare-kernel.ps1 (see docs/core-integration.md).' }
    $kernelSource = (Resolve-Path -LiteralPath $KernelRoot).Path
    $pin = Get-Content -LiteralPath (Join-Path $workspace 'Config\Kernel.version.json') -Raw | ConvertFrom-Json
    $kernelCommit = (& git -C $kernelSource rev-parse HEAD).Trim()
    if ($kernelCommit -ne $pin.commit) { throw "Expected liberika $($pin.tag) at $($pin.commit). Run Scripts/prepare-kernel.ps1." }
    $kernelPatch = Join-Path $PSScriptRoot 'patches\liberika-v0.3.8-windows.patch'
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & git -C $kernelSource apply --reverse --check $kernelPatch 2>$null
        $kernelPatchApplied = $LASTEXITCODE -eq 0
    } finally { $ErrorActionPreference = $savedErrorActionPreference }
    if (!$kernelPatchApplied) {
        Invoke-Checked git @('-C', $kernelSource, 'apply', '--check', $kernelPatch)
        Invoke-Checked git @('-C', $kernelSource, 'apply', $kernelPatch)
    }
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
    $savedBindgenArgs = $env:BINDGEN_EXTRA_CLANG_ARGS
    try {
        if ($KernelCargoHome) { $env:CARGO_HOME = (Resolve-Path -LiteralPath $KernelCargoHome).Path }
        # MSVC STL headers can require a newer Clang than the libclang installed on CI or dev machines;
        # bindgen only parses headers while MSVC cl.exe still compiles the C/C++ sources.
        $stlMismatchArg = '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH'
        if ([string]::IsNullOrWhiteSpace($env:BINDGEN_EXTRA_CLANG_ARGS)) {
            $env:BINDGEN_EXTRA_CLANG_ARGS = $stlMismatchArg
        } elseif ($env:BINDGEN_EXTRA_CLANG_ARGS -notmatch '(^|\s)-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH(=|\s|$)') {
            $env:BINDGEN_EXTRA_CLANG_ARGS = "$($env:BINDGEN_EXTRA_CLANG_ARGS) $stlMismatchArg"
        }
        Invoke-Checked cargo (@('build', '--manifest-path', "$kernelSource\Cargo.toml", '--target-dir', $kernelTarget, '-p', 'erika_capi', '--no-default-features', '--features', 'libass,embedded-fallback-font,artcnn-r8f64') + $cargoOptions)
    } finally {
        $env:CARGO_HOME = $savedCargoHome
        $env:BINDGEN_EXTRA_CLANG_ARGS = $savedBindgenArgs
    }
    New-Item -ItemType Directory -Force -Path $nativeOutput | Out-Null
    Copy-Item -LiteralPath "$coreTarget\$target\$profile\ocp_ffi.dll" -Destination $nativeOutput
    Copy-Item -LiteralPath "$kernelTarget\$target\$profile\erika_capi.dll" -Destination $nativeOutput
    [ordered]@{
        coreCommit = (& git -C $coreSource rev-parse HEAD).Trim()
        kernelRoot = $kernelSource
        kernelRepository = $pin.repository
        kernelTag = $pin.tag
        kernelCommit = $kernelCommit
        kernelFeatures = @('libass','embedded-fallback-font','artcnn-r8f64')
        kernelVersion = ([regex]::Match([IO.File]::ReadAllText((Join-Path $kernelSource 'Cargo.toml')), '(?ms)^\[workspace\.package\].*?^version\s*=\s*"([^"]+)"')).Groups[1].Value
        target = $target
        configuration = $Configuration
        coreSha256 = (Get-FileHash -LiteralPath "$nativeOutput\ocp_ffi.dll").Hash
        erikaSha256 = (Get-FileHash -LiteralPath "$nativeOutput\erika_capi.dll").Hash
        kernelPatches = @([ordered]@{
            path = 'Scripts/patches/liberika-v0.3.8-windows.patch'
            sha256 = (Get-FileHash -LiteralPath $kernelPatch).Hash
        })
    } | ConvertTo-Json | Set-Content -LiteralPath "$nativeOutput\build-receipt.json" -Encoding utf8
    $metadataPath = Join-Path $workspace 'artifacts\core-license-metadata.json'
    $metadata = & cargo metadata --locked --manifest-path "$coreSource\Cargo.toml" --format-version 1 --filter-platform $target
    if ($LASTEXITCODE -ne 0) { throw 'Core dependency metadata failed.' }
    [IO.File]::WriteAllText($metadataPath, ($metadata -join "`n"))
    $nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
    Invoke-Checked dotnet @('restore', "$workspace\src\OcPlayer.Windows\OcPlayer.Windows.csproj", "-p:Platform=$Platform", "-p:OcpCoreRoot=$coreSource\")
    & (Join-Path $PSScriptRoot 'generate-license-catalog.ps1') -Metadata $metadataPath -Kernel $kernelSource -Nuget $nugetRoot -Output "$workspace\src\OcPlayer.Windows\Services\OpenSourceCatalog.Generated.cs"
}
if (!$SkipManaged) {
    Invoke-Checked dotnet @('build', "$workspace\OcPlayer.sln", '-c', $Configuration, "-p:Platform=$Platform", "-p:OcpCoreRoot=$coreSource\", "-p:OcpNativeDirectory=$nativeOutput\")
}
