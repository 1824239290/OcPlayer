# Native OcPlayer Core

This directory is reserved for platform-specific native artifacts produced
from the `OcPlayer-Core` release pipeline. Do not commit generated DLLs or
import libraries here. Development builds should copy `ocp_ffi.dll` beside the
WinUI executable; release packaging will include the signed x64/ARM64 outputs.
