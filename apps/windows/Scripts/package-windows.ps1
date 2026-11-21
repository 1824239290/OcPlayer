[CmdletBinding()]
param(
    [ValidateSet('x64', 'ARM64')][string]$Platform = 'x64',
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')][string]$Version = '0.3.0',
    [int]$BuildNumber = 0,
    [string]$CoreRoot = (Join-Path $PSScriptRoot '..\..\..\core'),
    [string]$VcRuntimeDirectory,
    [string]$OutputDirectory,
    [string]$InnoSetupCompiler,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipPublish
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$OutputDirectory) { $OutputDirectory = Join-Path $workspace "artifacts\release\$Version\$Platform" }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($OutputDirectory.TrimEnd('\') -eq [IO.Path]::GetPathRoot($OutputDirectory).TrimEnd('\')) { throw 'A drive root cannot be used as release output.' }
$publishDirectory = Join-Path $OutputDirectory 'app'
$toolsDirectory = Join-Path $workspace 'artifacts\tools'
$env:DOTNET_ROOT = Split-Path -Parent (Get-Command dotnet -ErrorAction Stop).Source
$env:DOTNET_ROLL_FORWARD = 'Major'
$env:NUGET_SCRATCH = Join-Path $toolsDirectory 'nuget-scratch'
[IO.Directory]::CreateDirectory($env:NUGET_SCRATCH) | Out-Null
$env:TEMP = Join-Path $toolsDirectory 'temp'
$env:TMP = $env:TEMP
[IO.Directory]::CreateDirectory($env:TEMP) | Out-Null
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)." }
}
function Assert-PeArchitecture([string]$File) {
    $expectedMachine = if ($Platform -eq 'ARM64') { 0xAA64 } else { 0x8664 }
    $stream = [IO.File]::OpenRead($File); $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Invalid PE file: $File" }
        $stream.Position = 0x3C; $stream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne $expectedMachine) { throw "Architecture mismatch ($Platform): $File" }
    } finally { $reader.Dispose(); $stream.Dispose() }
}
function Resolve-InnoSetupCompiler {
    if ($InnoSetupCompiler) {
        if (!(Test-Path -LiteralPath $InnoSetupCompiler)) { throw "Inno Setup compiler not found: $InnoSetupCompiler" }
        return (Resolve-Path -LiteralPath $InnoSetupCompiler).Path
    }
    $onPath = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    throw 'Inno Setup 6 (ISCC.exe) is required. Install Inno Setup 6 (for example: choco install innosetup -y) or pass -InnoSetupCompiler.'
}
$iscc = Resolve-InnoSetupCompiler
if (!$SkipPublish) {
    # Publish into a fresh staging directory; stale DLLs from an older release
    # must never enter the installer. The completed output is replaced last.
    $staging = Join-Path $OutputDirectory ('publish-' + [Guid]::NewGuid().ToString('N'))
    $rid = if ($Platform -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
    Invoke-Checked dotnet @('publish', "$workspace\src\OcPlayer.Windows\OcPlayer.Windows.csproj", '-c', 'Release', '-r', $rid,
        "-p:Platform=$Platform", "-p:Version=$Version", "-p:OcpCoreRoot=$([IO.Path]::GetFullPath($CoreRoot))\",
        '-p:SelfContained=true', '-p:WindowsAppSDKSelfContained=true', '-p:WindowsAppSdkDeploymentManagerInitialize=false',
        '-p:PublishSingleFile=false', '-p:PublishTrimmed=false', '-p:DebugType=None', '-p:DebugSymbols=false', '-o', $staging)
    if (Test-Path -LiteralPath $publishDirectory) {
        $resolvedPublish = (Resolve-Path -LiteralPath $publishDirectory).Path
        if (!$resolvedPublish.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe publish output path.' }
        Remove-Item -LiteralPath $resolvedPublish -Recurse -Force
    }
    $resolvedStaging = (Resolve-Path -LiteralPath $staging).Path
    if (!$resolvedStaging.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        !$publishDirectory.StartsWith($OutputDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe publish staging path.' }
    Move-Item -LiteralPath $resolvedStaging -Destination $publishDirectory
}
foreach ($required in @('OcPlayer.Windows.exe', 'ocp_ffi.dll', 'erika_capi.dll', 'coreclr.dll', 'Microsoft.UI.Xaml.dll', 'OcPlayer.Windows.pri', 'App.xbf', 'MainWindow.xbf', 'Features\PlayerView.xbf', 'Features\ServerConnectionView.xbf', 'Assets\Demo\catalog.json', 'Assets\Branding\OcPlayer.ico')) {
    if (!(Test-Path -LiteralPath (Join-Path $publishDirectory $required))) { throw "Self-contained release is incomplete: $required" }
}
$runtimeConfig = Get-Content -LiteralPath (Join-Path $publishDirectory 'OcPlayer.Windows.runtimeconfig.json') -Raw | ConvertFrom-Json
if ($runtimeConfig.runtimeOptions.framework -or $runtimeConfig.runtimeOptions.frameworks) { throw 'Release still depends on an installed .NET runtime.' }
$receiptPath = Join-Path $publishDirectory 'build-receipt.json'
if (!(Test-Path -LiteralPath $receiptPath)) { throw 'Native build receipt is missing.' }
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if ($receipt.configuration -ne 'Release') { throw 'Native DLLs must be built in Release configuration.' }
if ((Get-FileHash -LiteralPath (Join-Path $publishDirectory 'ocp_ffi.dll')).Hash -ne $receipt.coreSha256 -or
    (Get-FileHash -LiteralPath (Join-Path $publishDirectory 'erika_capi.dll')).Hash -ne $receipt.erikaSha256) { throw 'Native DLL hashes do not match the build receipt.' }
$receipt.PSObject.Properties.Remove('kernelRoot')
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding utf8
if (!$VcRuntimeDirectory) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere)) { throw 'Pass -VcRuntimeDirectory pointing to the official MSVC v14 release CRT directory.' }
    $vsInstallation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $redistVersion = Get-ChildItem -LiteralPath (Join-Path $vsInstallation 'VC\Redist\MSVC') -Directory |
        Where-Object Name -match '^\d+\.' | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    $crtPlatform = if ($Platform -eq 'ARM64') { 'arm64' } else { 'x64' }
    $runtimeDirectory = Get-ChildItem -LiteralPath (Join-Path $redistVersion.FullName $crtPlatform) -Directory -Filter 'Microsoft.VC14*.CRT' |
        Sort-Object Name -Descending | Select-Object -First 1
    if (!$runtimeDirectory) { throw "Official MSVC v14 release CRT is missing for $crtPlatform." }
    $VcRuntimeDirectory = $runtimeDirectory.FullName
}
$VcRuntimeDirectory = (Resolve-Path -LiteralPath $VcRuntimeDirectory).Path
foreach ($required in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')) {
    if (!(Test-Path -LiteralPath (Join-Path $VcRuntimeDirectory $required))) { throw "Visual C++ release runtime is incomplete: $required" }
    Assert-PeArchitecture (Join-Path $VcRuntimeDirectory $required)
}
foreach ($nativeFile in @('ocp_ffi.dll', 'erika_capi.dll', 'Microsoft.UI.Xaml.dll')) { Assert-PeArchitecture (Join-Path $publishDirectory $nativeFile) }
Get-ChildItem -LiteralPath $VcRuntimeDirectory -Filter '*.dll' -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $publishDirectory -Force }
Copy-Item -LiteralPath (Join-Path $workspace 'licenses') -Destination $publishDirectory -Recurse -Force
$nugetRoot = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
$runtimePackName = "microsoft.netcore.app.runtime.$(if ($Platform -eq 'ARM64') { 'win-arm64' } else { 'win-x64' })\" + $runtimeConfig.runtimeOptions.includedFrameworks[0].version
$runtimePack = Join-Path $nugetRoot $runtimePackName
foreach ($notice in @('LICENSE.TXT', 'THIRD-PARTY-NOTICES.TXT')) {
    if (!(Test-Path -LiteralPath (Join-Path $runtimePack $notice))) { throw "Runtime license is missing: $notice" }
    Copy-Item -LiteralPath (Join-Path $runtimePack $notice) -Destination (Join-Path $publishDirectory "licenses\dotnet-$notice") -Force
}
$signTool = $null
if ($CertificateThumbprint) {
    $signTool = Get-ChildItem -LiteralPath "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -Recurse |
        Where-Object FullName -match '\\x64\\signtool\.exe$' | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (!$signTool) { throw 'Windows SDK signtool.exe is required for signing.' }
    Invoke-Checked $signTool @('sign', '/sha1', $CertificateThumbprint, '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256', (Join-Path $publishDirectory 'OcPlayer.Windows.exe'))
}
if ($BuildNumber -le 0) {
    $existing = Get-ChildItem -LiteralPath $OutputDirectory -Filter "OcPlayer-$Version-$Platform*.exe" -File -ErrorAction SilentlyContinue
    $maxBuild = 0
    foreach ($file in $existing) {
        if ($file.Name -match ('^OcPlayer-' + [regex]::Escape($Version) + '-' + [regex]::Escape($Platform) + '(?:\((\d+)\))?(?:-Setup)?\.exe$')) {
            $num = if ($Matches[1]) { [int]$Matches[1] } else { 1 }
            if ($num -gt $maxBuild) { $maxBuild = $num }
        }
    }
    $BuildNumber = if ($maxBuild -gt 0) { $maxBuild + 1 } else { 1 }
}
$installerBaseName = "OcPlayer-$Version-$Platform($BuildNumber)-Setup"
$installer = Join-Path $OutputDirectory "$installerBaseName.exe"
$builtinChineseIsl = Join-Path (Split-Path -Parent $iscc) 'Languages\ChineseSimplified.isl'
$chineseIsl = if (Test-Path -LiteralPath $builtinChineseIsl) { 'compiler:Languages\ChineseSimplified.isl' } else { Join-Path $workspace 'installer\ChineseSimplified.isl' }
Invoke-Checked $iscc @(
    "/DMyAppVersion=$Version",
    "/DMyPlatform=$Platform",
    "/DPublishDir=$publishDirectory",
    "/DInstallerDir=$workspace\installer",
    "/DOutputDir=$OutputDirectory",
    "/DOutputBaseName=$installerBaseName",
    "/DChineseSimplifiedIsl=$chineseIsl",
    "$workspace\installer\OcPlayer.iss"
)
if ($CertificateThumbprint) { Invoke-Checked $signTool @('sign', '/sha1', $CertificateThumbprint, '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256', $installer) }
[ordered]@{ version = $Version; platform = $Platform; installer = [IO.Path]::GetFileName($installer); installerFormat = 'InnoSetup'; sha256 = (Get-FileHash -LiteralPath $installer).Hash;
    selfContained = $true; signed = [bool]$CertificateThumbprint; coreCommit = $receipt.coreCommit; kernelCommit = $receipt.kernelCommit;
    visualCppRuntime = (Get-Item -LiteralPath (Join-Path $publishDirectory 'vcruntime140.dll')).VersionInfo.FileVersion } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'release.json') -Encoding utf8
Write-Output "Installer: $installer"
