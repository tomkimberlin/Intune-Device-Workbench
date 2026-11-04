param([Parameter(Mandatory)][string]$RepositoryPath,[int]$ExpectedGraphReads=0,[Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
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
    public void PressF5() {
        Find("SearchBox").SetFocus();
        uint foregroundId;
        GetWindowThreadProcessId(GetForegroundWindow(),out foregroundId);
        if(foregroundId!=processId) throw new InvalidOperationException("Refusing keyboard input outside the owned demo process.");
        keybd_event(0x74,0,0,UIntPtr.Zero);
        keybd_event(0x74,0,2,UIntPtr.Zero);
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
    $driver.Invoke('BitLockerTabButton')
    Wait-Until {$driver.Shown('CopyRecoveryKeyButton')} 'BitLocker tab'
    Check ($driver.Enabled('CopyRecoveryKeyButton')) 'The real BitLocker tab exposes recovery for the selected demo device'
    $driver.Invoke('LapsTabButton')
    Wait-Until {$driver.Shown('CopyPasswordButton')} 'LAPS tab'
    Check ($driver.Enabled('CopyPasswordButton')) 'Returning to the real LAPS tab preserves its recovery controls'
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
    Check (@(Read-Calls).Count -eq $ExpectedGraphReads) 'No extra Graph work appears during close'
    $failed=@($checks|Where-Object {-not $_.Passed}).Count
    $result=[ordered]@{
        Commit=(& git -C $RepositoryPath rev-parse HEAD).Trim();PowerShell=$PSVersionTable.PSVersion.ToString()
        ExpectedGraphReads=$ExpectedGraphReads;ObservedGraphReads=$observedCalls.Count;GraphUris=$observedCalls
        InitialCounts=$initialCounts;AfterF5Counts=$afterCounts;Passed=$checks.Count-$failed;Failed=$failed;Checks=$checks
        Limits='Actual application process, WPF/UIA and keyboard input on disposable Windows. Graph replaced by isolated local module; no SDK, tenant, credentials, recovery or clipboard action.'
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
