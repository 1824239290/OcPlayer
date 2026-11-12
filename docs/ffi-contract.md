# Windows adapter FFI contract

`OcPlayer.CoreAdapter` mirrors the C ABI from `OcPlayer-Core/include/ocplayer_core.h`.
All native strings are UTF-8 and are released through `ocp_string_free`; the
managed wrapper owns no native pointer after decoding a response or event.

The WinUI 3 application currently contains the P0 bootstrap only. The P1
renderer integration will bind the window's `HWND` and DirectComposition
surface through `IWindowsPlayerSurface`, then call `RenderTick` from the
display/render clock.

