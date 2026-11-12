# Windows development

The Windows solution targets WinUI 3 with .NET 8 and Windows App SDK. Build on
Windows with Visual Studio 2022 (Windows App SDK workload), then place the
matching `ocp_ffi.dll` beside the application executable.

The current macOS workstation does not have `dotnet` or Visual Studio, so the
WinUI projects are source-checked only here. Rust core tests run locally with a
target directory on the local filesystem because the NAS volume does not
support Cargo incremental-lock files.
