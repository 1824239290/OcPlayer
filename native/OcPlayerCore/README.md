# Native OcPlayer Core

`Scripts/build-windows.ps1` writes the generated `ocp_ffi.dll` and
`erika_capi.dll` into the `x64/` or `ARM64/` subdirectory. MSBuild copies both
beside the WinUI executable and into publish output. Generated native files and
build receipts are ignored by Git. Development builds are unsigned; release
signing and packaging require separate verification.
