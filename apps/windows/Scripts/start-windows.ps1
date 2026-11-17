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
$workspaceDirectory = Split-Path -Parent $PSScriptRoot
$useDefaultDataDirectory = [string]::IsNullOrWhiteSpace($DataDirectory)
if ($useDefaultDataDirectory) { $DataDirectory = Join-Path $env:LOCALAPPDATA 'OcPlayer\Windows' }
$DataDirectory = [IO.Path]::GetFullPath($DataDirectory)
[IO.Directory]::CreateDirectory($DataDirectory) | Out-Null
if (-not $BuildDirectory) { $BuildDirectory = Join-Path $workspaceDirectory "src\OcPlayer.Windows\bin\$Platform\$Configuration\net10.0-windows10.0.26100.0" }
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory).TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $BuildDirectory 'OcPlayer.Windows.exe'))) {
    throw "Application build missing. Run dotnet build OcPlayer.sln -c $Configuration -p:Platform=$Platform first."
}

# Copy file contents into a normal per-user directory. File.Copy deliberately
# inherits the destination ACL instead of the checkout's low integrity label.
# A content-addressed directory keeps an already running build untouched.
$buildPaths = [IO.Directory]::GetFiles($BuildDirectory, '*', [IO.SearchOption]::AllDirectories)
[Array]::Sort($buildPaths, [StringComparer]::Ordinal)
$buildFiles = @($buildPaths | ForEach-Object { [IO.FileInfo]::new($_) })
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $manifest = foreach ($file in $buildFiles) {
        $relative = $file.FullName.Substring($BuildDirectory.Length + 1)
        $stream = [IO.File]::OpenRead($file.FullName)
        try { $fileHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
        "$relative=$fileHash"
    }
    $buildHash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($manifest -join "`n")))).Replace('-', '').ToLowerInvariant()
} finally { $sha.Dispose() }
$runtimeRoot = Join-Path $env:LOCALAPPDATA "OcPlayer\Windows\Runtime\$Platform\$Configuration"
[IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
$stagedDirectory = Join-Path $runtimeRoot $buildHash
$readyPath = Join-Path $stagedDirectory '.ready'
$copyLock = $null
$lockDeadline = [DateTime]::UtcNow.AddSeconds(30)
while (-not $copyLock) {
    try { $copyLock = [IO.File]::Open((Join-Path $runtimeRoot "$buildHash.lock"), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] {
        if ([DateTime]::UtcNow -ge $lockDeadline) { throw 'Timed out preparing the application runtime.' }
        Start-Sleep -Milliseconds 200
    }
}
try {
    if (-not (Test-Path -LiteralPath $readyPath)) {
        foreach ($file in $buildFiles) {
            $destination = Join-Path $stagedDirectory $file.FullName.Substring($BuildDirectory.Length + 1)
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            [IO.File]::Copy($file.FullName, $destination, $true)
        }
        [IO.File]::WriteAllText($readyPath, $buildHash)
    }
} finally { $copyLock.Dispose() }
$appPath = Join-Path $stagedDirectory 'OcPlayer.Windows.exe'
if ($PrepareOnly) { Write-Output $appPath; return }

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

# Use the staged apphost for WinUI; launching the UI DLL through dotnet is not
# equivalent to running its apphost and can crash Windows App SDK startup.
$launch = [Diagnostics.ProcessStartInfo]::new($appPath)
$launch.UseShellExecute = $false
$launch.CreateNoWindow = $true
$launch.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$launch.WorkingDirectory = $workspaceDirectory
$launch.EnvironmentVariables['DOTNET_ROOT'] = $runtimeDirectory
$launch.EnvironmentVariables["DOTNET_ROOT_$($Platform.ToUpperInvariant())"] = $runtimeDirectory
$launch.EnvironmentVariables['OCP_DATA_DIRECTORY'] = $DataDirectory
# Import the former development store before the application reads preferences.
# The importer snapshots SQLite WAL and never overwrites existing user data.
$legacyDataDirectory = Join-Path $workspaceDirectory 'artifacts\app-data'
if ($useDefaultDataDirectory -and (Test-Path -LiteralPath $legacyDataDirectory)) {
    $launch.Arguments = '--migrate-data="' + $legacyDataDirectory + '"'
    $migrationProcess = [Diagnostics.Process]::Start($launch)
    try {
        if (-not $migrationProcess.WaitForExit(60000)) { throw 'Data migration timed out; the old data has been preserved.' }
        if ($migrationProcess.ExitCode -ne 0) { throw 'Data migration failed; the old data has been preserved. Close older OcPlayer instances and retry.' }
    } finally { $migrationProcess.Dispose() }
}
$launch.Arguments = '--register-bangumi-protocol'
$registration = [Diagnostics.Process]::Start($launch)
try {
    if (-not $registration.WaitForExit(15000)) { throw 'Bangumi callback registration timed out.' }
    if ($registration.ExitCode -ne 0) { throw 'Cannot register the Bangumi callback. Launch the startup script from File Explorer.' }
} finally { $registration.Dispose() }
# ProcessStartInfo.ArgumentList is unavailable in Windows PowerShell 5.1,
# which start-release.cmd uses. Quote arguments using the Windows argv rules.
function ConvertTo-WindowsArgument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
$appArguments = @()
if ($Demo) { $appArguments += '--demo-route=home' }
if ($NavigationPreview) { $appArguments += '--nav-preview' }
if ($HeaderActionsPreview) { $appArguments += '--header-actions-preview' }
if ($DetailControlsPreview) { $appArguments += '--detail-controls-preview' }
if ($Open) { $appArguments += "--open=$Open" }
$launch.Arguments = ($appArguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
$launch.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
$launchedApp = [Diagnostics.Process]::Start($launch)
Write-Output "Started OcPlayer (PID $($launchedApp.Id)) from $stagedDirectory."
