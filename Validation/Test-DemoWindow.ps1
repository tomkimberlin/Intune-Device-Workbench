param([Parameter(Mandatory)][string]$RepositoryPath,[int]$ExpectedGraphReads=0,[Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'This full-window fixture may run only on its disposable GitHub Actions runner.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,UIAutomationClient,UIAutomationTypes
Add-Type -ReferencedAssemblies @('UIAutomationClient.dll','UIAutomationTypes.dll','System.Runtime.dll') -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Automation;
public sealed class DemoWindowDriver {
    private readonly AutomationElement root;
    private readonly int processId;
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")] private static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll")] private static extern IntPtr GetClipboardData(uint format);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr memory);
    public DemoWindowDriver(int id) {
        processId=id;
        root=AutomationElement.RootElement.FindFirst(TreeScope.Children,new PropertyCondition(AutomationElement.ProcessIdProperty,id));
        if(root==null) throw new InvalidOperationException("Demo window not available yet.");
    }
    private AutomationElement Find(string id) {
        return root.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.AutomationIdProperty,id));
    }
    public string Name(string id) { var e=Find(id); return e==null ? "MISSING" : e.Current.Name; }
    public bool Enabled(string id) { var e=Find(id); return e!=null && e.Current.IsEnabled; }
    public bool Shown(string id) { var e=Find(id); return e!=null && !e.Current.IsOffscreen; }
    public void Search(string text) { ((ValuePattern)Find("SearchBox").GetCurrentPattern(ValuePattern.Pattern)).SetValue(text); }
    public void Invoke(string id) { ((InvokePattern)Find(id).GetCurrentPattern(InvokePattern.Pattern)).Invoke(); }
    private void Press(params byte[] keys) {
        Find("SearchBox").SetFocus();
        uint foregroundId;
        GetWindowThreadProcessId(GetForegroundWindow(),out foregroundId);
        if(foregroundId!=processId) throw new InvalidOperationException("Refusing keyboard input outside the owned demo process.");
        try { foreach(byte key in keys) keybd_event(key,0,0,UIntPtr.Zero); }
        finally { for(int i=keys.Length-1;i>=0;i--) keybd_event(keys[i],0,2,UIntPtr.Zero); }
    }
    public void PressF5() { Press(0x74); }
    public void PressEscape() { Press(0x1b); }
    public void PressCopyShortcut() { Press(0x11,0x10,0x43); }
    public static string ClipboardText() {
        if(!OpenClipboard(IntPtr.Zero)) throw new InvalidOperationException("Synthetic clipboard is busy.");
        try {
            IntPtr data=GetClipboardData(13);
            if(data==IntPtr.Zero) return "";
            IntPtr pointer=GlobalLock(data);
            if(pointer==IntPtr.Zero) throw new InvalidOperationException("Synthetic clipboard cannot be read.");
            try { return Marshal.PtrToStringUni(pointer); }
            finally { GlobalUnlock(data); }
        } finally { CloseClipboard(); }
    }
    public void Close() { ((WindowPattern)root.GetCurrentPattern(WindowPattern.Pattern)).Close(); }
}
'@
$temp=Join-Path ([IO.Path]::GetTempPath()) ('intune-demo-window-'+[guid]::NewGuid().ToString('N'))
$moduleRoot=Join-Path $temp 'Modules'
$module=Join-Path $moduleRoot 'Microsoft.Graph.Authentication'
$null=New-Item -ItemType Directory -Path $module -Force
$callsPath=Join-Path $temp 'synthetic-graph-calls.txt'
# Only this fake Graph module and PowerShell's own modules are discoverable in the
# child. A new process has no SDK session; an unexpected read cannot reach Graph.
[IO.File]::WriteAllText((Join-Path $module 'Microsoft.Graph.Authentication.psd1'),@'
@{RootModule='Microsoft.Graph.Authentication.psm1';ModuleVersion='2.38.0';GUID='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';FunctionsToExport=@('Invoke-MgGraphRequest')}
'@)
[IO.File]::WriteAllText((Join-Path $module 'Microsoft.Graph.Authentication.psm1'),@'
function Invoke-MgGraphRequest {
    param($Method,$Uri,$OutputType,$ErrorAction)
    if($Method -ne 'GET'){throw 'Only synthetic reads are supported.'}
    [IO.File]::AppendAllText($env:INTUNE_DEMO_PROBE_LOG,[string]$Uri+[Environment]::NewLine)
    [pscustomobject]@{value=@()}
}
Export-ModuleMember -Function Invoke-MgGraphRequest
'@)
$process=$null;$driver=$null;$checks=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Name){
    $checks.Add([pscustomobject]@{Name=$Name;Passed=$Condition})
    "$(if($Condition){'PASS'}else{'FAIL'}) $Name"
}
function Wait-Until([scriptblock]$Condition,[string]$Description){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $lastError='No exception; condition remained false.'
    do {
        if($process.HasExited){throw "App exited during $Description."}
        try {if(& $Condition){return}} catch {$lastError=[string]$_}
        Start-Sleep -Milliseconds 100
    }while($watch.Elapsed.TotalSeconds -lt 15)
    $process.Refresh()
    throw "Timed out during $Description. Last condition error: $lastError. Owned process window: $($process.MainWindowTitle); handle: $($process.MainWindowHandle)."
}
function Read-Calls { if([IO.File]::Exists($callsPath)){[IO.File]::ReadAllLines($callsPath)} }
try {
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute=$false
    $start.RedirectStandardError=$true
    $start.RedirectStandardOutput=$true
    $start.WorkingDirectory=$RepositoryPath
    $start.Environment['PSModulePath']=$moduleRoot+[IO.Path]::PathSeparator+(Join-Path $PSHOME 'Modules')
    $start.Environment['INTUNE_DEMO_PROBE_LOG']=$callsPath
    foreach($arg in @('-NoLogo','-NoProfile','-STA','-File',(Join-Path $RepositoryPath 'IntuneDeviceWorkbench.ps1'),'-DemoMode')){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync()
    $stderr=$process.StandardError.ReadToEndAsync()
    Wait-Until {$script:driver=[DemoWindowDriver]::new($process.Id); $true} 'visible app startup'
    Wait-Until {$driver.Name('DeviceCountText') -match '^[1-9][0-9]* shown'} 'demo inventory'
    $initialCounts=$driver.Name('DeviceCountText')
    Check (-not $driver.Enabled('RefreshButton')) 'Actual demo window disables Refresh'
    Check (@(Read-Calls).Count -eq 0) 'Actual demo startup makes no synthetic Graph request'

    $driver.Search('  DEMO-DEVICE-BRAVO  ')
    Wait-Until {$driver.Name('DeviceCountText') -match '^1 shown' -and $driver.Name('DetailDeviceName') -eq 'DEMO-DEVICE-BRAVO'} 'search and selection'
    Check ($driver.Name('DetailDeviceName') -eq 'DEMO-DEVICE-BRAVO') 'Typing in the real search field selects the matching demo device'
    $syntheticPassword='Demo-Only!Laps-2026'
    $syntheticKey='111111-222222-333333-444444-555555-666666-777777-888888'
    $driver.Invoke('RevealPasswordButton')
    Wait-Until {$driver.Name('PasswordText') -eq $syntheticPassword} 'synthetic password reveal'
    Check ($driver.Name('PasswordText') -eq $syntheticPassword) 'The actual Reveal button exposes only the built-in synthetic password'
    $driver.PressEscape()
    Wait-Until {$driver.Name('PasswordText') -eq '••••••••••••••••'} 'Escape hiding the synthetic password'
    Check ($driver.Name('PasswordText') -eq '••••••••••••••••') 'Actual Escape keyboard input hides the revealed password'
    $expectedAccount=$driver.Name('AccountNameText')
    $driver.Invoke('CopyAccountButton')
    Wait-Until {[DemoWindowDriver]::ClipboardText() -eq $expectedAccount} 'synthetic username copy'
    Check ([DemoWindowDriver]::ClipboardText() -eq $expectedAccount) 'The real username button copies the displayed demo account'
    $driver.Invoke('BitLockerTabButton')
    Wait-Until {$driver.Shown('CopyRecoveryKeyButton')} 'BitLocker tab'
    Check ($driver.Enabled('CopyRecoveryKeyButton')) 'The real BitLocker tab exposes recovery for the selected demo device'
    $driver.PressCopyShortcut()
    Wait-Until {[DemoWindowDriver]::ClipboardText() -eq $syntheticKey} 'BitLocker keyboard copy'
    Check ([DemoWindowDriver]::ClipboardText() -eq $syntheticKey) 'Actual Ctrl Shift C copies the active BitLocker tab synthetic key'
    $driver.Invoke('LapsTabButton')
    Wait-Until {$driver.Shown('CopyPasswordButton')} 'LAPS tab'
    Check ($driver.Enabled('CopyPasswordButton')) 'Returning to the real LAPS tab preserves its recovery controls'
    $driver.PressCopyShortcut()
    Wait-Until {[DemoWindowDriver]::ClipboardText() -eq $syntheticPassword} 'LAPS keyboard copy'
    Check ([DemoWindowDriver]::ClipboardText() -eq $syntheticPassword) 'Actual Ctrl Shift C copies the active LAPS tab synthetic password'
    $driver.Invoke('CopyDeviceDetailsButton')
    Wait-Until {[DemoWindowDriver]::ClipboardText().Contains('DEMO-DEVICE-BRAVO')} 'device details copy'
    $details=[DemoWindowDriver]::ClipboardText()
    Check (-not $details.Contains($syntheticPassword) -and -not $details.Contains($syntheticKey)) 'The real Copy details button replaces the secret with metadata only'
    $driver.Search('')
    Wait-Until {$driver.Name('DeviceCountText') -eq $initialCounts} 'clearing search'
    Check (@(Read-Calls).Count -eq 0) 'Search and tab changes stay inside the synthetic workspace'

    $driver.PressF5()
    if($ExpectedGraphReads -gt 0){Wait-Until {@(Read-Calls).Count -ge $ExpectedGraphReads} 'baseline Graph boundary reproduction'}
    Start-Sleep -Seconds 2
    $observedCalls=@(Read-Calls)
    $afterCounts=$driver.Name('DeviceCountText')
    Check ($observedCalls.Count -eq $ExpectedGraphReads) "Actual F5 reaches $ExpectedGraphReads synthetic Graph reads as expected for this revision"
    if($ExpectedGraphReads -eq 0){
        Check ($afterCounts -eq $initialCounts -and -not $driver.Enabled('RefreshButton')) 'Fixed demo F5 preserves the inventory and disabled Refresh control'
    }
    else {
        Check ($afterCounts -match '^0 shown') 'Baseline F5 replaces the demo inventory with the synthetic live-worker response'
    }
    $driver.Close()
    Check ($process.WaitForExit(5000) -and $process.ExitCode -eq 0) 'Actual demo window closes normally'
    Check ([DemoWindowDriver]::ClipboardText() -eq '') 'Closing the actual app clears its owned synthetic clipboard contents'
    Check (@(Read-Calls).Count -eq $ExpectedGraphReads) 'No extra Graph work appears during close'
    $failed=@($checks|Where-Object {-not $_.Passed}).Count
    $result=[ordered]@{
        Commit=(& git -C $RepositoryPath rev-parse HEAD).Trim();PowerShell=$PSVersionTable.PSVersion.ToString()
        ExpectedGraphReads=$ExpectedGraphReads;ObservedGraphReads=$observedCalls.Count;GraphUris=$observedCalls
        InitialCounts=$initialCounts;AfterF5Counts=$afterCounts;Passed=$checks.Count-$failed;Failed=$failed;Checks=$checks
        Limits='Actual application process, WPF/UIA, keyboard input and synthetic recovery/clipboard actions on disposable Windows. Graph replaced by isolated local module; no SDK, tenant, credentials or production recovery.'
    }
    [IO.File]::WriteAllText($OutputPath,($result|ConvertTo-Json -Depth 5))
    "$($result.Passed) passed; $failed failed"
    if($failed){throw 'Full-window demo smoke checks failed.'}
}
catch {
    if($null -ne $process -and $process.HasExited){
        if($stderr.IsCompleted){Write-Host $stderr.Result}
        if($stdout.IsCompleted){Write-Host $stdout.Result}
    }
    throw
}
finally {
    if($null -ne $process){
        if(-not $process.HasExited){try{$driver.Close()}catch{};if(-not $process.WaitForExit(2000)){$process.Kill();$process.WaitForExit()}}
        $process.Dispose()
    }
    Remove-Item -LiteralPath $temp -Recurse -Force
}
