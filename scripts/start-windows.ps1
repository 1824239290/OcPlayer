[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [switch]$Demo,
    [switch]$NavigationPreview,
    [switch]$HeaderActionsPreview,
    [switch]$DetailControlsPreview,
    [string]$BuildDirectory,
    [string]$Open,
    [string]$DataDirectory,
    [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
$windowsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\windows'))
$parameters = @{} + $PSBoundParameters
foreach ($pathName in @('BuildDirectory', 'DataDirectory')) {
    if ($parameters[$pathName]) { $parameters[$pathName] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($parameters[$pathName]) }
}
if ($parameters.Open -and ![Uri]::IsWellFormedUriString($parameters.Open, [UriKind]::Absolute)) {
    $parameters.Open = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($parameters.Open)
}
Push-Location $windowsRoot
try { & (Join-Path $windowsRoot 'Scripts\start-windows.ps1') @parameters }
finally { Pop-Location }
