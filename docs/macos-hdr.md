# macOS HDR presentation fix

OcPlayer-Core owns business state and policies. Its Core-enabled macOS client
uses the native OcPlayer UI and liberika renderer. The HDR clipping fix therefore
lives in the native renderer; the versioned patch and a reproducible build entry
point are retained here with the Core delivery.

## Cause and change

liberika v0.3.6 presents PQ-coded video through a floating-point CAMetalLayer
with an ITU-R 2100 PQ color space. Its shader intentionally delegates tone mapping
to the display compositor. It never supplied CAMetalLayer.EDRMetadata, however,
so Core Animation could clamp highlights above the screen's available EDR range.

The patch supplies CAEDRMetadata with the source's mastering minimum/maximum
luminance before requesting a drawable. The optical output scale is 10,000 for
the PQ encoding. Missing or invalid mastering values use finite HDR defaults.
Metadata changes update even when primaries/transfer remain unchanged; identical
frames retain the metadata object. Output reconfiguration and the already mapped
HLG path clear PQ metadata, preventing stale or double mapping.

Output diagnostics now report the negotiated mode's headroom instead of labeling
PQ's 10,000/203 encoding range as the screen's active headroom. The PQ encoding
ceiling remains 10,000 nits; it is separate from source and display luminance.

Patch: `patches/liberika/v0.3.6-macos-hdr.patch`, based on the peeled v0.3.6 commit
`e38a511561cb30ca57bd370b944d2e99b12737c7`.

## Build the Core-enabled fixed application

Run from this repository:

```sh
Scripts/build-macos-hdr-fixed.sh /path/to/OcPlayer /path/to/liberika /new/output
```

The liberika checkout must contain the v0.3.6 tag and its compatible bundled
native dependencies under third_party/dist. The script refuses an existing
output directory and an unexpected tag, clones both source repositories, applies
the patch, builds the arm64 macOS native archive, and installs it only into the
cloned native client's XCFramework. It builds/embeds Core and verifies the app's
signature. No source checkout or installed application is overwritten. The
generated native adapter reports `v0.3.6+macos.hdr.dev` so the patched binary is
distinguishable from the official release. Core and native library hashes and
source identities are recorded in build-receipt.json.

This is a local macOS arm64 delivery. Official release pins, the iOS slices and
Windows rendering are unchanged. A downstream official release can incorporate
the native patch and replace this local packaging step.

Validation and the before/after PQ staircase evidence are recorded in
[the HDR report](validation/2026-11-14-macos-hdr/README.md).
