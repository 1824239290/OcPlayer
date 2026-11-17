[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$UpgradeInstaller,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\installer-verification')
)
$ErrorActionPreference = 'Stop'
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$UpgradeInstaller = (Resolve-Path -LiteralPath $UpgradeInstaller).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$installedDirectory = Join-Path $OutputDirectory 'installed-app'
$dataDirectory = Join-Path $OutputDirectory 'user-data'
[IO.Directory]::CreateDirectory($dataDirectory) | Out-Null
$installerApi = New-Object -ComObject WindowsInstaller.Installer
function Read-MsiProperty([string]$Path, [string]$Name) {
    $database = $installerApi.OpenDatabase($Path, 0)
    $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    $view.Execute() | Out-Null
    try { $record = $view.Fetch(); return $record.StringData(1) }
    finally { $view.Close() | Out-Null }
}
$originalProduct = Read-MsiProperty $Installer 'ProductCode'
$upgradeProduct = Read-MsiProperty $UpgradeInstaller 'ProductCode'
$originalVersion = Read-MsiProperty $Installer 'ProductVersion'
$upgradeVersion = Read-MsiProperty $UpgradeInstaller 'ProductVersion'
if ([version]$upgradeVersion -le [version]$originalVersion) { throw 'The upgrade fixture must have a newer version.' }
if ($installerApi.ProductState($originalProduct) -ne -1 -or $installerApi.ProductState($upgradeProduct) -ne -1) { throw 'These products are already installed. Use fresh verification packages.' }
$relatedProducts = @($installerApi.RelatedProducts((Read-MsiProperty $Installer 'UpgradeCode'))) | Where-Object { $_ }
if ($relatedProducts) { throw 'An existing OcPlayer MSI is installed. Run lifecycle verification in an isolated Windows account or VM.' }
$protocolPaths = @('Software\Classes\ocplayer', 'Software\Classes\ocplayer\shell\open\command')
$protocolBackup = @{}
foreach ($path in $protocolPaths) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
    if ($key) { try { $values = @{}; foreach ($name in $key.GetValueNames()) { $values[$name] = @{ Value = $key.GetValue($name); Kind = $key.GetValueKind($name) } }; $protocolBackup[$path] = $values } finally { $key.Dispose() } }
}
$assertions = [Collections.Generic.List[string]]::new()
function Assert-Installer([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message }; $assertions.Add($Message); Write-Output "PASS $Message" }
function Invoke-Msi([string[]]$Arguments) {
    $quoted = $Arguments | ForEach-Object {
        if ($_.StartsWith('/')) { $_ }
        elseif ($_ -match '^([A-Z][A-Z0-9_]*)=(.*)$') { $Matches[1] + '="' + $Matches[2].Replace('"', '\"') + '"' }
        else { '"' + $_.Replace('"', '\"') + '"' }
    }
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList ($quoted -join ' ') -WindowStyle Hidden -PassThru
    try { if (!$process.WaitForExit(60000)) { $process.Kill(); throw 'Windows Installer did not finish within 60 seconds.' }; if ($process.ExitCode -notin @(0, 3010)) { throw "Windows Installer failed ($($process.ExitCode)). See the MSI log." } }
    finally { $process.Dispose() }
}
function Probe-Runtime([string]$Name, [string]$ExpectedVersion) {
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
    Assert-Installer ([version]$result.version -eq [version]$ExpectedVersion) 'the installed binary reports the expected release version'
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
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($path, $true)
        try { foreach ($name in $protocolBackup[$path].Keys) { $value = $protocolBackup[$path][$name]; $key.SetValue($name, $value.Value, $value.Kind) } }
        finally { $key.Dispose() }
    }
}
try {
    [IO.File]::WriteAllText($sentinel, 'preserve user playback history')
    Invoke-Msi @('/i', $Installer, '/qn', '/norestart', "INSTALLFOLDER=$installedDirectory", '/l*v', (Join-Path $OutputDirectory 'install.log'))
    Probe-Runtime 'first-runtime' $originalVersion
    Assert-Installer ((Read-MsiProperty $Installer 'ARPPRODUCTICON') -eq 'OcPlayerIcon') 'the installed product uses the OcPlayer icon'
    $handler = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\ocplayer\shell\open\command')
    try {
        Assert-Installer ($handler.GetValue('').Contains('"' + (Join-Path $installedDirectory 'OcPlayer.Windows.exe') + '"')) 'installation registers the quoted apphost protocol command'
    } finally { $handler.Dispose() }
    [IO.File]::WriteAllText((Join-Path $dataDirectory 'runtime-settings.json'), '{"UserAgent":"installer-fixture"}')
    $databasePath = Join-Path $dataDirectory 'Media.sqlite'
    $databaseHash = (Get-FileHash -LiteralPath $databasePath).Hash
    Invoke-Msi @('/i', $UpgradeInstaller, '/qn', '/norestart', "INSTALLFOLDER=$installedDirectory", '/l*v', (Join-Path $OutputDirectory 'upgrade.log'))
    Assert-Installer ($installerApi.ProductState($originalProduct) -eq -1 -and $installerApi.ProductState($upgradeProduct) -eq 5) 'major upgrade removes the earlier product and installs the new version'
    Assert-Installer ((Get-FileHash -LiteralPath $databasePath).Hash -eq $databaseHash) 'upgrade leaves the actual Core database unchanged'
    Probe-Runtime 'upgraded-runtime' $upgradeVersion
    Assert-Installer ([IO.File]::ReadAllText($sentinel) -eq 'preserve user playback history') 'upgrade preserves application data outside the installation directory'
    Assert-Installer ([IO.File]::ReadAllText((Join-Path $dataDirectory 'runtime-settings.json')) -eq '{"UserAgent":"installer-fixture"}') 'upgrade preserves existing runtime preferences'
    $databaseHash = (Get-FileHash -LiteralPath $databasePath).Hash
    Invoke-Msi @('/x', $upgradeProduct, '/qn', '/norestart', '/l*v', (Join-Path $OutputDirectory 'uninstall.log'))
    Assert-Installer (!(Test-Path -LiteralPath (Join-Path $installedDirectory 'OcPlayer.Windows.exe'))) 'uninstall removes the application binaries'
    Assert-Installer ([IO.File]::ReadAllText($sentinel) -eq 'preserve user playback history') 'uninstall preserves user preferences and playback data'
    Assert-Installer ((Get-FileHash -LiteralPath $databasePath).Hash -eq $databaseHash) 'uninstall retains the actual Core database unchanged'
    @{ passed = $true; assertions = $assertions.ToArray() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') -Encoding utf8
} catch {
    @{ passed = $false; assertions = $assertions.ToArray(); error = $_.Exception.ToString() } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'results.json') -Encoding utf8
    throw
} finally {
    foreach ($product in @($upgradeProduct, $originalProduct)) {
        if ($installerApi.ProductState($product) -eq 5) { Invoke-Msi @('/x', $product, '/qn', '/norestart', '/l*v', (Join-Path $OutputDirectory 'cleanup.log')) }
    }
    Restore-Protocol
}
