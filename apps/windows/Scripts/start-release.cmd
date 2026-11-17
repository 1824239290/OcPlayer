@echo off
setlocal
rem ExecutionPolicy applies to this process only; no user/system policy changes.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-windows.ps1" -Configuration Release -Platform x64
if errorlevel 1 (
    echo OcPlayer failed to start. See the error above.
    pause
    exit /b 1
)
