param(
    [string]$Python = 'python',
    [ValidateSet('debug', 'release')][string]$Configuration = 'debug',
    [string]$OutputDirectory,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne 'Win32NT' -or ![Environment]::Is64BitProcess) {
    throw 'Run this x64 Windows verification from a 64-bit PowerShell process.'
}
$workspace = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) { $OutputDirectory = Join-Path $workspace 'artifacts/windows-verification' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$savedEnvironment = @{}
foreach ($name in @('PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'OCP_CORE_LIBRARY_PATH', 'CARGO_HTTP_MULTIPLEXING')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Invoke-Checked([string]$Executable, [string[]]$CommandArguments, [string]$LogName) {
    Write-Host "Running $LogName"
    & $Executable @CommandArguments *> (Join-Path $OutputDirectory $LogName)
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath (Join-Path $OutputDirectory $LogName) -Tail 60
        throw "$Executable failed with exit code $LASTEXITCODE; see $LogName"
    }
}

Push-Location $workspace
try {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$installation) { throw 'Visual Studio C++ x64 Build Tools are required.' }
    $vcvars = Join-Path $installation 'VC/Auxiliary/Build/vcvars64.bat'
    $buildEnvironment = & $env:COMSPEC /d /s /c ('"{0}" >nul && set' -f $vcvars)
    if ($LASTEXITCODE -ne 0) { throw 'Failed to initialize the MSVC x64 environment.' }
    foreach ($entry in $buildEnvironment) {
        if ($entry -match '^([^=]+)=(.*)$') {
            if (!$savedEnvironment.ContainsKey($matches[1])) {
                $savedEnvironment[$matches[1]] = [Environment]::GetEnvironmentVariable($matches[1], 'Process')
            }
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
        }
    }
    # Avoid proxy-dependent HTTP/2 stalls during first-checkout Cargo downloads.
    $env:CARGO_HTTP_MULTIPLEXING = 'false'
    $cargoOptions = @('--locked')
    if ($Offline) { $cargoOptions += '--offline' }
    $profileOptions = @()
    if ($Configuration -eq 'release') { $profileOptions += '--release' }
    Invoke-Checked 'cargo' (@('test', '--workspace') + $cargoOptions + $profileOptions) 'rust-tests.log'
    Invoke-Checked 'cargo' (@('build', '-p', 'ocp-ffi', '-p', 'ocp-cli') + $cargoOptions + $profileOptions) 'rust-build.log'
    $library = Join-Path $workspace "target/$Configuration/ocp_ffi.dll"
    $nativeOutput = Join-Path $OutputDirectory 'native'
    New-Item -ItemType Directory -Force -Path $nativeOutput | Out-Null
    $fixture = Join-Path $nativeOutput 'ocp_fixture.dll'
    $missing = Join-Path $nativeOutput 'ocp_missing.dll'
    $compilerOptions = @('/nologo', '/LD', '/std:c11', '/experimental:c11atomics', '/utf-8',
        'tests/windows-sdk/native_fixture.c')
    Invoke-Checked 'cl' ($compilerOptions + @("/Fo$nativeOutput/fixture.obj", "/Fe$fixture")) 'fixture-build.log'
    Invoke-Checked 'cl' ($compilerOptions + @('/DOCP_FIXTURE_MISSING_EXPORT', "/Fo$nativeOutput/missing.obj", "/Fe$missing")) 'missing-build.log'
    $dotnetOutput = Join-Path $OutputDirectory 'dotnet'
    Invoke-Checked 'dotnet' @('build', 'tests/windows-sdk/WindowsSdkContracts.csproj', '--configuration', 'Release',
        '--artifacts-path', $dotnetOutput) 'dotnet-build.log'
    $sdk = Join-Path $dotnetOutput 'bin/WindowsSdkContracts/release/WindowsSdkContracts.dll'
    $env:OCP_CORE_LIBRARY_PATH = $fixture
    Invoke-Checked 'dotnet' @($sdk, 'mock') 'sdk-mock.log'
    $env:OCP_CORE_LIBRARY_PATH = $missing
    Invoke-Checked 'dotnet' @($sdk, 'missing') 'sdk-missing.log'
    Invoke-Checked $Python @('tests/windows-sdk/run_contracts.py', '--library', $library, '--sdk', $sdk,
        '--output', $OutputDirectory) 'runtime-runner.log'
    $env:OCP_CORE_LIBRARY_PATH = $library
    Invoke-Checked (Join-Path $workspace "target/$Configuration/ocp-cli.exe") @('replay', 'fixtures/playback-basic.jsonl') 'cli-replay.log'
    Write-Host "Windows verification passed. Results: $OutputDirectory"
    Get-Content -LiteralPath (Join-Path $OutputDirectory 'runtime-results.json')
}
finally {
    Pop-Location
    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}
