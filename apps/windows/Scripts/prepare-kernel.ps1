[CmdletBinding()]
param(
    [string]$KernelRoot = (Join-Path $PSScriptRoot '..\artifacts\liberika-v0.3.8'),
    [ValidateSet('x64','ARM64')][string]$Platform = 'x64',
    [string]$NativeArchiveCache,
    [string]$KernelCargoHome = $env:CARGO_HOME,
    [int]$Jobs = 8,
    [switch]$PrepareOnly,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pin = Get-Content -LiteralPath "$workspace\Config\Kernel.version.json" -Raw | ConvertFrom-Json
$source = [IO.Path]::GetFullPath($KernelRoot)
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)." }
}
if (!(Test-Path -LiteralPath (Join-Path $source '.git'))) {
    if (Test-Path -LiteralPath $source) { throw "Choose a new kernel source directory: $source" }
    Invoke-Checked git @('clone','--depth','1','--filter=blob:none','--no-checkout','--branch',$pin.tag,$pin.repository,$source)
    Invoke-Checked git @('-C',$source,'sparse-checkout','init','--no-cone')
    # Omit website/package artwork; keep native crates, assets, examples and patches.
    @('/*','!/packages/','!/readme/','!/docs/') | & git -C $source sparse-checkout set --no-cone --stdin
    if ($LASTEXITCODE -ne 0) { throw 'Kernel sparse checkout configuration failed.' }
    Invoke-Checked git @('-C',$source,'checkout','--detach',$pin.tag)
}
if ((& git -C $source rev-parse HEAD).Trim() -ne $pin.commit) { throw "Expected liberika $($pin.tag) commit $($pin.commit)." }
$patch = Join-Path $PSScriptRoot 'patches\liberika-v0.3.8-windows.patch'
$savedErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    & git -C $source apply --reverse --check $patch 2>$null
    $patched = $LASTEXITCODE -eq 0
} finally { $ErrorActionPreference = $savedErrorActionPreference }
if (!$patched) {
    Invoke-Checked git @('-C',$source,'apply','--check',$patch)
    Invoke-Checked git @('-C',$source,'apply',$patch)
}
if ($NativeArchiveCache) {
    $cache = Join-Path $source 'third_party\cache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    Get-ChildItem -LiteralPath $NativeArchiveCache -File | ForEach-Object {
        if (!(Test-Path -LiteralPath (Join-Path $cache $_.Name))) { Copy-Item -LiteralPath $_.FullName -Destination $cache }
    }
}
if (!$PrepareOnly) {
    $target = if ($Platform -eq 'x64') { 'x86_64-pc-windows-msvc' } else { 'aarch64-pc-windows-msvc' }
    $savedCargoHome = $env:CARGO_HOME
    $savedTemp = $env:TEMP; $savedTmp = $env:TMP
    try {
        if ($KernelCargoHome) { $env:CARGO_HOME = (Resolve-Path -LiteralPath $KernelCargoHome).Path }
        $env:TEMP = Join-Path $workspace 'artifacts\kernel-build-temp'; $env:TMP = $env:TEMP
        New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
        # Avoid the MSVC C7 writer issue in ring while building the dependency tool.
        $env:CARGO_PROFILE_DEV_DEBUG = '0'
        $cargoArgs = @('run','--locked','--manifest-path',"$source\Cargo.toml",'--target-dir',"$workspace\artifacts\kernel-target",'-p','xtask')
        if ($Offline) { $cargoArgs += '--offline' }
        Invoke-Checked cargo ($cargoArgs + @('--','deps','build','--all','--profile','lgpl','--target',$target,'--jobs',"$Jobs"))
    } finally { $env:CARGO_HOME = $savedCargoHome; $env:TEMP = $savedTemp; $env:TMP = $savedTmp }
}
Write-Output $source
