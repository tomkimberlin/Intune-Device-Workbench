@echo off
rem Compatibility entry point for existing shortcuts and command lines.
call "%~dp0Launch-IntuneDeviceWorkbench.cmd"
exit /b %errorlevel%
