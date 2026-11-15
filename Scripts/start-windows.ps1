param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug',
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [switch]$Demo,
    [switch]$NavigationPreview,
    [switch]$HeaderActionsPreview,
    [string]$BuildDirectory,
    [string]$Open,
    [string]$DataDirectory
)

$ErrorActionPreference = 'Stop'
$workspaceDirectory = Split-Path -Parent $PSScriptRoot
if (-not $DataDirectory) { $DataDirectory = Join-Path $workspaceDirectory 'artifacts\app-data' }
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $workspaceDirectory "src\OcPlayer.Windows\bin\$Platform\$Configuration\net10.0-windows10.0.26100.0" }
$appPath = [IO.Path]::GetFullPath((Join-Path $BuildDirectory 'OcPlayer.Windows.exe'))
if (-not (Test-Path -LiteralPath $appPath)) {
    throw "Application build missing. Run dotnet build OcPlayer.sln -c $Configuration -p:Platform=$Platform first."
}

$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$runtimeCandidates = @(
    [Environment]::GetEnvironmentVariable("DOTNET_ROOT_$($Platform.ToUpperInvariant())"),
    $env:DOTNET_ROOT,
    $(if ($dotnetCommand) { Split-Path -Parent $dotnetCommand.Source }),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'),
    (Join-Path $env:ProgramFiles 'dotnet')
)
$runtimeDirectory = $runtimeCandidates | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'dotnet.exe')) } | Select-Object -First 1
if (-not $runtimeDirectory) { throw 'Cannot locate .NET 10. Install the SDK or set DOTNET_ROOT.' }

$launch = [Diagnostics.ProcessStartInfo]::new($appPath)
$launch.UseShellExecute = $false
$launch.CreateNoWindow = $true
$launch.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$launch.WorkingDirectory = $workspaceDirectory
$launch.Environment['DOTNET_ROOT'] = $runtimeDirectory
$launch.Environment["DOTNET_ROOT_$($Platform.ToUpperInvariant())"] = $runtimeDirectory
$launch.Environment['OCP_DATA_DIRECTORY'] = $DataDirectory
if ($Demo) { $launch.ArgumentList.Add('--demo-route=home') }
if ($NavigationPreview) { $launch.ArgumentList.Add('--nav-preview') }
if ($HeaderActionsPreview) { $launch.ArgumentList.Add('--header-actions-preview') }
if ($Open) { $launch.ArgumentList.Add("--open=$Open") }
$launchedApp = [Diagnostics.Process]::Start($launch)
Write-Output "Started OcPlayer (PID $($launchedApp.Id))."
