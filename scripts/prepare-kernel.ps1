[CmdletBinding()]
param(
    [string]$KernelRoot,
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [string]$NativeArchiveCache,
    [string]$KernelCargoHome = $env:CARGO_HOME,
    [int]$Jobs = 8,
    [switch]$PrepareOnly,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$windowsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\windows'))
$parameters = @{} + $PSBoundParameters
foreach ($pathName in @('KernelRoot', 'NativeArchiveCache', 'KernelCargoHome')) {
    if ($parameters[$pathName]) { $parameters[$pathName] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($parameters[$pathName]) }
}
Push-Location $windowsRoot
try { & (Join-Path $windowsRoot 'Scripts\prepare-kernel.ps1') @parameters }
finally { Pop-Location }
