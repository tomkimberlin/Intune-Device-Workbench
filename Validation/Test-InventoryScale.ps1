param([Parameter(Mandatory)][string]$OutputPath,[int[]]$DeviceCounts=@(6,3000,10000))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Run this synthetic desktop probe only in disposable CI.'}
$repository=Split-Path $PSScriptRoot
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,WindowsBase
Add-Type -ReferencedAssemblies @('UIAutomationClient','UIAutomationTypes','WindowsBase','System.Runtime','System.Collections','System.Threading') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Windows.Automation;
public sealed class InventoryScaleDriver {
    private readonly AutomationElement root;
    private readonly Dictionary<string,AutomationElement> controls = new Dictionary<string,AutomationElement>();
    public InventoryScaleDriver(int processId) {
        root=AutomationElement.RootElement.FindFirst(TreeScope.Children,new PropertyCondition(AutomationElement.ProcessIdProperty,processId));
        if(root==null) throw new InvalidOperationException("Owned app window is not ready.");
    }
    private AutomationElement Find(string id) {
        AutomationElement element;
        if(controls.TryGetValue(id,out element)) return element;
        element=root.FindFirst(TreeScope.Descendants,new PropertyCondition(AutomationElement.AutomationIdProperty,id));
        if(element==null) throw new InvalidOperationException("Missing app control: "+id);
        controls.Add(id,element);return element;
    }
    public string Name(string id) { return Find(id).Current.Name; }
    public void Search(string query) { ((ValuePattern)Find("SearchBox").GetCurrentPattern(ValuePattern.Pattern)).SetValue(query); }
    public void IncludeAll() {
        var toggle=(TogglePattern)Find("OnlyReadyCheckBox").GetCurrentPattern(TogglePattern.Pattern);
        if(toggle.Current.ToggleState==ToggleState.On) toggle.Toggle();
    }
    public void Close() { ((WindowPattern)root.GetCurrentPattern(WindowPattern.Pattern)).Close(); }
}
'@
$temp=Join-Path $env:RUNNER_TEMP ('intune-scale-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $temp
$copy=Join-Path $temp 'application'
$archive=Join-Path $temp 'source.zip'
& git -C $repository archive --format=zip --output=$archive HEAD
if($LASTEXITCODE){throw 'Could not copy committed application sources.'}
Expand-Archive $archive -DestinationPath $copy
$app=Join-Path $copy 'IntuneDeviceWorkbench.ps1'
$original=[IO.File]::ReadAllText($app)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($original,[ref]$tokens,[ref]$errors)
$replacements=[Collections.Generic.List[object]]::new()
foreach($name in @('Get-DemoInventory','Set-DeviceInventory','Refresh-DeviceFilter')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if($null -eq $node){throw "Missing production function $name"}
    $renamed=$node.Extent.Text.Replace("function $name {","function ${name}Original {")
    $wrapper=switch($name) {
        'Get-DemoInventory' {@'
function Get-DemoInventory {
    $seed=@(Get-DemoInventoryOriginal)
    for($index=0;$index -lt [int]$env:INTUNE_SCALE_COUNT;$index++) {
        $row=$seed[$index % $seed.Count].PSObject.Copy()
        $row.EntraDeviceId='aaaaaaaa-1111-4111-8111-'+($index+1).ToString('x12')
        $row.DeviceName='DEMO-DEVICE-'+($index+1).ToString('D6')
        $row.SearchText=($row.DeviceName+' '+$row.PrimaryUser+' '+$row.SerialNumber).ToLowerInvariant()
        $row
    }
}
'@}
        'Set-DeviceInventory' {@'
function Set-DeviceInventory {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Devices)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Set-DeviceInventoryOriginal -Devices $Devices
    $elapsed=$watch.Elapsed.TotalMilliseconds
    [IO.File]::AppendAllText($env:INTUNE_SCALE_METRICS,(@{Operation='ApplyInventory';Milliseconds=$elapsed;Rows=$Devices.Count}|ConvertTo-Json -Compress)+[Environment]::NewLine)
}
'@}
        'Refresh-DeviceFilter' {@'
function Refresh-DeviceFilter {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Refresh-DeviceFilterOriginal
    $elapsed=$watch.Elapsed.TotalMilliseconds
    [IO.File]::AppendAllText($env:INTUNE_SCALE_METRICS,(@{Operation='Filter';Milliseconds=$elapsed;Query=$SearchBox.Text}|ConvertTo-Json -Compress)+[Environment]::NewLine)
}
'@}
    }
    $replacements.Add(@{Start=$node.Extent.StartOffset;End=$node.Extent.EndOffset;Text=$renamed+"`n"+$wrapper})
}
foreach($replacement in $replacements|Sort-Object Start -Descending){$original=$original.Substring(0,$replacement.Start)+$replacement.Text+$original.Substring($replacement.End)}
[IO.File]::WriteAllText($app,$original)
$results=[Collections.Generic.List[object]]::new()
$process=$null
try {
    foreach($count in $DeviceCounts) {
        if($count -lt 6 -or $count -gt 10000){throw 'Unsupported synthetic count.'}
        $metricPath=Join-Path $temp "metrics-$count.jsonl"
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$copy
        $start.Environment['PSModulePath']=Join-Path $PSHOME 'Modules'
        $start.Environment['INTUNE_SCALE_COUNT']=[string]$count
        $start.Environment['INTUNE_SCALE_METRICS']=$metricPath
        foreach($arg in @('-NoLogo','-NoProfile','-STA','-File',$app,'-DemoMode')){$start.ArgumentList.Add($arg)}
        $launch=[Diagnostics.Stopwatch]::StartNew()
        $process=[Diagnostics.Process]::Start($start)
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $driver=$null
        do {
            if($process.HasExited){throw "Synthetic app exited: $($stderr.Result) $($stdout.Result)"}
            try {$driver=[InventoryScaleDriver]::new($process.Id);$ready=$driver.Name('DeviceCountText') -like "* $count total"}catch{$ready=$false}
            if(-not $ready){[Threading.Thread]::Sleep(50)}
        }while(-not $ready -and $launch.Elapsed.TotalSeconds -lt 45)
        if(-not $ready){throw 'Large inventory startup timed out.'}
        $launchMs=$launch.Elapsed.TotalMilliseconds
        $driver.IncludeAll()
        $until=[Diagnostics.Stopwatch]::StartNew()
        while($driver.Name('DeviceCountText') -notlike "$count shown*" -and $until.Elapsed.TotalSeconds -lt 10){[Threading.Thread]::Sleep(25)}
        if($driver.Name('DeviceCountText') -notlike "$count shown*"){throw 'Include-all count was incorrect.'}
        $queries=@('DEMO-DEVICE-000001','zz-no-such-computer','',('DEMO-DEVICE-'+$count.ToString('D6')),'')
        $searches=[Collections.Generic.List[object]]::new()
        foreach($query in $queries) {
            $expected=if($query -eq ''){$count}elseif($query -like 'zz-*'){0}else{1}
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $driver.Search($query)
            do {
                $counts=$driver.Name('DeviceCountText')
                $correct=$counts -like "$expected shown*"
                if($correct -and $expected -eq 1){$correct=$driver.Name('DetailDeviceName') -eq $query}
                if(-not $correct){[Threading.Thread]::Sleep(25)}
            }while(-not $correct -and $watch.Elapsed.TotalSeconds -lt 15)
            if(-not $correct){throw 'Search count or selection was incorrect.'}
            $searches.Add(@{Query=$query;ExpectedShown=$expected;ObservedCounts=$counts;UiObservedMilliseconds=[Math]::Round($watch.Elapsed.TotalMilliseconds,2)})
        }
        $process.Refresh()
        $workingSet=$process.WorkingSet64
        $driver.Close()
        if(-not $process.WaitForExit(5000) -or $process.ExitCode -ne 0){throw 'Synthetic app failed normal close.'}
        $metrics=@([IO.File]::ReadAllLines($metricPath)|ForEach-Object {$_|ConvertFrom-Json})
        $results.Add(@{DeviceCount=$count;LaunchThroughInventoryMs=[Math]::Round($launchMs,2);WorkingSetBytes=$workingSet;Searches=@($searches);ProductUiFunctionTimings=$metrics;NormalClose=$true})
        $process.Dispose();$process=$null
    }
    @{Head=(& git -C $repository rev-parse HEAD).Trim();PowerShell=$PSVersionTable.PSVersion.ToString();Results=@($results);Limits='Disposable Windows with actual app/WPF/UIA. Only the demo data factory is scaled; production inventory/filter functions are renamed and wrapped with stopwatches. Startup includes synthetic row generation; UIA timings include 150ms debounce, layout and observation overhead. SDK modules unavailable, no tenant/credentials/recovery/clipboard actions.'}|ConvertTo-Json -Depth 8|Set-Content $OutputPath -Encoding utf8
    Write-Output 'PASS: six, three thousand and ten thousand rows load, filter, select and close with correct counts.'
}
finally {
    if($null -ne $process){if(-not $process.HasExited){$process.Kill();$null=$process.WaitForExit(5000)};$process.Dispose()}
    Remove-Item -LiteralPath $temp -Recurse -Force
}
