# Opt-in integration tests: overwrite the real clipboard with synthetic data only.
[CmdletBinding()]
param([switch]$AllowClipboardOverwrite)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $AllowClipboardOverwrite) {
    throw 'This native test replaces the current clipboard. Run with -AllowClipboardOverwrite only in a synthetic test session.'
}
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'Run this native test with pwsh.exe -NoProfile -STA.'
}
$AppRoot=Split-Path -Parent $PSScriptRoot
$ScratchPath=Join-Path ([IO.Path]::GetTempPath()) ('intune-workbench-native-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $ScratchPath
$helperSource=@"
param([switch]`$Hold)
`$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if (`$Hold) {
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Runtime.InteropServices;
public static class ClipboardHolder {
 [DllImport("user32.dll")] private static extern bool OpenClipboard(IntPtr handle);
 [DllImport("user32.dll")] private static extern bool CloseClipboard();
 public static void Hold(IntPtr handle, string directory) {
  if (!OpenClipboard(handle)) throw new InvalidOperationException("Unable to acquire the test clipboard lock.");
  try {
   File.WriteAllText(Path.Combine(directory,"holder-ready"),"ready");
   Stopwatch watch=Stopwatch.StartNew();
   while(!File.Exists(Path.Combine(directory,"holder-release"))) {
    if(watch.Elapsed.TotalSeconds>15) throw new TimeoutException("Clipboard holder timed out.");
    Thread.Sleep(25);
   }
  } finally {CloseClipboard();}
 }
}
'@
 `$holderWindow=[Windows.Window]::new()
 `$holderHandle=([Windows.Interop.WindowInteropHelper]::new(`$holderWindow)).EnsureHandle()
 try {[ClipboardHolder]::Hold(`$holderHandle,`$PSScriptRoot)}finally{`$holderWindow.Close()}
} else {
 [System.Windows.Clipboard]::SetText('Harmless synthetic clipboard replacement from another process')
}
"@
[IO.File]::WriteAllText((Join-Path $ScratchPath 'OtherProcessClipboard.ps1'),$helperSource)
try {
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Import-Module (Join-Path $AppRoot 'M365Workbench.Core.psm1') -Force
Add-Type -Path (Join-Path $AppRoot 'SecureClipboard.cs')
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SmokeClipboardInspection {
 [DllImport("user32.dll",SetLastError=true)] public static extern bool OpenClipboard(IntPtr owner);
 [DllImport("user32.dll")] public static extern bool CloseClipboard();
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern uint RegisterClipboardFormat(string name);
 [DllImport("user32.dll")] public static extern bool IsClipboardFormatAvailable(uint format);
 [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
 [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr memory);
 [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr memory);
 public static bool HasProtectionMarker(string name, bool dword) {
   uint format=RegisterClipboardFormat(name);
   if(!IsClipboardFormatAvailable(format) || !OpenClipboard(IntPtr.Zero)) return false;
   try { IntPtr data=GetClipboardData(format); if(data==IntPtr.Zero)return false;
     IntPtr pointer=GlobalLock(data); if(pointer==IntPtr.Zero)return false;
     try { return !dword || Marshal.ReadInt32(pointer)==0; }
     finally { GlobalUnlock(data); }
   } finally { CloseClipboard(); }
 }
}
"@
$tokens=$null; $parseErrors=$null
$mainAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $AppRoot 'IntuneDeviceWorkbench.ps1'),[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Source did not parse'}
foreach($functionName in @('Get-SensitiveClockNow','Get-DemoInventory','Clear-SecretDisplay','Update-ClipboardStatusForSelection','Copy-SelectedDeviceDetails','Complete-CredentialAction','Invoke-CredentialAction','Complete-BitLockerAction','Invoke-BitLockerAction')) {
 $functionAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true)
 . ([scriptblock]::Create($functionAst.Extent.Text))
}
# Off-screen controls and a real native owner HWND; no live UI automation or Graph.
$xamlAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml'},$true)
$reader=[Xml.XmlNodeReader]::new([xml]$xamlAst.Right.Expression.Value)
$window=[Windows.Markup.XamlReader]::Load($reader); $reader.Close()
foreach($match in [regex]::Matches($xamlAst.Right.Expression.Value,'x:Name="([^"]+)"')) {Set-Variable -Name $match.Groups[1].Value -Value $window.FindName($match.Groups[1].Value)}
$null=([Windows.Interop.WindowInteropHelper]::new($window)).EnsureHandle()
$settings=@{ClipboardClearSeconds=45;RevealSeconds=20;ExpectedAccount='laps-admin@contoso.onmicrosoft.com'}
$DemoMode=$true
$script:SensitiveClockOrigin=[DateTimeOffset]::UtcNow
$script:SensitiveClock=[Diagnostics.Stopwatch]::StartNew()
$script:CurrentOperation=$null; $script:PendingSecretRequest=$null; $script:LocalVerificationTask=$null
$script:CurrentCredential=$null; $script:CurrentBitLockerKey=$null
$script:CredentialExpiresAt=[DateTimeOffset]::MinValue; $script:BitLockerExpiresAt=[DateTimeOffset]::MinValue
$script:ClipboardClearAt=[DateTimeOffset]::MinValue; $script:ClipboardDeviceId=$null; $script:ClipboardKind=$null; $script:ClipboardRecoveryKeyId=$null
$script:ToastExpiresAt=[DateTimeOffset]::MinValue
$script:Results=[Collections.Generic.List[object]]::new()
$script:FixtureDevices=@(Get-DemoInventory)
$script:SelectedFixture=$FixtureDevices | Where-Object DeviceName -eq 'DEMO-DEVICE-ALPHA'
function Get-SelectedDevice {return $script:SelectedFixture}
function Restore-SecretActionControls {}
function Set-RecoveryActionFocus {param($Kind,$Action)}
function Set-AppStatus {param($Message,[switch]$Busy)}
function Show-Toast {param($Message,$Kind); $script:LastToastKind=$Kind}
function Set-PasswordStatus {param($Message,$DotColor,$TextColor);$PasswordCountdownText.Text=$Message}
function Set-BitLockerStatus {param($Message,$DotColor,$TextColor);$BitLockerCountdownText.Text=$Message}
function Process-OperationOutput {}
function Clear-SecretVerificationState {$script:VerificationRevoked=$true}
function Check([bool]$Condition,[string]$Name) {
 $script:Results.Add([pscustomobject]@{Name=$Name;Passed=$Condition})
 $label=if($Condition){'PASS'}else{'FAIL'}; Write-Output ($label+'  '+$Name)
}
function Set-OtherProcessText {
 & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -STA -File (Join-Path $ScratchPath 'OtherProcessClipboard.ps1')
 if($LASTEXITCODE -ne 0){throw 'Other-process clipboard writer failed'}
}
$tickAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$pollTimer' -and $n.Member.Extent.Text -eq 'Add_Tick'},$true)
$tickBody=$tickAst.Arguments[0].ScriptBlock.Extent.Text
$tick=[scriptblock]::Create($tickBody.Substring(1,$tickBody.Length-2))
$closingAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$window' -and $n.Member.Extent.Text -eq 'Add_Closing'},$true)
$closingBody=$closingAst.Arguments[0].ScriptBlock.Extent.Text
$closing=[scriptblock]::Create($closingBody.Substring(1,$closingBody.Length-2))
# Session registration and the live message hook are not installed by this harness.
Add-Type -Path (Join-Path $AppRoot 'WindowsSessionNotifications.cs')
$sessionWindowHandle=([Windows.Interop.WindowInteropHelper]::new($window)).Handle
$sessionWindowSource=[System.Windows.Interop.HwndSource]::FromHwnd($sessionWindowHandle)
$hookAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$sessionMessageHook'},$true)
. ([scriptblock]::Create($hookAst.Extent.Text))
$sessionWindowSource.AddHook($sessionMessageHook)
try {
 Clear-SecretDisplay
 Invoke-CredentialAction -Action Copy
 Check ([Windows.Clipboard]::GetText() -eq 'Demo-Only!Laps-2026' -and $script:ClipboardKind -eq 'LAPS') 'Production DemoMode LAPS Copy uses the real Windows clipboard'
 Copy-SelectedDeviceDetails
 $alphaDetails=Format-DeviceDetails $script:SelectedFixture
 Check ([Windows.Clipboard]::GetText() -eq $alphaDetails -and ($alphaDetails -split '\r?\n').Count -eq 5) 'Production details handler replaces synthetic LAPS with exactly five allowed metadata fields'
 Check ($script:ClipboardKind -eq 'DeviceDetails' -and $null -eq $script:ClipboardDeviceId -and $PasswordCountdownText.Text -eq 'Password remains hidden until requested') 'Details replace secret cleanup tracking and remove the old LAPS countdown'
 foreach($marker in @('ExcludeClipboardContentFromMonitorProcessing','CanIncludeInClipboardHistory','CanUploadToCloudClipboard')) {
  Check ([SmokeClipboardInspection]::HasProtectionMarker($marker,($marker -ne 'ExcludeClipboardContentFromMonitorProcessing'))) ('Real clipboard protection marker: '+$marker)
 }
 $script:SelectedFixture=$FixtureDevices | Where-Object DeviceName -eq 'DEMO-DEVICE-DELTA'
 Copy-SelectedDeviceDetails
 $deltaDetails=[Windows.Clipboard]::GetText()
 Check ($deltaDetails -eq (Format-DeviceDetails $script:SelectedFixture) -and $deltaDetails.Contains('Primary user: Unassigned') -and -not $deltaDetails.Contains('ashley.morgan')) 'Changing to the unassigned demo device copies its metadata without the previous user'
 $script:SelectedFixture=$FixtureDevices | Where-Object DeviceName -eq 'DEMO-DEVICE-BRAVO'
 Copy-SelectedDeviceDetails
 Check ([Windows.Clipboard]::GetText() -eq (Format-DeviceDetails $script:SelectedFixture) -and [Windows.Clipboard]::GetText().Contains('jason.reed@contoso.com')) 'Selection change copies the current demo device and UPN'
 $BitLockerKeySelector.Items.Clear()
 $null=$BitLockerKeySelector.Items.Add([pscustomobject]@{Id='a2222222-2222-4222-8222-222222222222';CreatedDateTime=[DateTimeOffset]::Now;VolumeType='operatingSystemVolume'})
 $BitLockerKeySelector.SelectedIndex=0
 Invoke-BitLockerAction -Action Copy
 Check ([Windows.Clipboard]::GetText() -eq '111111-222222-333333-444444-555555-666666-777777-888888' -and $script:ClipboardKind -eq 'BitLocker') 'Details followed by production DemoMode BitLocker Copy replaces details with the synthetic key'
 Copy-SelectedDeviceDetails
 Check ([Windows.Clipboard]::GetText() -eq (Format-DeviceDetails $script:SelectedFixture) -and $BitLockerCountdownText.Text -eq 'Recovery key remains hidden until requested') 'Details replace the synthetic BitLocker key and its countdown'
 # Run the actual production timer for a full default lifetime on the real clipboard.
 $copyWatch=[Diagnostics.Stopwatch]::StartNew()
 while($copyWatch.Elapsed.TotalSeconds -lt 46) { & $tick; Start-Sleep -Milliseconds 125 }
 Check (-not [Windows.Clipboard]::ContainsText() -and $script:ClipboardKind -eq $null -and $script:ClipboardClearAt -eq [DateTimeOffset]::MinValue) 'Production timer clears owned details after the real 45-second default interval'
 Copy-SelectedDeviceDetails
 Set-OtherProcessText
 $script:ClipboardClearAt=(Get-SensitiveClockNow).AddMilliseconds(-1)
 & $tick
 Check ([Windows.Clipboard]::GetText() -eq 'Harmless synthetic clipboard replacement from another process') 'Expired details cleanup preserves harmless text written by a different process'
 Copy-SelectedDeviceDetails
 $closingArgs=[ComponentModel.CancelEventArgs]::new()
 & $closing $window $closingArgs
 Check (-not $closingArgs.Cancel -and -not [Windows.Clipboard]::ContainsText()) 'The production normal-close callback clears owned details on the real clipboard'
 Copy-SelectedDeviceDetails
 Set-OtherProcessText
 $closingArgs=[ComponentModel.CancelEventArgs]::new()
 & $closing $window $closingArgs
 Check (-not $closingArgs.Cancel -and [Windows.Clipboard]::GetText() -eq 'Harmless synthetic clipboard replacement from another process') 'The production normal-close callback preserves newer text from a different process'
 # Invoke the production session callback with synthetic events only; no desktop lock/disconnect.
 $hookAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$sessionMessageHook'},$true)
 . ([scriptblock]::Create($hookAst.Extent.Text))
 Copy-SelectedDeviceDetails
 Invoke-CredentialAction -Action Reveal
 $script:VerificationRevoked=$false; $handled=$false
 $null=$sessionMessageHook.Invoke($sessionWindowHandle,0x02B1,[IntPtr]7,[IntPtr]::Zero,[ref]$handled)
 Check ($script:VerificationRevoked -and $PasswordText.Text -eq '••••••••••••••••' -and $script:ClipboardKind -eq $null) 'Production synthetic SessionLock callback hides revealed demo material and resets tracking'
 Check (-not [Windows.Clipboard]::ContainsText()) 'Production synthetic SessionLock callback clears owned details on the real clipboard'
 Copy-SelectedDeviceDetails
 Set-OtherProcessText
 $handled=$false
 $null=$sessionMessageHook.Invoke($sessionWindowHandle,0x02B1,[IntPtr]4,[IntPtr]::Zero,[ref]$handled)
 Check ([Windows.Clipboard]::GetText() -eq 'Harmless synthetic clipboard replacement from another process') 'Production synthetic disconnect callback preserves newer text from another process'
 # Hold the actual clipboard lock in a second process, then exercise retry and close behavior.
 Copy-SelectedDeviceDetails
 $holder=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo','-NoProfile','-STA','-File',('"'+(Join-Path $ScratchPath 'OtherProcessClipboard.ps1')+'"'),'-Hold') -WindowStyle Hidden -PassThru
 try {
  $readyWatch=[Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath (Join-Path $ScratchPath 'holder-ready'))) {
   if ($holder.HasExited -or $readyWatch.Elapsed.TotalSeconds -gt 5) {throw 'Clipboard holder failed to become ready.'}
   Start-Sleep -Milliseconds 25
  }
  $busyReported=$false
  try {$null=[M365Workbench.Security.SecureClipboard]::ClearIfUnchanged($false)} catch [ComponentModel.Win32Exception] {$busyReported=$true}
  Check $busyReported 'Real native clipboard contention is reported for nonblocking cleanup'
  $closingArgs=[ComponentModel.CancelEventArgs]::new()
  & $closing $window $closingArgs
  Check $closingArgs.Cancel 'The production close callback defers closing while owned clipboard cleanup is busy'
 } finally {
  [IO.File]::WriteAllText((Join-Path $ScratchPath 'holder-release'),'release')
  if (-not $holder.WaitForExit(5000)) {$holder.Kill(); throw 'Clipboard holder did not release its test lock.'}
  $holder.Dispose()
 }
 & $tick
 Check (-not [Windows.Clipboard]::ContainsText() -and $script:ClipboardKind -eq $null) 'The production timer retries and clears owned data after real clipboard contention ends'
 # Leave no synthetic recovery value or metadata on the clipboard.
 [M365Workbench.Security.SecureClipboard]::SetSensitiveText('Synthetic smoke test cleanup',([Windows.Interop.WindowInteropHelper]::new($window)).Handle)
 $null=[M365Workbench.Security.SecureClipboard]::ClearIfUnchanged()
 $passed=@($Results | Where-Object Passed).Count; $failed=@($Results | Where-Object {-not $_.Passed}).Count
 Write-Output "$passed passed; $failed failed"
 if([Windows.Clipboard]::GetText() -eq 'Synthetic smoke test cleanup'){[Windows.Clipboard]::Clear()}
 if($failed){exit 1}
} finally {
 try {$null=[M365Workbench.Security.SecureClipboard]::ClearIfUnchanged()}catch{}
 Clear-SecretDisplay
 $window.Close()
}
} finally {
    # The directory is a fresh, task-specific child of the system temporary directory.
    $resolvedScratch=[IO.Path]::GetFullPath($ScratchPath)
    $resolvedTemp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolvedScratch.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedScratch) -notlike 'intune-workbench-native-*') {
        throw 'Refusing cleanup outside the native test temporary directory.'
    }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}