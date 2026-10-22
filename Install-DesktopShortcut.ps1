[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appPath = Join-Path $PSScriptRoot 'IntuneDeviceWorkbench.ps1'
$iconPath = Join-Path $PSScriptRoot 'assets\M365Workbench.ico'
$shellIdentityPath = Join-Path $PSScriptRoot 'assets\WindowsShellIdentity.cs'
$launcherBuildPath = Join-Path $PSScriptRoot 'assets\Build-Launcher.ps1'
$launcherDirectory = Join-Path $env:LOCALAPPDATA 'M365Workbench'
$launcherPath = Join-Path $launcherDirectory 'M365Workbench.Launcher.exe'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath 'Intune Device Workbench.lnk'
$appUserModelId = 'M365Workbench.Desktop'

if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw "Application icon not found: $iconPath"
}
if (-not (Test-Path -LiteralPath $launcherBuildPath -PathType Leaf)) {
    throw "Launcher build script not found: $launcherBuildPath"
}
if (-not (Test-Path -LiteralPath $shellIdentityPath -PathType Leaf)) {
    throw "Windows shell identity helper not found: $shellIdentityPath"
}

if ($null -eq ('M365Workbench.WindowsShellIdentity' -as [type])) {
    Add-Type -Path $shellIdentityPath
}

$null = New-Item -ItemType Directory -Path $launcherDirectory -Force
& $launcherBuildPath -OutputPath $launcherPath | Out-Null

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $launcherPath
$shortcut.Arguments = "`"$appPath`""
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Intune Device Workbench'
$shortcut.IconLocation = "$launcherPath,0"
$shortcut.WindowStyle = 1
$shortcut.Save()
$null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
$null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
$shortcut = $null
$shell = $null
[GC]::Collect()
[GC]::WaitForPendingFinalizers()

[M365Workbench.WindowsShellIdentity]::SetShortcutAppId($shortcutPath, $appUserModelId)
[M365Workbench.WindowsShellIdentity]::NotifyShortcutChanged($shortcutPath)

Write-Output $shortcutPath
