# Core-enabled macOS HDR fix — 2026-11-14

The Core-enabled application now supplies the native PQ compositor with source
HDR mastering metadata. The renderer change is delivered as a versioned patch in
OcPlayer-Core, with an isolated native/Core build script. The original installed
application and source checkouts are not replaced.

## Regression and verification

- A new real-Metal/CAMetalLayer regression test fails on official v0.3.6 because
  the PQ layer's EDRMetadata is nil. It passes after the fix.
- The complete native kernel suite passes **801 tests, with 3 existing ignored
  cases and zero failures**. The three added tests cover PQ metadata/SDR reset,
  1000→4000-nit metadata updates with unchanged colorspace, retained metadata on
  identical frames, HLG clearing, and finite missing/invalid metadata fallbacks.
- The optimized native static library builds with macOS deployment target 13.0.
  The fixed arm64 native application and embedded Core library build and pass
  strict deep ad-hoc signature verification. The final relink removes the first
  build's deployment-version warnings from bundled C++ objects.
- Five final application playback runs pass: HEVC Main10/AAC, VP9/Opus,
  AV1/Opus, H.264 controls and separate H.264 EOF. Each has positive video/audio
  counts and an attached surface, with zero render/audio failures. Controls
  include pause/play, seek, rates 2.0/1.0 and window resize.
- The final PQ staircase run reaches Core natural EOF and records source
  BT.2020/PQ, mastering minimum 0.0001 and maximum 1000 nits, non-nil system
  tone-mapping metadata, and HDR10/PQ output headroom **2.0**, rather than the
  previous misleading 49.26 encoding-range value.

Complete logs, final library hashes and source identities are adjacent.
The native base is OcPlayer `888ccdd`; the Core base is `fa75810`; the native
renderer patch applies to the peeled v0.3.6 commit
`e38a511561cb30ca57bd370b944d2e99b12737c7`. The built adapter identifies the
modified renderer as `v0.3.6+macos.hdr.dev`.

## Luminance staircase evidence

The generated 640×360 lossless 10-bit HEVC fixture has eight uniform grayscale
bands at **50, 100, 203, 300, 400, 600, 800 and 1000 nits**. PQ code values are
computed directly from SMPTE ST 2084 and encoded into limited-range YUV; x265 VUI
explicitly signals BT.2020/PQ and the 1000-nit mastering range. An initial fixture
without complete VUI was rejected as a PQ test and remains in the local build
directory; its captures are not used for the comparison below.

The same Mac's compositor window capture gives these sRGB red-channel samples
at the centers of the eight bands, away from the controls:

| Capture | Samples | Distinct bands |
| --- | --- | ---: |
| Official v0.3.6 | 133, 182, 182, 182, 182, 182, 182, 182 | 2 |
| Fixed renderer | 80, 107, 132, 145, 155, 168, 176, 182 | 8 |

The previous path clips the upper seven bands to one value; the fixed path
preserves all eight ordered levels. This is evidence of compositor mapping and
highlight separation on this Mac, not a calibrated measurement of panel nits.
The source mastering range stays separate from the 10,000-nit PQ encoding
ceiling and the host-reported display headroom.

The original PNG captures are retained as `before-pq.png` and
`after-pq-visible.png`; no image was reduced or replaced in the report. Local
model inspection used only JPEG previews produced by codex-image-preview.

## Reproduce and artifacts

Use [the build instructions](../../macos-hdr.md). The new fixed application from
this run is at:

`/Users/jumusu/Documents/project/OcPlayer/.local-build/hdr-core-build-20261114/DerivedData/Build/Products/Debug/OcPlayer.app`

The complete build sources, native dependencies reference, test fixture, capture
helpers and preliminary attempts remain under the adjacent local `hdr-fix-20261114`
and `hdr-core-build-20261114` directories. The native renderer source edits also
remain in the attached `codex/macos-hdr-mapping` worktree; the patch in this Core
repository is the portable source change.

The user's `/Applications/OcPlayer.app` was not overwritten. The remaining
platform renderers, official release version pins and iOS slices are unchanged.
