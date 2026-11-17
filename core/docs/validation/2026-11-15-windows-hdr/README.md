# Windows HDR-to-SDR mapping acceptance — 2026-11-15

The user visually accepted the new Windows native demo while playing
`凡人修仙传 - S01E200 - 第 200 集.mp4`, after rejecting the earlier monitor-only
fix as overexposed. This acceptance applies to this source and current SDR
display, not a calibrated HDR-panel test.

## Implementation and scope

The versioned native patch is retained at
[`patches/liberika/d9334c6-windows-hdr.patch`](../../../patches/liberika/d9334c6-windows-hdr.patch).
It applies to Erika base `d9334c6f8dcc87d4131d056ef4692f643b231c6c` (local v0.1.7
Dolby Vision branch). Build instructions and platform boundaries are in
[`docs/windows-hdr.md`](../../windows-hdr.md).

Windows display HDR state, display peak and SDR white are separate inputs. The
renderer uses the BT.2446A luminance curve with uniform RGB gain for HDR-to-SDR,
the zero-black BT.2390 EETF for compressed HDR-to-HDR, and bypasses unnecessary
mapping. The standard SDR reference remains 100 nits on an SDR desktop; panel
maximum is not treated as a calibrated current white level. The Metal renderer,
shared color pipeline and Apple packaging were not changed.

## Automated checks

All **17 D3D11 tests passed**, with zero failures. They include actual HLSL
video/overlay compilation, active-HDR-desktop gating, explicit-SDR policy,
display peak/Windows white separation, invalid-report fallback, unchanged SDR
normalization and an offscreen WARP render through the actual mapping shader.
The WARP readback is checked against independent double-precision reference
values. Gray channels remain equal, black remains black and a colored sample
retains its linear RGB ratios.

| HDR input luminance (nits) | Mapped nominal SDR luminance (nits) | Approximate gamma-2.2 code |
| ---: | ---: | ---: |
| 50 | 12.6484 | 100 |
| 100 | 22.6634 | 130 |
| 203 | 40.5953 | 169 |
| 300 | 53.7432 | 192 |
| 400 | 64.4562 | 209 |
| 600 | 80.3575 | 231 |
| 800 | 91.6122 | 245 |
| 1000 | 100.0000 | 255 |

These are shader outputs, not physical panel measurements. The mapping uses the
BT.2446 Method A luminance curve, not every chroma correction in the complete
Method A procedure. Full native build and test logs are adjacent. Existing
unused-code and mixed-CRT linker warnings did not prevent either run.

## Actual playback and acceptance

The sample is HEVC Main10, 3840×2160, 25 fps, BT.2020/PQ, with AAC stereo. The
new native demo launched near 180 seconds and was observed displaying a real
animation scene and progressing beyond 216 seconds. The window identifies
`Erika Windows HDR Fix 2026-11-15`.

The current output reports HDR inactive and DXGI maximum/full-frame luminance
270 nits. Video uniforms are `[1000,100,203,100]` (source peak, target peak,
source reference white, target reference white), with `toneMap=4`. This is the
new SDR mapping path, not HDR10 output. At 44.04 seconds of wall time, 904 frames
had been decoded, all using direct zero-copy D3D11VA. Audio underflow, import
failures, render failures and HDR-output failures were zero. The initial seek and
paused review make this a playback check, not a throughput benchmark.

The user then said “可以，提交推送吧”, accepting the displayed result. The accepted
binary SHA256 is
`AE6913CB882992C0FFCE9CB9AFFFF9847CEE7C30B1C3FF03A81AF4ED5BCAF46F`.
Sources were subsequently rustfmt-formatted for the versioned patch; this hash
identifies the visually reviewed binary rather than promising reproducible
debug binary bytes. All 17 D3D11 checks also passed after formatting. The
isolated source preparation and patch equality checks
are recorded in `patch-preparation.json`.

This is an independent native renderer/demo test. It does not establish complete
OcPlayer Windows Core/WinUI integration, DV5 hardware playback, Dolby Vision
mapping accuracy, HDR-panel calibration, Atmos passthrough or full-file A/V sync.

Local binaries, media and complete live metrics remain under
`D:\OcPlayer-Core\artifacts\windows-hdr-luminance-2026-11-15`. Media and binaries
are not checked in. Selected test/build logs, launch identity and the observed
metrics snapshot are retained beside this report.
