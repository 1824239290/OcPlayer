# Supplemental license sources

These two upstream license files are bundled because the installed release archives omit standalone text. Other notices are read directly from the resolved Cargo/NuGet packages and the prepared Erika source by `Scripts/generate-license-catalog.ps1`.

- `Win2D.txt`: https://raw.githubusercontent.com/microsoft/Win2D/master/LICENSE.txt . Exact upstream MIT license text, retrieved 2026-11-16. Microsoft.Graphics.Win2D 1.4.0's `.nuspec` declares the legacy Microsoft EULA URL https://www.microsoft.com/web/webpi/eula/eula_win2d_10012014.htm , which now redirects to a general Microsoft Learn page. The catalog explicitly distinguishes the upstream MIT license from that package declaration.
- `alloc-stdlib.txt`: https://raw.githubusercontent.com/dropbox/rust-alloc-no-stdlib/master/LICENSE . Retrieved 2026-11-16. This is the upstream BSD 3-Clause license shared by `alloc-stdlib` / `alloc-no-stdlib`.

The generated application catalog embeds all notice text; runtime access does not require these build-source files or an internet connection.
