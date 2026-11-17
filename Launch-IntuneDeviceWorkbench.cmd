@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "WORKBENCH_PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined ProgramFiles if exist "%WORKBENCH_PWSH%" goto launch
set "WORKBENCH_PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if defined LOCALAPPDATA if exist "%WORKBENCH_PWSH%" goto launch
rem Custom installations use the GUI launcher's absolute-directory lookup.
set "WORKBENCH_ROOT=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command ^
    "$ErrorActionPreference = 'Stop';" ^
    "Add-Type -Path (Join-Path $env:WORKBENCH_ROOT 'assets\M365Workbench.Launcher.cs') -ReferencedAssemblies System.dll,System.Windows.Forms.dll;" ^
    "exit [M365Workbench.Launcher]::Main([string[]](Join-Path $env:WORKBENCH_ROOT 'IntuneDeviceWorkbench.ps1'))"
exit /b %errorlevel%

:launch
start "" "%WORKBENCH_PWSH%" -NoLogo -NoProfile -STA -WindowStyle Hidden -File "%~dp0IntuneDeviceWorkbench.ps1"
exit /b 0
