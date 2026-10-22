# Compatibility entry point for existing automation.
& (Join-Path $PSScriptRoot 'Test-IntuneDeviceWorkbench.ps1')
if (-not $?) { exit 1 }
