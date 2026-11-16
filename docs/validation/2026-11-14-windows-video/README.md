# Windows real-video comparison — 2026-11-14

**Acceptance correction after user feedback:** the monitor used for these runs
does not support HDR. The old example nevertheless reported `hdr10_active=1`
and `sdr_tonemap=0`, and the user observed overexposure. Its throughput and
zero-error counters remain valid measurements, but its display-output behavior
**fails SDR-monitor acceptance**. The screenshots and the earlier claim that
the MP4 displayed normally did not establish correct brightness or color.
See the [SDR output fix follow-up](../2026-11-14-windows-hdr-fix/README.md).

**Later result:** the
[2026-11-15 Windows HDR-to-SDR mapping acceptance](../2026-11-15-windows-hdr/README.md)
records a versioned renderer fix and user-accepted MP4 playback on the SDR
display. The measurements below describe the older, pre-fix example.

The non-DV5 MP4 plays through D3D11VA with direct zero-copy import and no
reported audio underflow, import errors or render errors. The DV5 MKV displays
video, but the existing Erika debug example explicitly falls back to software
decoding for RPU mapping and fails the playback-throughput check.

These are **independent native Erika/FFmpeg tests**, followed by **separate
OcPlayer-Core JSON policy tests**. The local `D:\OcPlayer-Windows` project is a
WinUI shell without a decoder integration. The example used here does not call
OcPlayer-Core. These results do not establish a complete OcPlayer Windows player.

## Inputs and host

| Input | DV5 MKV | Non-DV5 MP4 |
| --- | --- | --- |
| File | `[花开锦绣].The.Road.to.Splendor.S01E28.2026.2160p.WEB-DL.H265.DV.DDP.5.1.Atmos.2Audios-CMCTV.mkv` | `凡人修仙传 - S01E200 - 第 200 集.mp4` |
| Directory | `D:\` | `D:\` |
| Bytes | 1,068,127,232 | 1,279,965,839 |
| Duration | 2769.237 s | 1156.010667 s |
| Video | HEVC, 3840×1606, 25 fps, 10-bit | HEVC, 3840×2160, 25 fps, 10-bit |
| Color | DV profile 5, level 6, RPU+BL, no EL, compatibility ID 0 | BT.2020 / SMPTE ST 2084 (PQ), no DV configuration detected |
| Audio | E-AC-3 48 kHz 6-channel; AAC 48 kHz stereo | AAC 48 kHz stereo |
| Embedded subtitles | None found | None found |

The MP4 is non-DV5 **HDR**, rather than an SDR control. Its six decode samples
contain no DOVI RPU or DOVI metadata frame side data. The ordinary MKV color
primaries/transfer fields are unknown; its DV configuration identifies the
profile and prevents treating it as plain SDR.

Host: Windows 11 x64 build 26300, Radeon RX 470, driver `31.0.12027.9001`.
A GameViewer virtual display adapter is also present. The probe and native
example both use the local default D3D11 device selection.

The native example is the pre-existing executable at
`D:\DevCache\cargo-target\erika-dolby\x86_64-pc-windows-msvc\debug\windows_native_demo.exe`,
last modified 2026-09-04, SHA256
`93b0b6fd81cb8f1d4d01b8fc18299f3d52e9226a9b82b135c15bfc182ea06861`.
It was not rebuilt or changed. The current Erika source checkout already has
local renderer changes; correspondence between that source and this older
binary has not been verified. Core uses `target\debug\ocp_ffi.dll`; the probe
uses MSVC `/O2`, static FFmpeg `v0.1.7+dolby.2`, and D3D11VA.

## Independent decode samples

Both files passed six eight-second decode samples: opening, middle and ending,
each in software and D3D11VA. Every audio/video stream produced output, all
decoder error counts were zero, and every sampled hardware video frame was
actually D3D11VA-backed. The final interval has 199 video frames; its start
falls between frame timestamps and it reaches the file ending.

| Eight-second interval | DV5 software / hardware elapsed | MP4 software / hardware elapsed |
| --- | ---: | ---: |
| Opening | 1.519 / 1.340 s | 2.539 / 1.747 s |
| Middle | 1.706 / 1.659 s | 3.182 / 2.176 s |
| Ending | 2.509 / 1.861 s | 3.099 / 2.297 s |

Elapsed time measures the decode loop, excluding probe/setup/seek. This is a
small sample of each file, not an entire-file decode or a performance benchmark.
It excludes RPU color mapping, texture upload, presentation and audio output.

Each DV5 sampled video frame carries RPU and parsed DOVI metadata in **both**
software and hardware decoding. This establishes that the local FFmpeg build
can preserve those side data with D3D11VA. It does not establish that the
example's hardware renderer would consume and apply them correctly.

## Actual native playback

Both examples ran for about 180 seconds and displayed real frames. No decode
sampling process ran concurrently with the MP4 native-playback measurement.
The MP4 log records two seeks and successful preroll completion at 61.24 and
67.48 seconds. This task did not inject those seek inputs. The whole-run totals
therefore include those transitions. The fixed comparison uses the last sample
at or before 60 seconds, preceding those seeks.

| Counter at approximately one minute | DV5 (59.857 s) | MP4 (59.764 s) |
| --- | ---: | ---: |
| Decoded video frames | 82 | 1,458 |
| Decoded frames / wall second | 1.37 | 24.40 |
| Hardware / zero-copy / direct frames | 0 / 0 / 0 | 1,458 / 1,458 / 1,458 |
| Audio output underflow frames | 801,082 | 0 |
| Import / render errors | 0 / 0 | 0 / 0 |

| Whole-run final counter | DV5 (180.023 s) | MP4 (180.031 s) |
| --- | ---: | ---: |
| Decoded video frames | 202 | 4,464 |
| Hardware / zero-copy / direct frames | 0 / 0 / 0 | 4,464 / 4,464 / 4,464 |
| Rendered video presentations | 2,215 | 10,444 |
| Audio output underflow frames | 1,967,077 | 0 |
| Video pump p95 | 693.160 ms | 0.103 ms |
| Import / render errors | 0 / 0 | 0 / 0 |
| HDR metadata / output errors | 0 / 0 | 0 / 0 |

Rendered presentations include presenting the same video frame repeatedly;
they cannot be used as the decoded frame count or source-video frame rate.
Underflow counts audio output frames, not separate underflow events. The MP4
whole-run average is 24.80 decoded frames/s, close to its 25 fps source. A
short run with zero error counters does not establish frame-perfect pacing,
audible fidelity, lip sync, or correct display HDR calibration.

The DV5 decoder event explicitly reports:

```json
{"requestedBackend":"d3d11va","activeBackend":"software","reason":"dolby vision profile 5 requires software decode for RPU mapping"}
```

Raw HEVC software and hardware decoding both outpace real time in the separate
probe. The slow DV5 result belongs to this older example's software/RPU playback
path; it is insufficient evidence to blame Core or to say RX 470 cannot decode
the HEVC stream. Next investigations belong in Erika: measure an optimized
release build, profile RPU/color processing and pumping, and validate whether
the current FFmpeg hardware side data can be safely consumed before relaxing
the profile-5 fallback.

The earlier separate DV5 control run also observed pause, stable paused state,
forward/backward five-second seeks, and resumed progress. That run remains
distinct from the fixed-duration performance run. The MP4 displayed a nonblank
animation frame at about 109 seconds. Screen captures are local artifacts at
`artifacts\windows-video-test\playback-frame.png` and
`artifacts\windows-video-test\non-dv5\playback-frame.png`; SDR screenshots do
not validate HDR/Dolby Vision color accuracy. Visible MP4 captions are part of
the video image, not proof of native subtitle rendering. The MP4's FFmpeg
chapter-track warning did not prevent opening or decoding.

## Separate Core checks and evidence

The final diagnostic runner passed 24 Core command responses for the DV5 file
and 23 for the MP4. It checks actual Unicode source paths, duration via
`playback.ready`, seek/position snapshots matching decoded timestamps,
pause/resume, audio-selection state, stop, and saved SQLite progress equality
after destroying/reopening Core. Filename parsing returned S01/E28 and S01/E200;
the DV5 title still retains release tags and an unmatched closing bracket. These
are command/state checks, not integrated decoder, audio-track switching or
danmaku matching accuracy checks. Production Core/SDK files were unchanged.

- [Consolidated receipt, metadata, hashes, six samples per file and playback metrics](video-results.json)
- [DV5 Core command responses](dv5-core-receipts.json) and [MP4 responses](nonDv5-core-receipts.json)
- [DV5 final summary](dv5-native-stdout.log), [decoder events](dv5-native-stderr.log), [time series](dv5-native-metrics.jsonl)
- [MP4 final summary](nonDv5-native-stdout.log), [decoder/seek events](nonDv5-native-stderr.log), [time series](nonDv5-native-metrics.jsonl)
- [DV5 interactive observations](dv5-controls.json) and [MP4 visual observation](nonDv5-visual-observation.json)
- [Diagnostic build/run instructions](../../../tests/windows-video/README.md)
- [Earlier Windows Core/SDK acceptance](../2026-11-14-windows/README.md)

The probe and runner are in `tests/windows-video`. The native example invocation
was `"<media>" --smoke-seconds 180 --metrics-log "<absolute JSONL path>" --platform-native`.
All playback test windows have exited. Media files were read locally and never
copied into the repository or uploaded. No commit or push was performed.

Remaining acceptance includes the actual OcPlayer Windows decoder/Core/WinUI
integration, optimized builds, full-file stability, color/HDR/DV fidelity,
Atmos passthrough, native subtitles, multi-track playback and A/V sync.
