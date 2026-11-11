# Runs inside the workflow fixture with actual worker, polling and completion
# functions. Requests and UI are synthetic; no Graph module or clipboard access.
function Reset-RecoveryCancellationFixture([string]$Kind) {
    $script:IsSignedIn=$true
    $script:RecoveryRequestCanceled=$false
    $script:PendingSecretRequest=$null
    $script:PendingCredentialAction=$null
    $script:PendingCredentialVerificationGeneration=$null
    $script:PendingBitLockerAction=$null
    $script:PendingBitLockerVerificationGeneration=$null
    $script:WorkflowToast=''
    if($Kind -eq 'Credential') {
        $script:PendingCredentialAction='Copy'
        $script:PendingCredentialVerificationGeneration=0
    }
    else {
        $script:PendingBitLockerAction='Copy'
        $script:PendingBitLockerVerificationGeneration=0
    }
    Set-SecretActionBusy -Kind $(if($Kind -eq 'Credential'){'LAPS'}else{'BitLocker'})
}

foreach($kind in @('Credential','BitLockerKey')) {
    Reset-RecoveryCancellationFixture $kind
    $ready=[Threading.ManualResetEvent]::new($false)
    $revocationsBefore=$script:WorkflowRevocations
    try {
        $null=Start-GraphOperation -Name $kind -ScriptText 'param($Ready,$Kind) $null=$Ready.Set(); Start-Sleep -Seconds 4; [pscustomobject]@{Kind=$Kind;Password="synthetic";RecoveryKey="synthetic"}' -Arguments @($ready,($kind+'Result'))
        if(-not $ready.WaitOne(2000)){throw 'Synthetic recovery request failed to start.'}
        $operation=$script:CurrentOperation
        Cancel-PendingRecoveryAction
        $stop=$operation.StopAsyncResult
        Cancel-PendingRecoveryAction
        Assert-True -Condition ($operation.CancellationRequested -and $null -ne $stop -and [object]::ReferenceEquals($stop,$operation.StopAsyncResult)) -Name "Repeated $kind cancellation requests one asynchronous stop"
        Assert-True -Condition $operation.AsyncResult.AsyncWaitHandle.WaitOne(1000) -Name "Cancel stops a slow $kind worker before its simulated service delay expires"
        $competing=Start-GraphOperation -Name Inventory -ScriptText 'throw "Must remain serialized"'
        Assert-True -Condition (-not $competing -and $script:CurrentOperation -eq $operation -and -not $CopyPasswordButton.IsEnabled) -Name "Canceled $kind remains serialized until UI completion processes it"
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowExposed -eq 0 -and $script:WorkflowToast -like 'Recovery action canceled*' -and $CopyPasswordButton.IsEnabled -and $CopyRecoveryKeyButton.IsEnabled) -Name "Canceled $kind restores recovery controls without exposing a result or reporting a service failure"
        Assert-True -Condition ($script:IsSignedIn -and $script:WorkflowRevocations -eq $revocationsBefore) -Name "Canceling $kind alone does not sign out or revoke verification"
        $appliedBefore=$script:WorkflowApplied
        $next=Start-GraphOperation -Name Inventory -ScriptText "[pscustomobject]@{Kind='InventoryResult';Devices=@('after canceled recovery');LoadedAt=[DateTimeOffset]::Now}"
        Wait-WorkflowFixture
        Assert-True -Condition ($next -and $script:WorkflowApplied -eq $appliedBefore+1 -and $script:GraphRunspace.RunspaceAvailability -eq 'Available') -Name "The same worker accepts another operation after canceled $kind completion"
    }
    finally { $ready.Dispose() }
}

# A response can be buffered while the pipeline is still finishing. Stopping the
# invocation must not leave that response's secret in the completion object.
foreach($kind in @('Credential','BitLockerKey')) {
    Reset-RecoveryCancellationFixture $kind
    $ready=[Threading.ManualResetEvent]::new($false)
    $field=if($kind -eq 'Credential'){'Password'}else{'RecoveryKey'}
    $payload=[pscustomobject]@{Kind=($kind+'Result')}
    $payload|Add-Member -NotePropertyName $field -NotePropertyValue 'synthetic'
    try {
        $null=Start-GraphOperation -Name $kind -ScriptText 'param($Payload,$Ready) $Payload; $null=$Ready.Set(); Start-Sleep -Seconds 4' -Arguments @($payload,$ready)
        if(-not $ready.WaitOne(2000)){throw 'Synthetic response was not buffered.'}
        Cancel-PendingRecoveryAction
        Wait-WorkflowFixture
        Assert-True -Condition ($null -eq $payload.$field -and $script:WorkflowExposed -eq 0 -and $script:WorkflowToast -like 'Recovery action canceled*') -Name "Canceled buffered $kind result is scrubbed and never exposed"
    }
    finally { $ready.Dispose() }
}

# An already-returned 401 remains authoritative even when cancellation races it.
Reset-RecoveryCancellationFixture Credential
$ready=[Threading.ManualResetEvent]::new($false)
try {
    $revocationsBefore=$script:WorkflowRevocations
    $null=Start-GraphOperation -Name Credential -ScriptText 'param($Ready) [pscustomobject]@{Kind="Error";ErrorCode="InvalidAuthenticationToken";Message="Synthetic expired token";StatusCode=401}; $null=$Ready.Set(); Start-Sleep -Seconds 4' -Arguments @($ready)
    if(-not $ready.WaitOne(2000)){throw 'Synthetic 401 was not buffered.'}
    Cancel-PendingRecoveryAction
    Wait-WorkflowFixture
    Assert-True -Condition (-not $script:IsSignedIn -and $script:WorkflowRevocations -eq $revocationsBefore+1 -and $script:WorkflowToast -like '*requires you to sign in again*') -Name 'Cancellation cannot hide a returned 401 or preserve an expired verification grant'
}
finally { $ready.Dispose() }

# Failed stop requests must retain canceled intent and keep the worker occupied.
Reset-RecoveryCancellationFixture Credential
$ready=[Threading.ManualResetEvent]::new($false)
try {
    $payload=[pscustomobject]@{Kind='CredentialResult';Password='synthetic'}
    $null=Start-GraphOperation -Name Credential -ScriptText 'param($Ready,$Payload) $null=$Ready.Set(); Start-Sleep -Milliseconds 500; $Payload' -Arguments @($ready,$payload)
    if(-not $ready.WaitOne(2000)){throw 'Stop-failure fixture did not start.'}
    $script:GraphPowerShell|Add-Member -MemberType ScriptMethod -Name BeginStop -Force -Value {param($Callback,$State) throw 'Synthetic asynchronous stop failure'}
    Cancel-PendingRecoveryAction
    $competing=Start-GraphOperation -Name Inventory -ScriptText 'throw "Must not overlap"'
    Assert-True -Condition ($script:RecoveryRequestCanceled -and -not $competing -and $null -ne $script:CurrentOperation -and -not $CopyPasswordButton.IsEnabled) -Name 'A failed stop keeps canceled recovery serialized and its controls disabled'
    Wait-WorkflowFixture
    Assert-True -Condition ($null -eq $payload.Password -and $script:WorkflowExposed -eq 0 -and $script:WorkflowToast -like 'Recovery action canceled*') -Name 'A failed stop still discards and scrubs the eventual recovery response'
}
finally {
    if($null -ne $script:GraphPowerShell){$script:GraphPowerShell.PSObject.Members.Remove('BeginStop')}
    $ready.Dispose()
}

# A queued startup error has no running invocation to stop.
Reset-RecoveryCancellationFixture Credential
function Initialize-GraphWorker { throw 'Synthetic recovery startup failure' }
$null=Start-GraphOperation -Name Credential -ScriptText 'throw "Must not run"'
Cancel-PendingRecoveryAction
Wait-WorkflowFixture
Assert-True -Condition ($script:WorkflowToast -like '*background worker could not start*' -and $CopyPasswordButton.IsEnabled -and $script:WorkflowExposed -eq 0) -Name 'Cancellation of a failed startup preserves the startup error and restores controls'
. ([scriptblock]::Create($mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-GraphWorker'},$true).Extent.Text))
$script:IsSignedIn=$true
