param([string]$Metadata, [string]$Kernel, [string]$Nuget, [string]$Output)
$ErrorActionPreference = 'Stop'
$data = Get-Content -LiteralPath $Metadata -Raw | ConvertFrom-Json
$packages = @{}; $nodes = @{}
foreach ($package in $data.packages) { $packages[$package.id] = $package }
foreach ($node in $data.resolve.nodes) { $nodes[$node.id] = $node }
$reachable = [System.Collections.Generic.HashSet[string]]::new()
function Walk([string]$key) { if (!$reachable.Add($key)) { return }; foreach ($dep in $nodes[$key].deps) { Walk $dep.pkg } }
Walk (($data.packages | Where-Object name -eq 'ocp-ffi').id)
$entries = [System.Collections.Generic.List[object]]::new()
function Add-Entry($group,$name,$version,$license,$purpose,$url,$link,$text) {
    $entries.Add([ordered]@{ Group=$group; Name=$name; Version=$version; License=$license; Purpose=$purpose; HomeUrl=$url; LicenseUrl=$link; Text=$text })
}
foreach ($package in ($reachable | ForEach-Object { $packages[$_] } | Sort-Object name,version)) {
    $folder = Split-Path -Parent $package.manifest_path
    $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object Name -match '^(LICENSE|COPYING|NOTICE)')
    if ($package.name.StartsWith('ocp-')) { $files = @(Get-Item (Join-Path $data.workspace_root 'LICENSE')) }
    $text = ($files | ForEach-Object { $_.Name + "`n" + (Get-Content -LiteralPath $_.FullName -Raw) }) -join "`n`n"
    if (!$text -and $package.name -eq 'alloc-stdlib') { $text = Get-Content (Join-Path $PSScriptRoot '../licenses/ThirdParty/alloc-stdlib.txt') -Raw }
    if (!$text) { throw "Missing license text for $($package.name) $($package.version)" }
    $url = $package.repository; if (!$url) { $url = $package.homepage }; if (!$url) { $url = 'https://crates.io/crates/' + $package.name }
    $license = $package.license; if (!$license) { $license = '见随包许可' }
    $purpose = $package.description; if (!$purpose) { $purpose = 'OcPlayer 共享核心组件' }
    Add-Entry '共享核心与 Rust 依赖' $package.name $package.version $license $purpose $url ('https://crates.io/crates/'+$package.name+'/'+$package.version) $text
}
Add-Entry 'Windows 界面' 'Microsoft.WindowsAppSDK' '2.6.5' 'Microsoft Windows App SDK license' 'WinUI 3、窗口与系统集成' 'https://github.com/microsoft/WindowsAppSDK' 'https://github.com/microsoft/WindowsAppSDK/blob/main/LICENSE' ((Get-Content (Join-Path $Nuget 'microsoft.windowsappsdk/2.6.5/license.txt') -Raw)+"`n`n"+(Get-Content (Join-Path $Nuget 'microsoft.windowsappsdk/2.6.5/NOTICE.txt') -Raw))
Add-Entry 'Windows 界面' 'Microsoft.Graphics.Win2D' '1.4.0' 'MIT（上游源码）；NuGet 声明 Microsoft EULA' 'Direct2D 图形。NuGet 的旧 EULA URL 已重定向至无关页面；此处随包保留官方源仓库的 MIT 文本。' 'https://github.com/microsoft/Win2D' 'https://github.com/microsoft/Win2D/blob/master/LICENSE.txt' (Get-Content (Join-Path $PSScriptRoot '../licenses/ThirdParty/Win2D.txt') -Raw)
Add-Entry 'Windows 运行库' 'Microsoft Visual C++ Runtime' 'MSVC v14 release CRT' 'Microsoft Visual Studio REDIST terms' '原生 Core、Erika 和 WinUI 的 app-local C/C++ 运行库。具体文件版本记录在发行 release.json。' 'https://visualstudio.microsoft.com/license-terms/' 'https://learn.microsoft.com/visualstudio/releases/2022/redistribution' (Get-Content (Join-Path $PSScriptRoot '../licenses/ThirdParty/VisualCppRuntime.txt') -Raw)
$windowsAssets = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/OcPlayer.Windows/obj/project.assets.json') -Raw | ConvertFrom-Json
foreach ($identity in $windowsAssets.libraries.PSObject.Properties.Name | Where-Object { $_ -match '^Microsoft\.Data\.Sqlite(?:\.Core)?/|^SQLite/|^SQLitePCLRaw\.' }) {
    $parts = $identity.Split('/'); $name = $parts[0]; $version = $parts[1]
    $folder = Join-Path $Nuget ($name.ToLowerInvariant() + '/' + $version)
    [xml]$nuspec = Get-Content -LiteralPath (Join-Path $folder ($name.ToLowerInvariant() + '.nuspec')) -Raw
    $packageMetadata = $nuspec.package.metadata; $license = $packageMetadata.license.InnerText
    if ($packageMetadata.license.type -eq 'file') { $text = Get-Content -LiteralPath (Join-Path $folder $license) -Raw; $license = 'Public Domain' }
    elseif ($license -eq 'Apache-2.0') { $text = Get-Content -LiteralPath (Join-Path $Kernel 'packaging/LICENSE.Apache-2.0') -Raw }
    elseif ($license -eq 'MIT') {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../licenses/ThirdParty/DotNet-MIT.txt') -Raw
    } else { throw "Missing migration dependency license for $identity ($license)" }
    $url = if ($packageMetadata.projectUrl) { [string]$packageMetadata.projectUrl } else { 'https://www.nuget.org/packages/' + $name }
    Add-Entry 'Windows 数据迁移' $name $version $license '旧数据目录的 SQLite 一致性快照；读取 WAL，保留原数据库。' $url $url $text
}
$kernelVersion = ([regex]::Match([IO.File]::ReadAllText((Join-Path $Kernel 'Cargo.toml')), '(?ms)^\[workspace\.package\].*?^version\s*=\s*"([^"]+)"')).Groups[1].Value
if (!$kernelVersion) { throw 'Kernel workspace version is missing.' }
Add-Entry '播放内核与原生依赖' 'liberika' $kernelVersion 'MPL-2.0' 'FFmpeg 解码、WASAPI 音频、D3D11 视频与字幕/弹幕' 'https://github.com/AimesSoft/liberika' 'https://github.com/AimesSoft/liberika/blob/main/LICENSE' (Get-Content (Join-Path $Kernel 'LICENSE') -Raw)
foreach ($native in @(
    @('FFmpeg','LGPL-3.0-or-later（本 Windows 构建）','音视频解封装与解码','https://ffmpeg.org/','LICENSE.FFmpeg.md'),
    @('dav1d','BSD-2-Clause','AV1 软件解码','https://code.videolan.org/videolan/dav1d','LICENSE.dav1d'),
    @('libass','ISC','ASS / SSA 字幕渲染','https://github.com/libass/libass','LICENSE.libass'),
    @('FreeType','FTL / GPL-2.0','字体栅格化','https://freetype.org/','LICENSE.FreeType'),
    @('HarfBuzz','MIT','字体 shaping','https://harfbuzz.github.io/','LICENSE.HarfBuzz'),
    @('zlib','Zlib','解压缩','https://zlib.net/','LICENSE.zlib'))) {
    $text = Get-Content (Join-Path $Kernel ('packaging/'+$native[4])) -Raw
    if ($native[0] -eq 'FFmpeg') { $text += "`n`n"+(Get-Content (Join-Path $Kernel 'packaging/LICENSE.LGPL-3.0') -Raw) }
    Add-Entry '播放内核与原生依赖' $native[0] '随 liberika 原生构建' $native[1] $native[2] $native[3] $native[3] $text
}
Add-Entry '播放内核与原生依赖' 'ArtCNN' '随 liberika 打包模型' 'MIT' '画质增强模型' 'https://github.com/Artoriuz/ArtCNN' 'https://github.com/Artoriuz/ArtCNN/blob/master/LICENSE' (Get-Content (Join-Path $Kernel 'crates/erika/assets/artcnn/LICENSE.ArtCNN') -Raw)
Add-Entry '播放内核与原生依赖' 'Droid Sans Fallback' '随 liberika 打包字体' 'Apache-2.0' '字幕与弹幕的内置字体回退' 'https://github.com/AimesSoft/liberika' 'https://github.com/AimesSoft/liberika/blob/main/crates/erika/assets/NOTICE.md' ((Get-Content (Join-Path $Kernel 'crates/erika/assets/NOTICE.md') -Raw) + "`n`n" + (Get-Content (Join-Path $Kernel 'packaging/LICENSE.Apache-2.0') -Raw))
Add-Entry '播放内核与原生依赖' 'Anime4K' '随 liberika 打包模型' 'MIT' '画质增强模型' 'https://github.com/bloc97/Anime4K' 'https://github.com/bloc97/Anime4K/blob/master/LICENSE' (Get-Content (Join-Path $Kernel 'crates/erika/assets/anime4k/LICENSE.Anime4K') -Raw)
Add-Entry '播放内核与原生依赖' 'FSR1' '随 liberika 打包着色器' 'MIT' '空间缩放着色器' 'https://github.com/GPUOpen-Effects/FidelityFX-FSR' 'https://github.com/GPUOpen-Effects/FidelityFX-FSR/blob/master/license.txt' (Get-Content (Join-Path $Kernel 'crates/erika/assets/fsr1/LICENSE.FSR1') -Raw)
foreach ($service in @(@('TMDB','影视元数据、海报与分集数据','https://www.themoviedb.org/'),@('Bangumi','番组元数据、收藏与播放记录','https://bgm.tv/'),@('DanDanPlay','弹幕匹配和弹幕数据','https://www.dandanplay.com/'),@('AniSkip','动画片头区间','https://aniskip.com/'),@('anime-skip','动画跳过区间','https://anime-skip.com/'),@('TheIntroDB','影视片头区间','https://theintrodb.org/'))) {
    Add-Entry '社区数据服务' $service[0] '在线服务' '遵循服务条款' $service[1] $service[2] $service[2] '此项是在线数据服务。数据和商标归各服务及其贡献者所有。'
}
$json = ConvertTo-Json -InputObject $entries.ToArray() -Depth 6 -Compress
$base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
$source = @"
// Generated by Scripts/generate-license-catalog.ps1 from resolved Windows dependencies.
using System.Text;
using System.Text.Json;
namespace OcPlayer.Windows.Services;
internal sealed record LicenseEntry(string Group, string Name, string Version, string License, string Purpose, string HomeUrl, string LicenseUrl, string Text);
internal static class OpenSourceCatalog
{
    public static LicenseEntry[] Entries { get; } = JsonSerializer.Deserialize<LicenseEntry[]>(Encoding.UTF8.GetString(Convert.FromBase64String("$base64")))!;
}
"@
$outputPath = [IO.Path]::GetFullPath($Output)
if (!(Test-Path -LiteralPath $outputPath) -or [IO.File]::ReadAllText($outputPath) -ne $source) {
    [IO.File]::WriteAllText($outputPath, $source)
}
Write-Output "Bundled $($entries.Count) entries, $($source.Length) source characters."
