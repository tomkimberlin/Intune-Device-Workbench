@echo off
setlocal

set "WORKBENCH_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%WORKBENCH_PWSH%" goto launch
set "WORKBENCH_PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if exist "%WORKBENCH_PWSH%" goto launch
for %%P in (pwsh.exe) do set "WORKBENCH_PWSH=%%~$PATH:P"
if not defined WORKBENCH_PWSH (
    echo PowerShell 7 is required but was not found.
    echo Install Microsoft PowerShell 7, then launch this utility again.
    pause
    exit /b 1
)

:launch
start "" "%WORKBENCH_PWSH%" -NoLogo -NoProfile -STA -WindowStyle Hidden -File "%~dp0IntuneDeviceWorkbench.ps1"
exit /b 0
