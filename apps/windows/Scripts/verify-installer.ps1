[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$UpgradeInstaller,
    [ValidateSet('perUser', 'perMachine')][string]$Scope = 'perUser',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\installer-verification')
)
$ErrorActionPreference = 'Stop'
if ($Scope -eq 'perMachine') {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Per-machine installer lifecycle verification requires an elevated Administrator PowerShell session.'
    }
}
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$UpgradeInstaller = (Resolve-Path -LiteralPath $UpgradeInstaller).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$installedDirectory = Join-Path $OutputDirectory '自定义安装目录\OcPlayer App'
$dataDirectory = Join-Path $OutputDirectory 'user-data'
[IO.Directory]::CreateDirectory($dataDirectory) | Out-Null
$registryRoot = if ($Scope -eq 'perMachine') { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
$scopeFlag = if ($Scope -eq 'perMachine') { '/ALLUSERS' } else { '/CURRENTUSER' }
$uninstallSubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{1EDBADE9-AD55-442B-A1DB-752A2A40B549}_is1'
$metaSubkey = 'Software\OcPlayer\Windows\Installer'
function Normalize-Version([string]$Raw) {
    $v = [version]($Raw.Trim())
    $build = if ($v.Build -lt 0) { 0 } else { $v.Build }
    $rev = if ($v.Revision -lt 0) { 0 } else { $v.Revision }
    return [version]::new($v.Major, $v.Minor, $build, $rev)
}
function Read-SetupVersion([string]$Path) {
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $raw = if ($info.FileVersion) { $info.FileVersion } else { $info.ProductVersion }
    if (!$raw) { throw "Installer version metadata is missing: $Path" }
    return Normalize-Version $raw
}
$originalVersion = Read-SetupVersion $Installer
$upgradeVersion = Read-SetupVersion $UpgradeInstaller
if ($upgradeVersion -le $originalVersion) { throw 'The upgrade fixture must have a newer version.' }
$existingUninstall = $registryRoot.OpenSubKey($uninstallSubkey)
if ($existingUninstall) {
    $existingUninstall.Dispose()
    throw "An existing OcPlayer installation is present for $Scope. Run lifecycle verification in an isolated Windows account or VM."
}
$protocolPaths = @('Software\Classes\ocplayer', 'Software\Classes\ocplayer\shell\open\command')
$protocolBackup = @{}
foreach ($path in $protocolPaths) {
    $key = $registryRoot.OpenSubKey($path)
    if ($key) { try { $values = @{}; foreach ($name in $key.GetValueNames()) { $values[$name] = @{ Value = $key.GetValue($name); Kind = $key.GetValueKind($name) } }; $protocolBackup[$path] = $values } finally { $key.Dispose() } }
}
$assertions = [Collections.Generic.List[string]]::new()
function Assert-Installer([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message }; $assertions.Add($Message); Write-Output "PASS $Message" }
function Invoke-Setup([string]$Executable, [string[]]$Arguments) {
    $quoted = $Arguments | ForEach-Object {
        if ($_ -match '^(/[A-Za-z]+)=(.*)$') { $Matches[1] + '="' + $Matches[2].Replace('"', '\"') + '"' }
        elseif ($_ -match '\s') { '"' + $_.Replace('"', '\"') + '"' }
        else { $_ }
    }
    $process = Start-Process -FilePath $Executable -ArgumentList ($quoted -join ' ') -WindowStyle Hidden -PassThru
    try {
        if (!$process.WaitForExit(120000)) { $process.Kill(); throw "Installer did not finish within 120 seconds: $Executable" }
        if ($process.ExitCode -ne 0) { throw "Installer failed ($($process.ExitCode)): $Executable" }
    } finally { $process.Dispose() }
}
function Read-RegistryValue([string]$Subkey, [string]$Name) {
    $key = $registryRoot.OpenSubKey($Subkey)
    if (!$key) { return $null }
    try { return $key.GetValue($Name) }
    finally { $key.Dispose() }
}
function Probe-Runtime([string]$Name, [version]$ExpectedVersion) {
    $resultPath = Join-Path $dataDirectory "$Name.json"
    $launch = [Diagnostics.ProcessStartInfo]::new((Join-Path $installedDirectory 'OcPlayer.Windows.exe'))
    $launch.UseShellExecute = $false; $launch.CreateNoWindow = $true; $launch.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $launch.WorkingDirectory = $OutputDirectory
    $launch.EnvironmentVariables['DOTNET_ROOT'] = 'Z:\nonexistent-runtime'
    $launch.EnvironmentVariables['DOTNET_ROOT_X64'] = 'Z:\nonexistent-runtime'
    $launch.EnvironmentVariables['OCP_CORE_LIBRARY_PATH'] = ''
    $launch.EnvironmentVariables['OCP_DATA_DIRECTORY'] = $dataDirectory
    $launch.Arguments = '--verify-runtime="' + $resultPath + '"'
    $process = [Diagnostics.Process]::Start($launch)
    try { if (!$process.WaitForExit(30000)) { throw 'Installed runtime probe timed out.' }; Assert-Installer ($process.ExitCode -eq 0 -and (Test-Path -LiteralPath $resultPath)) 'installed apphost starts without DOTNET_ROOT or a developer checkout' }
    finally { $process.Dispose() }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-Installer $result.passed 'installed Core, Erika and the WinUI main window initialize successfully'
    Assert-Installer ((Normalize-Version $result.version) -eq $ExpectedVersion) 'the installed binary reports the expected release version'
    Assert-Installer ($result.dataDirectory -eq $dataDirectory) 'the installed app uses the independent user-data directory'
    foreach ($module in @('coreclr.dll', 'Microsoft.UI.Xaml.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        Assert-Installer ($result.modules.$module.StartsWith($installedDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) "$module loads from the installed directory"
    }
    Assert-Installer (Test-Path -LiteralPath (Join-Path $installedDirectory 'msvcp140.dll')) 'the C++ standard library runtime is included beside the apphost'
    Assert-Installer (Test-Path -LiteralPath (Join-Path $installedDirectory 'Assets\Branding\OcPlayer.ico')) 'the window icon is included in the installed application'
}
$sentinel = Join-Path $dataDirectory 'playback-history-sentinel.txt'
function Restore-Protocol {
    foreach ($path in $protocolBackup.Keys) {
        $key = $registryRoot.CreateSubKey($path, $true)
        try { foreach ($name in $protocolBackup[$path].Keys) { $value = $protocolBackup[$path][$name]; $key.SetValue($name, $value.Value, $value.Kind) } }
        finally { $key.Dispose() }
    }
}
function Invoke-InstalledUninstaller([string]$LogName) {
    $uninstallString = Read-RegistryValue $uninstallSubkey 'UninstallString'
    if (!$uninstallString) { return $false }
    $uninstallerPath = $uninstallString.Trim().Trim('"')
    if (!(Test-Path -LiteralPath $uninstallerPath)) { return $false }
    Invoke-Setup $uninstallerPath @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$(Join-Path $OutputDirectory $LogName)")
    return $true
}
try {
    [IO.File]::WriteAllText($sentinel, 'preserve user playback history')
    Invoke-Setup $Installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', $scopeFlag, "/DIR=$installedDirectory", "/LOG=$(Join-Path $OutputDirectory 'install.log')")
    $recordedInstall = Read-RegistryValue $uninstallSubkey 'InstallLocation'
    Assert-Installer ($recordedInstall -and $recordedInstall.TrimEnd('\') -eq $installedDirectory.TrimEnd('\')) 'installation records the custom directory containing spaces and Unicode characters'
    $metaInstall = Read-RegistryValue $metaSubkey 'InstallLocation'
    Assert-Installer ($metaInstall -and $metaInstall.TrimEnd('\') -eq $installedDirectory.TrimEnd('\')) 'installation records InstallLocation in OcPlayer installer metadata'
    Probe-Runtime 'first-runtime' $originalVersion
    $displayIcon = Read-RegistryValue $uninstallSubkey 'DisplayIcon'
    Assert-Installer ($displayIcon -and $displayIcon.EndsWith('OcPlayer.Windows.exe', [StringComparison]::OrdinalIgnoreCase)) 'the installed product uses the OcPlayer icon'
    $handler = $registryRoot.OpenSubKey('Software\Classes\ocplayer\shell\open\command')
    if (!$handler) { throw "Protocol registration is missing for $Scope." }
    try {
        Assert-Installer ($handler.GetValue('').Contains('"' + (Join-Path $installedDirectory 'OcPlayer.Windows.exe') + '"')) 'installation registers the quoted apphost protocol command'
    } finally { $handler.Dispose() }
    [IO.File]::WriteAllText((Join-Path $dataDirectory 'runtime-settings.json'), '{"UserAgent":"installer-fixture"}')
    $databasePath = Join-Path $dataDirectory 'Media.sqlite'
    $databaseHash = (Get-FileHash -LiteralPath $databasePath).Hash
    Invoke-Setup $UpgradeInstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$(Join-Path $OutputDirectory 'upgrade.log')")
    $upgradedDisplayVersion = Read-RegistryValue $uninstallSubkey 'DisplayVersion'
    Assert-Installer ($upgradedDisplayVersion -and (Normalize-Version $upgradedDisplayVersion) -eq $upgradeVersion) 'upgrade updates the registered product version in place'
    $upgradedInstall = Read-RegistryValue $uninstallSubkey 'InstallLocation'
    Assert-Installer ($upgradedInstall -and $upgradedInstall.TrimEnd('\') -eq $installedDirectory.TrimEnd('\')) 'upgrade reuses the custom installation directory and scope without CLI overrides'
    Assert-Installer ((Get-FileHash -LiteralPath $databasePath).Hash -eq $databaseHash) 'upgrade leaves the actual Core database unchanged'
    Probe-Runtime 'upgraded-runtime' $upgradeVersion
    Assert-Installer ([IO.File]::ReadAllText($sentinel) -eq 'preserve user playback history') 'upgrade preserves application data outside the installation directory'
    Assert-Installer ([IO.File]::ReadAllText((Join-Path $dataDirectory 'runtime-settings.json')) -eq '{"UserAgent":"installer-fixture"}') 'upgrade preserves existing runtime preferences'
    $databaseHash = (Get-FileHash -LiteralPath $databasePath).Hash
    Assert-Installer (Invoke-InstalledUninstaller 'uninstall.log') 'uninstaller runs cleanly'
    Assert-Installer (!(Test-Path -LiteralPath (Join-Path $installedDirectory 'OcPlayer.Windows.exe'))) 'uninstall removes the application binaries'
    Assert-Installer ($null -eq (Read-RegistryValue $uninstallSubkey 'InstallLocation')) 'uninstall removes the registered product entry'
    Assert-Installer ([IO.File]::ReadAllText($sentinel) -eq 'preserve user playback history') 'uninstall preserves user preferences and playback data'
    Assert-Installer ((Get-FileHash -LiteralPath $databasePath).Hash -eq $databaseHash) 'uninstall retains the actual Core database unchanged'
    @{ passed = $true; scope = $Scope; assertions = $assertions.ToArray() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') -Encoding utf8
} catch {
    @{ passed = $false; scope = $Scope; assertions = $assertions.ToArray(); error = $_.Exception.ToString() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') -Encoding utf8
    throw
} finally {
    Invoke-InstalledUninstaller 'cleanup.log' | Out-Null
    Restore-Protocol
}
