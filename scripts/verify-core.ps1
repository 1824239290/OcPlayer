[CmdletBinding()]
param(
    [string]$Python = 'python',
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\verification\windows-core'),
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$coreRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\core'))
$parameters = @{} + $PSBoundParameters
$parameters.Configuration = $Configuration
$parameters.OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if ($parameters.Python -match '[/\\]') { $parameters.Python = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($parameters.Python) }
Push-Location $coreRoot
try { & (Join-Path $coreRoot 'Scripts\verify-windows.ps1') @parameters }
finally { Pop-Location }
