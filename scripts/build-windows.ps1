[CmdletBinding()]
param(
    [string]$CoreRoot = (Join-Path $PSScriptRoot '..\core'),
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
$windowsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\windows'))
$parameters = @{} + $PSBoundParameters
$parameters.CoreRoot = $CoreRoot
$parameters.KernelRoot = if ($KernelRoot) { $KernelRoot } else { Join-Path $windowsRoot 'artifacts\liberika-v0.3.7' }
foreach ($pathName in @('CoreRoot', 'KernelRoot', 'LibClangPath', 'KernelCargoHome')) {
    if ($parameters[$pathName]) { $parameters[$pathName] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($parameters[$pathName]) }
}
Push-Location $windowsRoot
try { & (Join-Path $windowsRoot 'Scripts\build-windows.ps1') @parameters }
finally { Pop-Location }
