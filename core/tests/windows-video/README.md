# Local Windows video diagnostics

These tools sample a local file with FFmpeg and then exercise the Core DLL's
JSON playback policy separately. They do **not** connect a native player to
Core, render video, apply Dolby Vision RPU mapping, or verify Atmos bitstream
output. No media is copied or uploaded.

`native_media_probe.c` uses `wmain` for Unicode Windows paths. For each
audio/video stream it reports decoded frame counts, timestamps, decoder errors,
D3D11VA frames, and Dolby Vision frame side data. Each invocation decodes one
eight-second interval by default. Its elapsed time measures the decode loop;
probing, decoder setup and seeking occur before that timer.

`run_sample.py` checks opening, middle and ending intervals with software and
D3D11VA. It requires every audio/video stream to decode, no decoder errors,
nonempty output, and all video frames to use hardware when requested. It then
tests the actual Unicode source path, duration supplied through `playback.ready`,
seek/position snapshots, pause/resume, audio selection, stop, and SQLite progress
retention after destroying and reopening Core. Track selection here verifies
policy state; it does not switch a native decoder's audio track.

## Prerequisites and build

Use Windows x64, Python 3, Visual Studio Build Tools with the C compiler/Windows
SDK, and an existing static FFmpeg build with D3D11VA support. The local
2026-11-14 run used Erika's existing FFmpeg distribution at
`D:\DevCache\Erika-Dolby\third_party\dist\x86_64-pc-windows-msvc\lgpl`, version
`v0.1.7+dolby.2`. No FFmpeg download is part of these tools.

Run the following in PowerShell from the repository root. Adjust the dependency
and VS paths for another machine. `cmd` only imports the compiler environment;
file operations stay in PowerShell.

```powershell
$buildEnvironment = & $env:COMSPEC /d /s /c '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul && set'
foreach ($entry in $buildEnvironment) {
    if ($entry -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
    }
}
$videoDist = 'D:\DevCache\Erika-Dolby\third_party\dist\x86_64-pc-windows-msvc\lgpl'
$videoOutput = Join-Path (Get-Location) 'artifacts\windows-video-test'
New-Item -ItemType Directory -Path $videoOutput -Force | Out-Null
$videoLibs = @('avformat.lib','avcodec.lib','swresample.lib','swscale.lib','avutil.lib',
    'zlib.lib','bcrypt.lib','d3d11.lib','dxgi.lib','dxguid.lib','gdi32.lib','mf.lib',
    'mfplat.lib','mfuuid.lib','mfreadwrite.lib','ole32.lib','secur32.lib',
    'strmiids.lib','user32.lib','uuid.lib','ws2_32.lib')
& cl.exe /nologo /O2 /MD /std:c11 /utf-8 "/I$videoDist\ffmpeg\include" `
    tests\windows-video\native_media_probe.c "/Fo$videoOutput\native_media_probe.obj" `
    "/Fe$videoOutput\native_media_probe.exe" /link /NODEFAULTLIB:LIBCMT `
    "/LIBPATH:$videoDist\ffmpeg\lib" "/LIBPATH:$videoDist\zlib\lib" $videoLibs
if ($LASTEXITCODE -ne 0) { throw 'FFmpeg probe build failed' }
cargo build --locked -p ocp-ffi
if ($LASTEXITCODE -ne 0) { throw 'Core DLL build failed' }
```

`/MD /NODEFAULTLIB:LIBCMT` matches the mixed CRT directives of this existing
FFmpeg/zlib distribution. Reassess those flags when using different libraries.

## Run a sample

```powershell
python tests\windows-video\run_sample.py `
    --media 'D:\凡人修仙传 - S01E200 - 第 200 集.mp4' `
    --probe artifacts\windows-video-test\native_media_probe.exe `
    --core target\debug\ocp_ffi.dll `
    --output artifacts\windows-video-test\non-dv5
```

Use a separate output directory per file. JSON results and per-interval FFmpeg
stderr logs are written there. `core-sample-receipts.json` preserves Core
responses even if an assertion fails; `sample-results.json` is written only
after the complete sample succeeds.

The separate native playback measurements and their scope are documented in
[the real-video report](../../docs/validation/2026-11-14-windows-video/README.md).
