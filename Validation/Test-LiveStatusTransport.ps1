param(
    [ValidateSet('Controller','Provider')][string]$Mode = 'Controller',
    [string]$SourcePath,
    [string]$ExchangePath,
    [switch]$ExpectBaselineFailure,
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes

# This disposable integration fixture loads only the real XAML and status functions.
# It does not execute application startup, Graph, verification or clipboard code.
if ($Mode -eq 'Provider') {
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'Application source does not parse.'}
    $xamlNode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml'},$true)
    $reader=[Xml.XmlNodeReader]::new([xml]$xamlNode.Right.Expression.Value)
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    $window.Title='DEMO-DEVICE UI Automation transport fixture'
    foreach($name in @('FooterStatusText','BusyIndicator','ToastBorder','ToastText','ToastIcon','AuthOverlay','AuthOverlayStatus')){
        Set-Variable -Name $name -Value $window.FindName($name)
    }
    foreach($name in @('Set-LiveStatusText','Set-AppStatus','Show-Toast')){
        $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if($null -ne $node){. ([scriptblock]::Create($node.Extent.Text))}
    }
    $expiry=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if ($script:ToastExpiresAt -ne')},$true)
    $expiryBlock=[scriptblock]::Create($expiry.Extent.Text)
    $script:ToastExpiresAt=[DateTimeOffset]::MinValue
    function Get-SensitiveClockNow { [DateTimeOffset]::UtcNow }
    $script:CommandIndex=0
    $script:ProviderClock=[Diagnostics.Stopwatch]::StartNew()
    $timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[TimeSpan]::FromMilliseconds(50)
    $timer.Add_Tick({
        try {
            if($script:ProviderClock.Elapsed.TotalSeconds -gt 60){throw 'Provider timeout.'}
            $path=Join-Path $ExchangePath ("command-$script:CommandIndex.json")
            if(-not [IO.File]::Exists($path)){return}
            $command=[IO.File]::ReadAllText($path)|ConvertFrom-Json
            switch($command.Action){
                'Probe' { }
                'Status' { Set-AppStatus -Message $command.Message }
                'Toast' { Show-Toast -Message $command.Message -Kind Error }
                'ExpireToast' { $now=$script:ToastExpiresAt.AddMilliseconds(1); & $expiryBlock }
                'Auth' {
                    $AuthOverlay.Visibility='Visible'
                    if(Get-Command Set-LiveStatusText -ErrorAction SilentlyContinue){Set-LiveStatusText -Control $AuthOverlayStatus -Message $command.Message}
                    else{$AuthOverlayStatus.Text=$command.Message}
                }
                'HiddenToast' {
                    $ToastBorder.Visibility='Collapsed'
                    if(Get-Command Set-LiveStatusText -ErrorAction SilentlyContinue){Set-LiveStatusText -Control $ToastText -Message $command.Message}
                    else{$ToastText.Text=$command.Message}
                }
                'Close' { $timer.Stop(); $window.Close() }
                default {throw 'Unknown fixture command.'}
            }
            $reply=[ordered]@{
                Action=$command.Action
                Listening=[Windows.Automation.Peers.AutomationPeer]::ListenerExists([Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)
                ToastVisible=$ToastText.IsVisible
                FooterVisible=$FooterStatusText.IsVisible
            }
            $replyTemp=Join-Path $ExchangePath "reply-$script:CommandIndex.tmp"
            [IO.File]::WriteAllText($replyTemp,($reply|ConvertTo-Json -Compress))
            [IO.File]::Move($replyTemp,(Join-Path $ExchangePath "reply-$script:CommandIndex.json"))
            $script:CommandIndex++
        }
        catch {
            [IO.File]::WriteAllText((Join-Path $ExchangePath 'provider-error.txt'),[string]$_)
            $timer.Stop(); $window.Close()
        }
    })
    $window.Add_ContentRendered({
        $handle=([Windows.Interop.WindowInteropHelper]::new($window)).Handle.ToInt64()
        [IO.File]::WriteAllText((Join-Path $ExchangePath 'ready.tmp'),(@{Handle=$handle}|ConvertTo-Json -Compress))
        [IO.File]::Move((Join-Path $ExchangePath 'ready.tmp'),(Join-Path $ExchangePath 'ready.json'))
        $timer.Start()
    })
    $null=$window.ShowDialog()
    exit 0
}

Add-Type -ReferencedAssemblies @('UIAutomationClient.dll','UIAutomationTypes.dll','System.Runtime.dll','System.Collections.dll','System.Threading.dll') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Windows.Automation;
public sealed class LiveStatusClient : IDisposable {
    private readonly AutomationElement root;
    private readonly AutomationEventHandler handler;
    private readonly object gate = new object();
    private readonly List<string> received = new List<string>();
    public LiveStatusClient(long hwnd) {
        root = AutomationElement.FromHandle(new IntPtr(hwnd));
        handler = OnChanged;
        Automation.AddAutomationEventHandler(AutomationElementIdentifiers.LiveRegionChangedEvent, root, TreeScope.Subtree, handler);
    }
    private void OnChanged(object sender, AutomationEventArgs args) {
        string value;
        try {
            var element = (AutomationElement)sender;
            value = element.Current.AutomationId + "\t" + element.Current.Name;
        } catch (Exception ex) { value = "CLIENT-ERROR\t" + ex.GetType().Name; }
        lock(gate) { received.Add(value); }
    }
    public string[] Snapshot() { lock(gate) { return received.ToArray(); } }
    public string ReadName(string automationId) {
        var element = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.AutomationIdProperty, automationId));
        return element == null ? "MISSING" : element.Current.Name;
    }
    public void Dispose() { Automation.RemoveAutomationEventHandler(AutomationElementIdentifiers.LiveRegionChangedEvent, root, handler); }
}
'@
$exchange=Join-Path ([IO.Path]::GetTempPath()) ('intune-uia-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $exchange
$child=$null; $client=$null
$script:CommandIndex=0
$checks=[Collections.Generic.List[object]]::new()
function Send-Command([string]$Action,[string]$Message='') {
    $index=$script:CommandIndex++
    $temp=Join-Path $exchange "command-$index.tmp"
    [IO.File]::WriteAllText($temp,(@{Action=$Action;Message=$Message}|ConvertTo-Json -Compress))
    [IO.File]::Move($temp,(Join-Path $exchange "command-$index.json"))
    $reply=Join-Path $exchange "reply-$index.json"
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists($reply)){
        if([IO.File]::Exists((Join-Path $exchange 'provider-error.txt'))){throw [IO.File]::ReadAllText((Join-Path $exchange 'provider-error.txt'))}
        if($child.HasExited -or $watch.Elapsed.TotalSeconds -gt 10){throw "No provider reply for $Action."}
        Start-Sleep -Milliseconds 50
    }
    [IO.File]::ReadAllText($reply)|ConvertFrom-Json
}
function Assert-Observation([bool]$Condition,[string]$Name){
    $checks.Add([pscustomobject]@{Name=$Name;Passed=$Condition})
    "$(if($Condition){'PASS'}else{'FAIL'}) $Name"
}
function Wait-ForEvent([string]$Expected,[int]$Minimum=1){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        $count=@($client.Snapshot()|Where-Object {$_ -ceq $Expected}).Count
        if($count -ge $Minimum){return $true}
        Start-Sleep -Milliseconds 50
    }while($watch.Elapsed.TotalSeconds -lt 3)
    return $false
}
try {
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.UseShellExecute=$false
    foreach($arg in @('-NoLogo','-NoProfile','-STA','-File',$PSCommandPath,'-Mode','Provider','-SourcePath',$SourcePath,'-ExchangePath',$exchange)){$start.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($start)
    $readyPath=Join-Path $exchange 'ready.json'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while(-not [IO.File]::Exists($readyPath)){
        if($child.HasExited -or $watch.Elapsed.TotalSeconds -gt 15){throw 'Visible WPF provider failed to start.'}
        Start-Sleep -Milliseconds 50
    }
    $ready=[IO.File]::ReadAllText($readyPath)|ConvertFrom-Json
    $client=[LiveStatusClient]::new($ready.Handle)
    $watch.Restart()
    do {$probe=Send-Command Probe; if($probe.Listening){break};Start-Sleep -Milliseconds 100}while($watch.Elapsed.TotalSeconds -lt 5)
    if(-not $probe.Listening -or -not $probe.FooterVisible){throw 'Real UI Automation listener or visible WPF surface unavailable.'}

    $status='DEMO-DEVICE refresh failed; showing the previous inventory.'
    $null=Send-Command Status $status
    Assert-Observation ($client.ReadName('FooterStatusText') -ceq $status) 'Client reads the actual footer message'
    Assert-Observation (Wait-ForEvent "FooterStatusText`t$status") 'Footer live-region event reaches the external client'
    $before=$client.Snapshot().Count
    $null=Send-Command Status $status
    Start-Sleep -Milliseconds 500
    Assert-Observation ($client.Snapshot().Count -eq $before) 'Identical passive status does not emit another event'

    $toast='Synthetic clipboard contention; retry the copy.'
    $null=Send-Command Toast $toast
    Assert-Observation ($client.ReadName('ToastText') -ceq $toast) 'Client reads the actual toast message'
    Assert-Observation (Wait-ForEvent "ToastText`t$toast") 'Toast event reaches the external client'
    $expired=Send-Command ExpireToast
    Assert-Observation (-not $expired.ToastVisible) 'Production expiry hides the previous toast'
    $null=Send-Command Toast $toast
    Assert-Observation (Wait-ForEvent "ToastText`t$toast" 2) 'The repeated toast produces a second delivered event'

    $auth='Synthetic verification canceled; no recovery data accessed.'
    $null=Send-Command Auth $auth
    Assert-Observation ($client.ReadName('AuthOverlayStatus') -ceq $auth) 'Client reads the actual verification message'
    Assert-Observation (Wait-ForEvent "AuthOverlayStatus`t$auth") 'Verification event reaches the external client'
    $before=$client.Snapshot().Count
    $null=Send-Command HiddenToast 'Synthetic hidden status'
    Start-Sleep -Milliseconds 500
    Assert-Observation ($client.Snapshot().Count -eq $before) 'Hidden status does not emit a live-region event'

    $failures=@($checks|Where-Object {-not $_.Passed}).Count
    $result=[ordered]@{PowerShell=$PSVersionTable.PSVersion.ToString();SourceSHA256=(Get-FileHash $SourcePath -Algorithm SHA256).Hash;ExpectedBaselineFailure=[bool]$ExpectBaselineFailure;Passed=$checks.Count-$failures;Failed=$failures;Checks=$checks;DeliveredEvents=@($client.Snapshot());Limits='Real WPF and cross-process UIA transport; no screen-reader speech, Graph, credentials, Windows Hello or host clipboard access.'}
    if($OutputPath){[IO.File]::WriteAllText($OutputPath,($result|ConvertTo-Json -Depth 6))}
    "$($result.Passed) passed; $failures failed"
    if($ExpectBaselineFailure){
        $expectedFailures=@(
            'Client reads the actual footer message',
            'Footer live-region event reaches the external client',
            'Client reads the actual toast message',
            'Toast event reaches the external client',
            'The repeated toast produces a second delivered event',
            'Client reads the actual verification message',
            'Verification event reaches the external client'
        )
        $actualFailures=@($checks|Where-Object {-not $_.Passed}|ForEach-Object Name)
        if(@(Compare-Object $expectedFailures $actualFailures).Count -ne 0){throw 'Baseline did not reproduce the specific expected accessibility failures.'}
    }
    elseif($failures){throw "$failures UIA transport checks failed."}
}
finally {
    if($null -ne $client){$client.Dispose()}
    if($null -ne $child){
        if(-not $child.HasExited){try{$null=Send-Command Close}catch{};if(-not $child.WaitForExit(3000)){$child.Kill();$child.WaitForExit()}}
        $child.Dispose()
    }
    Remove-Item -LiteralPath $exchange -Recurse -Force
}
