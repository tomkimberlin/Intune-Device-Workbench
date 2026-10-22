# Compatibility entry point for existing shortcuts and command lines.
[CmdletBinding()]
param(
    [switch]$DemoMode,
    [switch]$NoAutoConnect,
    [string]$RenderPreviewPath,
    [ValidateSet('Workspace', 'MicrosoftVerification', 'LapsClipboard', 'BitLockerClipboard', 'InventoryRefreshing')]
    [string]$RenderPreviewState = 'Workspace'
)

& (Join-Path $PSScriptRoot 'IntuneDeviceWorkbench.ps1') @PSBoundParameters
if (-not $?) { exit 1 }
