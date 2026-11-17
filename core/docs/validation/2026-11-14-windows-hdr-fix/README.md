# Windows SDR output investigation — deferred

**Historical status:** this report describes the deferred investigation on
2026-11-14. It was superseded by the
[2026-11-15 Windows HDR-to-SDR mapping acceptance](../2026-11-15-windows-hdr/README.md),
which records the versioned renderer patch, 17 passing D3D11 checks and the
user-accepted MP4 playback result on the SDR display.

The user asked to defer brightness/tone-mapping investigation while fixing the
same issue in the older macOS player. **Overexposure remains unresolved.**

The local Erika checkout at `D:\DevCache\Erika-Dolby` retains these uncommitted
Windows changes: honor explicit SDR requests; check the window's active DXGI
display color space before enabling HDR10; refresh stale display factories;
fall back to SDR when display information is unavailable; report the fallback.
The shader's tone-mapping curve has not been changed.

Fourteen D3D11 unit tests passed. A 60-second MP4 run in automatic mode reported
`hdr10_active=0`, `sdr_tonemap=1491`, `hw=1491`, and zero audio underflow/import/
render errors. A 15-second explicit-SDR run also stayed SDR. **The user still
observed excessive brightness, so these counters do not establish correct
exposure or color.**

The example also has diagnostic `--output-mode auto|sdr` and `--frame-at`
arguments for later comparison. The local, unversioned
`tests/windows-video/extract_frame.c` is an unbuilt, unused diagnostic draft.
No tone-mapping fix had been validated at this stage.
Temporary binaries, source backups and logs are under
`D:\OcPlayer-Core\artifacts\windows-hdr-fix`. The active fixed-frame test was
stopped at the user's request. No changes were committed or pushed.

The [original video report](../2026-11-14-windows-video/README.md) now retracts
SDR-display acceptance while retaining its raw throughput measurements.
