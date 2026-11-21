[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')][string]$Version = '1.0.0',
    [string]$CoreRoot,
    [string]$VcRuntimeDirectory,
    [string]$OutputDirectory,
    [string]$InnoSetupCompiler,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipPublish
)
$ErrorActionPreference = 'Stop'
$windowsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\apps\windows'))
if (!$CoreRoot) { $CoreRoot = Join-Path $PSScriptRoot '..\core' }
$parameters = @{} + $PSBoundParameters
$parameters.CoreRoot = $CoreRoot
foreach ($pathName in @('CoreRoot', 'VcRuntimeDirectory', 'OutputDirectory', 'InnoSetupCompiler')) {
    if ($parameters[$pathName]) { $parameters[$pathName] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($parameters[$pathName]) }
}
Push-Location $windowsRoot
try { & (Join-Path $windowsRoot 'Scripts\package-windows.ps1') @parameters }
finally { Pop-Location }
