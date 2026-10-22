[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourcePath = Join-Path $PSScriptRoot 'M365Workbench.Launcher.cs'
$iconPath = Join-Path $PSScriptRoot 'M365Workbench.ico'
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Launcher source not found: $sourcePath"
}
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw "Launcher icon not found: $iconPath"
}

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compilerPath = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($compilerPath)) {
    throw 'The Windows .NET Framework C# compiler was not found.'
}

$resolvedOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
}

$compilerOutput = & $compilerPath `
    '/nologo' `
    '/target:winexe' `
    '/platform:anycpu' `
    '/optimize+' `
    "/out:$resolvedOutputPath" `
    "/win32icon:$iconPath" `
    '/reference:System.dll' `
    '/reference:System.Core.dll' `
    '/reference:System.Windows.Forms.dll' `
    $sourcePath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "The Intune Device Workbench launcher could not be built.`n$($compilerOutput -join [Environment]::NewLine)"
}

$bytes = [IO.File]::ReadAllBytes($resolvedOutputPath)
if ($bytes.Length -lt 256) {
    throw 'The generated launcher is not a valid Windows executable.'
}
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
$subsystem = [BitConverter]::ToUInt16($bytes, $peOffset + 24 + 68)
if ($subsystem -ne 2) {
    throw "The generated launcher does not use the Windows GUI subsystem (found $subsystem)."
}

Write-Output $resolvedOutputPath
