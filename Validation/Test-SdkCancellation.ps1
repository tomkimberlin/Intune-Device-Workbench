param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$RepositoryPath=(Split-Path $PSScriptRoot),
    [string]$Baseline='d90a9a9bee531b275f72a523cba778841a1b9474'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'This SDK probe is restricted to disposable CI runners.'}
# Never sign in. Replace the entire HTTP transport with a handler that cannot
# open sockets; it rejects authentication headers and unexpected request URIs.
Import-Module $ModulePath -ErrorAction Stop
Import-Module (Join-Path $RepositoryPath 'M365Workbench.Core.psm1') -Force
# SDK 2.41 isolates its core assembly in a private load context. Resolve the
# already-loaded public type instead of loading a second copy into the default.
$null=Get-MgContext
function Get-SdkType([string]$Name) {
    foreach($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
        $type=$assembly.GetType($Name,$false)
        if($null -ne $type){return $type}
    }
    throw "The SDK did not load the required public type: $Name"
}
$sessionType=Get-SdkType 'Microsoft.Graph.PowerShell.Authentication.GraphSession'
$authType=Get-SdkType 'Microsoft.Graph.PowerShell.Authentication.AuthContext'
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
public sealed class SyntheticGraphTransport : HttpMessageHandler {
    public readonly ManualResetEvent Started = new ManualResetEvent(false);
    public int Calls;
    public int Canceled;
    public int DelayMs = 5000;
    public HttpStatusCode ResponseStatus = HttpStatusCode.OK;
    public string ResponseJson;
    public string ExpectedUri;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
        if(request.Method != HttpMethod.Get || request.RequestUri.AbsoluteUri != ExpectedUri || request.Headers.Authorization != null)
            throw new InvalidOperationException("Unexpected request in synthetic transport.");
        Interlocked.Increment(ref Calls);
        Started.Set();
        try { await Task.Delay(DelayMs, token).ConfigureAwait(false); }
        catch(OperationCanceledException) { Interlocked.Increment(ref Canceled); throw; }
        return new HttpResponseMessage(ResponseStatus) {
            Content = new StringContent(ResponseJson, Encoding.UTF8, "application/json"), RequestMessage = request
        };
    }
}
'@
foreach($name in @('CopyDeviceDetailsButton','CopyAccountButton','CopyPasswordButton','CopyPasswordButtonText','RevealPasswordButton','CopyRecoveryKeyButton','CopyRecoveryKeyButtonText','RevealRecoveryKeyButton','RefreshButton','RefreshButtonText','RefreshIcon','SignInButton','AccountNameText')) {
    Set-Variable -Name $name -Value ([pscustomobject]@{IsEnabled=$true;Text='';Content='';Visibility='Collapsed';ToolTip=''})
}
$AccountNameText.Text='DemoLapsAdmin'
$BitLockerKeySelector=[pscustomobject]@{IsEnabled=$true;SelectedItem=[pscustomobject]@{Id='22222222-2222-4222-8222-222222222222'}}
$settings=@{ExpectedAccount='admin@contoso.com'}
$DemoMode=$false
function Get-SelectedDevice {[pscustomobject]@{LapsAvailable=$true;BitLockerAvailable=$true;BitLockerKeys=@(1)}}
function Set-AppStatus {param($Message,[switch]$Busy) $script:LastStatus=$Message}
function Show-Toast {param($Message,$Kind) $script:LastToast=$Message}
function Set-RecoveryActionFocus {param($Kind,$Action)}
function Test-SecretVerificationGeneration {param($Generation) $Generation -eq 1}
function Complete-CredentialAction {param($Action,$Credential) if($Credential.Password -ne 'SYNTHETIC-LAPS-DO-NOT-USE'){throw 'Unexpected synthetic password.'};$Credential.Password=$null;$script:Exposed++}
function Complete-BitLockerAction {param($Action,$KeyResult) if($KeyResult.RecoveryKey -ne '111111-222222-333333-444444-555555-666666-777777-888888'){throw 'Unexpected synthetic key.'};$KeyResult.RecoveryKey=$null;$script:Exposed++}
function Reset-Intent {
    $script:PendingSecretRequest=$null;$script:LocalVerificationTask=$null;$script:LocalVerificationCancellation=$null;$script:MicrosoftVerificationCancelEvent=$null
    $script:PendingCredentialAction='Copy';$script:PendingBitLockerAction='Copy'
    $script:PendingCredentialVerificationGeneration=1;$script:PendingBitLockerVerificationGeneration=1;$script:RecoveryRequestCanceled=$false
    $script:LastToast='';$script:LastStatus='';$script:IsSignedIn=$true
}
function Wait-Completion {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($null -ne $script:CurrentOperation -and $watch.Elapsed.TotalSeconds -lt 8){Process-OperationOutput;[Threading.Thread]::Sleep(10)}
    if($null -ne $script:CurrentOperation){throw 'Synthetic SDK completion exceeded its bound.'}
}
$results=[Collections.Generic.List[object]]::new()
$responseResults=[Collections.Generic.List[object]]::new()
$head=(& git -C $RepositoryPath rev-parse HEAD).Trim()
foreach($revision in @($Baseline,$head)) {
    $source=(& git -C $RepositoryPath show "${revision}:IntuneDeviceWorkbench.ps1") -join "`n"
    if($LASTEXITCODE -ne 0){throw 'Could not read reviewed source.'}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Application source did not parse.'}
    foreach($name in @('Initialize-GraphWorker','Start-GraphOperation','Cancel-PendingRecoveryAction','Set-SecretActionBusy','Get-OperationResultObject','Process-OperationOutput','Complete-GraphOperation','Restore-SecretActionControls')) {
        . ([scriptblock]::Create($ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true).Extent.Text))
    }
    foreach($kind in @('Credential','BitLockerKey')) {
        $script:GraphRunspace=$null;$script:GraphPowerShell=$null;$script:CurrentOperation=$null;$script:Exposed=0
        $session=$null
        $transport=[SyntheticGraphTransport]::new()
        $client=[Net.Http.HttpClient]::new($transport)
        try {
            Initialize-GraphWorker
            # Import into the real reusable worker before installing the fake
            # context; module loading does not involve Connect-MgGraph or tokens.
            $null=$script:GraphPowerShell.AddScript('param($Path) Import-Module $Path -ErrorAction Stop').AddArgument($ModulePath)
            $null=$script:GraphPowerShell.Invoke()
            if($script:GraphPowerShell.HadErrors){throw 'Worker SDK import failed.'}
            $session=$sessionType.GetProperty('Instance').GetValue($null)
            $auth=[Activator]::CreateInstance($authType)
            $auth.Account='admin@contoso.com';$auth.TenantId='33333333-3333-4333-8333-333333333333';$auth.ContextScope='Process';$auth.AuthType='Delegated'
            $session.AuthContext=$auth
            $session.GraphHttpClient=$client
            $deviceId='11111111-1111-4111-8111-111111111111'
            $keyId='22222222-2222-4222-8222-222222222222'
            $core=Join-Path $RepositoryPath 'M365Workbench.Core.psm1'
            if($kind -eq 'Credential') {
                $variable='$credentialOperationScript'
                $arguments=@($deviceId,$core)
                $transport.ExpectedUri="https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/${deviceId}?`$select=id,deviceName,lastBackupDateTime,refreshDateTime,credentials"
                $transport.ResponseJson=@{id=$deviceId;deviceName='DEMO-DEVICE-001';credentials=@(@{accountName='DemoLapsAdmin';accountSid='S-1-5-21-1-2-3-500';backupDateTime='2026-11-01T00:00:00Z';passwordBase64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('SYNTHETIC-LAPS-DO-NOT-USE'))})}|ConvertTo-Json -Depth 5 -Compress
            }
            else {
                $variable='$bitLockerKeyOperationScript'
                $arguments=@($deviceId,$keyId,$core)
                $transport.ExpectedUri="https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/${keyId}?`$select=id,key,deviceId,createdDateTime,volumeType"
                $transport.ResponseJson=@{id=$keyId;deviceId=$deviceId;key='111111-222222-333333-444444-555555-666666-777777-888888';createdDateTime='2026-11-01T00:00:00Z';volumeType='operatingSystemVolume'}|ConvertTo-Json -Compress
            }
            $body=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $variable},$true).Right.Expression.Value
            Reset-Intent
            Set-SecretActionBusy -Kind $(if($kind -eq 'Credential'){'LAPS'}else{'BitLocker'})
            $null=Start-GraphOperation -Name $kind -ScriptText $body -Arguments $arguments
            if(-not $transport.Started.WaitOne(5000)){throw 'Actual SDK did not reach synthetic HTTP transport.'}
            $watch=[Diagnostics.Stopwatch]::StartNew()
            Cancel-PendingRecoveryAction
            Wait-Completion
            $elapsed=$watch.Elapsed.TotalMilliseconds
            $cancelSafe=$script:Exposed -eq 0 -and $script:LastToast -like 'Recovery action canceled*'
            $restored=$CopyPasswordButton.IsEnabled -and $CopyRecoveryKeyButton.IsEnabled
            $contextRetained=[object]::ReferenceEquals($session.AuthContext,$auth)
            $canceled=$transport.Canceled
            $expectedCancel=if($revision -eq $Baseline){0}else{1}
            if(-not $cancelSafe -or -not $restored -or -not $contextRetained -or $canceled -ne $expectedCancel){throw "SDK cancellation invariant failed for $kind."}
            if($revision -ne $Baseline -and $elapsed -gt 1500){throw 'Cooperative SDK stop did not finish promptly.'}
            # Follow the cancellation with a normal response through the same
            # SDK client, authenticated-context object and application worker.
            Reset-Intent
            $transport.DelayMs=0
            $null=Start-GraphOperation -Name $kind -ScriptText $body -Arguments $arguments
            Wait-Completion
            if($script:Exposed -ne 1 -or $transport.Calls -ne 2 -or $script:GraphRunspace.RunspaceAvailability -ne 'Available'){throw 'Normal SDK read after cancellation failed.'}
            $results.Add([pscustomobject]@{Revision=$revision;Operation=$kind;SdkVersion=(Get-Module Microsoft.Graph.Authentication).Version.ToString();SyntheticDelayMs=5000;UiReadyMs=[Math]::Round($elapsed,2);TransportObservedCancellation=($canceled -eq 1);CanceledExposureCount=0;ControlsRestored=$restored;AuthContextRetained=$contextRetained;SubsequentNormalReadPassed=$true;TransportCalls=$transport.Calls})
            if($revision -ne $Baseline) {
                # Exercise actual SDK exception shaping, not a handmade exception.
                # These checks stop at the worker result; UI status/reconnect
                # behavior is covered separately by the application's tests.
                $operations=@($kind)
                if($kind -eq 'BitLockerKey'){$operations+='Inventory'}
                foreach($operationKind in $operations) {
                    if($operationKind -eq 'Inventory') {
                        $variable='$inventoryOperationScript'
                        $body=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $variable},$true).Right.Expression.Value
                        $arguments=@($core)
                        $transport.ExpectedUri="https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,azureADDeviceId,serialNumber,operatingSystem,osVersion,model,manufacturer,lastSyncDateTime,complianceState,managementState,managedDeviceOwnerType,deviceEnrollmentType,isEncrypted,managementAgent,enrolledDateTime"
                    }
                    foreach($status in @(401,403,404,429,503)) {
                        $transport.ResponseStatus=[Net.HttpStatusCode]$status
                        $transport.ResponseJson='{"error":{"code":"SyntheticHttpFailure","message":"Synthetic status fixture"}}'
                        $callsBefore=$transport.Calls
                        $null=Start-GraphOperation -Name $operationKind -ScriptText $body -Arguments $arguments
                        $operation=$script:CurrentOperation
                        if(-not $operation.AsyncResult.AsyncWaitHandle.WaitOne(3000)){throw 'SDK error response did not finish.'}
                        $null=$script:GraphPowerShell.EndInvoke($operation.AsyncResult)
                        $result=Get-OperationResultObject -Operation $operation
                        if($null -eq $result -or $result.Kind -ne 'Error' -or $result.StatusCode -ne $status -or $transport.Calls -ne $callsBefore+1){throw "Actual SDK HTTP $status was not preserved for $operationKind."}
                        $responseResults.Add([pscustomobject]@{Operation=$operationKind;HttpStatus=$status;ReturnedStatus=[int]$result.StatusCode;Calls=($transport.Calls-$callsBefore);Passed=$true})
                        $script:GraphPowerShell.Streams.ClearStreams()
                        $operation.Output.Clear();$operation.Input.Dispose();$operation.Output.Dispose();$script:CurrentOperation=$null
                    }
                }
            }
        }
        finally {
            if($null -ne $script:GraphPowerShell){$script:GraphPowerShell.Stop();$script:GraphPowerShell.Dispose()}
            if($null -ne $script:GraphRunspace){$script:GraphRunspace.Close();$script:GraphRunspace.Dispose()}
            if($null -ne $session){$session.AuthContext=$null;$session.GraphHttpClient=$null}
            $client.Dispose();$transport.Started.Dispose()
        }
    }
}
[pscustomobject]@{Results=@($results);HttpResponses=@($responseResults);Limits='Actual published Graph SDK 2.41.1 and production operation bodies. Cancellation uses actual worker/completion; HTTP error checks inspect worker results only. In-memory HTTP transport with no socket implementation and synthetic auth context; no Connect-MgGraph, tokens, tenant, clipboard, screen reader or physical UI. Polling interval 10 ms.'}|ConvertTo-Json -Depth 6|Set-Content $OutputPath -Encoding utf8
Write-Output 'PASS: four SDK cancellation/reuse scenarios and fifteen actual SDK HTTP-status checks, synthetic transport only.'
