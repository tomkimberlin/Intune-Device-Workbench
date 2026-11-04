# Real asynchronous PowerShell pipelines, synthetic responses, and unshown WPF
# controls. No Graph module, tenant connection, or Windows clipboard access.
& {
    Add-Type -AssemblyName PresentationFramework
    $DemoMode=$false
    foreach ($name in @('Initialize-GraphWorker','Start-GraphOperation','Stop-InventoryLoad','Start-InventoryLoad','Set-InventoryLoadingState','Reset-InventoryControls','Complete-GraphOperation','Get-OperationResultObject','Process-OperationOutput','Restore-SecretActionControls','Set-SecretActionBusy','Update-OperationControls','Cancel-PendingRecoveryAction','Set-RecoveryTab','Complete-LocalSecretVerification','Request-SecretAction')) {
        . ([scriptblock]::Create($mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true).Extent.Text))
    }
    $xamlNode=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml'},$true)
    $reader=[System.Xml.XmlNodeReader]::new([xml]$xamlNode.Right.Expression.Value)
    $testWindow=[System.Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    $namesNode=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$controlNames'},$true)
    . ([scriptblock]::Create($namesNode.Extent.Text))
    foreach ($name in $controlNames) { Set-Variable -Name $name -Value $testWindow.FindName($name) }
    $coreModulePath='unused fixture'
    $settings=@{ExpectedAccount='admin@contoso.com'}
    $script:GraphRunspace=$null
    $script:GraphPowerShell=$null
    $script:CurrentOperation=$null
    $script:PendingSecretRequest=$null
    $script:LocalVerificationTask=$null
    $script:LocalVerificationCancellation=$null
    $script:MicrosoftVerificationCancelEvent=$null
    $script:RecoveryRequestCanceled=$false
    $script:WorkflowSelected=[pscustomobject]@{LapsAvailable=$true;BitLockerAvailable=$true;BitLockerKeys=@(1,2)}
    $script:AllDevices=@('previous inventory')
    $script:IsSignedIn=$true
    $script:WorkflowApplied=0
    $script:WorkflowExposed=0
    $script:WorkflowStatus=''
    $BitLockerKeySelector.ItemsSource=@([pscustomobject]@{Id='22222222-2222-4222-8222-222222222222';VolumeDisplay='Operating system volume';CreatedDisplay='Sep 1, 2026 12:00 PM'})
    $BitLockerKeySelector.SelectedIndex=0
    function Get-SelectedDevice { $script:WorkflowSelected }
    function Set-AppStatus { param($Message,[switch]$Busy) $script:WorkflowStatus=$Message }
    function Show-Toast { param($Message,$Kind) $script:WorkflowToast=$Message }
    function Set-DeviceInventory { param($Devices) $script:WorkflowApplied++; $script:AllDevices=@($Devices) }
    function Update-FilteredCount { }
    function Set-RecoveryActionFocus { param($Kind,$Action) }
    $script:WorkflowSecretClears=0
    $script:WorkflowRevocations=0
    function Clear-SecretDisplay { $script:WorkflowSecretClears++ }
    function Update-ClipboardStatusForSelection { }
    function Clear-AuthenticationClipboard { }
    function Clear-SecretVerificationState { $script:WorkflowRevocations++ }
    function Set-AuthenticationDisplay { param($SignedIn,$Text) $script:IsSignedIn=$SignedIn }
    function Complete-CredentialAction { param($Action,$Credential) $script:WorkflowExposed++ }
    function Complete-BitLockerAction { param($Action,$KeyResult) $script:WorkflowExposed++ }
    function Test-SecretVerificationGeneration { param($Generation) $null -ne $Generation }
    function Fail-SecretVerification { param($Message,[switch]$Canceled) $script:WorkflowToast=$Message; $script:PendingSecretRequest=$null }
    function Wait-WorkflowFixture {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while ($null -ne $script:CurrentOperation -and $watch.Elapsed.TotalSeconds -lt 5) {
            Process-OperationOutput
            [Threading.Thread]::Sleep(10)
        }
        if ($null -ne $script:CurrentOperation) { throw 'Synthetic worker did not complete within the bounded test window.' }
    }
    try {
        # Startup failure is queued for normal UI completion; the next attempt can retry.
        function Initialize-GraphWorker { throw 'Synthetic worker startup failure' }
        $inventoryOperationScript="[pscustomobject]@{Kind='InventoryResult';Devices=@('new inventory');LoadedAt=[DateTimeOffset]::Now}"
        Start-InventoryLoad
        Assert-True -Condition ($null -ne $script:CurrentOperation -and $null -eq $script:CurrentOperation.AsyncResult) -Name 'Worker startup failure becomes a recoverable operation result instead of escaping the UI event'
        Wait-WorkflowFixture
        Assert-True -Condition ($RefreshButton.IsEnabled -and $SignInButton.IsEnabled -and $RefreshButtonText.Text -eq 'Refresh' -and $script:AllDevices[0] -eq 'previous inventory') -Name 'Worker startup failure restores controls and preserves the previous inventory'
        . ([scriptblock]::Create($mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-GraphWorker'},$true).Extent.Text))
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 1 -and $script:AllDevices[0] -eq 'new inventory') -Name 'A fresh background worker succeeds after a startup failure'

        # BeginStop is genuinely asynchronous; no synchronous Stop on the UI thread.
        $AccountNameText.Text='DemoLapsAdmin'
        $CopyAccountButton.IsEnabled=$true
        $inventoryOperationScript="Start-Sleep -Seconds 30; [pscustomobject]@{Kind='InventoryResult';Devices=@('must not apply');LoadedAt=[DateTimeOffset]::Now}"
        Start-InventoryLoad
        Assert-True -Condition ($RefreshButton.IsEnabled -and $RefreshButtonText.Text -eq 'Cancel' -and -not $CopyPasswordButton.IsEnabled -and -not $SignInButton.IsEnabled) -Name 'A running refresh exposes Cancel and prevents competing actions'
        Restore-SecretActionControls
        Update-OperationControls
        Assert-True -Condition ($RefreshButton.IsEnabled -and -not $CopyPasswordButton.IsEnabled -and -not $SignInButton.IsEnabled) -Name 'Selection updates during refresh keep Cancel available without re-enabling competing actions'
        Assert-True -Condition (-not $CopyAccountButton.IsEnabled) -Name 'Pending Graph work disables username copying even when an earlier recovery populated the account'
        $inFlight=$script:CurrentOperation
        $secondStarted=Start-GraphOperation -Name Inventory -ScriptText 'throw "must not run"'
        Assert-True -Condition (-not $secondStarted -and $script:CurrentOperation -eq $inFlight) -Name 'Only one background operation can run at a time'
        Stop-InventoryLoad
        Stop-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 1 -and $script:AllDevices[0] -eq 'new inventory' -and $script:WorkflowStatus -like 'Refresh canceled*') -Name 'Repeated Cancel safely stops a delayed refresh without replacing the previous inventory'
        Assert-True -Condition ($RefreshButton.IsEnabled -and $CopyPasswordButton.IsEnabled -and $SignInButton.IsEnabled -and $LoadingOverlay.Visibility -eq 'Collapsed') -Name 'Canceled refresh restores usable controls and hides loading overlays'
        Assert-True -Condition $CopyAccountButton.IsEnabled -Name 'Canceling pending work restores the known username copy action'
        $AccountNameText.Text='Retrieved with password'
        Restore-SecretActionControls
        Assert-True -Condition (-not $CopyAccountButton.IsEnabled) -Name 'Restoring controls never enables username copying before an account was retrieved'

        $inventoryOperationScript="[pscustomobject]@{Kind='InventoryResult';Devices=@('retry inventory');LoadedAt=[DateTimeOffset]::Now}"
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 2 -and $script:AllDevices[0] -eq 'retry inventory') -Name 'The same worker successfully refreshes after asynchronous cancellation'

        # Result already arrived, but Cancel was clicked before the UI consumed it.
        Start-InventoryLoad
        $null=$script:CurrentOperation.AsyncResult.AsyncWaitHandle.WaitOne(5000)
        Stop-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 2) -Name 'Cancel wins the race against an unconsumed completed inventory result'

        $script:GraphRunspace.Close()
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($null -eq $script:GraphRunspace -and $null -eq $script:GraphPowerShell -and $RefreshButton.IsEnabled) -Name 'A broken worker is released after BeginInvoke fails and leaves Retry available'
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 3) -Name 'Refresh recreates a broken worker on the next attempt'

        $inventoryOperationScript="[pscustomobject]@{Kind='Error';ErrorCode='ServiceUnavailable';Message='synthetic';StatusCode=503}"
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 3 -and $script:IsSignedIn -and $script:WorkflowStatus -like '*Showing the previous inventory*' -and $RefreshButton.IsEnabled) -Name 'A failed refresh preserves sign-in and inventory and clearly labels the displayed data as previous'
        # Run the real inventory body through the real worker/UI completion path.
        # Only the Graph transport is replaced, using its actual exception shape.
        $inventoryNode=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$inventoryOperationScript'},$true)
        $coreModulePath=$modulePath
        $inventoryOperationScript=@'
param($CoreModulePath)
function Invoke-MgGraphRequest {
    $failure=[Net.Http.HttpRequestException]::new('Synthetic HTTP failure')
    $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Unauthorized))
    throw $failure
}
& {
'@ + $inventoryNode.Right.Expression.Value + "`n} `$CoreModulePath"
        $revocationsBefore=$script:WorkflowRevocations
        $clearsBefore=$script:WorkflowSecretClears
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition (-not $script:IsSignedIn -and $script:WorkflowRevocations -eq $revocationsBefore + 1 -and $script:WorkflowSecretClears -eq $clearsBefore + 1 -and $script:WorkflowStatus -like '*sign-in has expired*' -and $script:WorkflowApplied -eq 3) -Name 'An SDK-shaped 401 revokes recovery verification, clears displayed secrets, and requires sign-in without replacing inventory'
        Assert-True -Condition ($SignInButton.IsEnabled -and $RefreshButton.IsEnabled -and -not $CopyPasswordButton.IsEnabled -and -not $CopyRecoveryKeyButton.IsEnabled) -Name 'Expired sign-in leaves reconnect available while recovery actions are disabled'
        $script:IsSignedIn=$true
        $inventoryOperationScript=@'
param($CoreModulePath)
function Invoke-MgGraphRequest { [pscustomobject]@{ unexpected='malformed collection' } }
& {
'@ + $inventoryNode.Right.Expression.Value + "`n} `$CoreModulePath"
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 3 -and $script:IsSignedIn -and $script:AllDevices.Count -eq 1 -and $script:WorkflowStatus -like '*Showing the previous inventory*' -and $RefreshButton.IsEnabled) -Name 'Malformed Graph inventory preserves the displayed inventory and restores Refresh through the actual UI completion path'
        $coreModulePath='unused fixture'
        $inventoryOperationScript="Write-Progress -Activity 'Synthetic progress' -Status 'Running'; throw 'Synthetic unhandled failure'"
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:GraphPowerShell.Streams.Error.Count -eq 0 -and $script:GraphPowerShell.Streams.Progress.Count -eq 0 -and $RefreshButton.IsEnabled) -Name 'Unhandled worker errors recover normally and release retained error/progress streams'
        $inventoryOperationScript="[pscustomobject]@{Kind='UnexpectedResult'}"
        Start-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($script:WorkflowApplied -eq 3 -and $RefreshButton.IsEnabled -and $RefreshButtonText.Text -eq 'Refresh' -and $script:WorkflowStatus -like '*could not complete*') -Name 'Unexpected worker output fails closed and restores the refresh controls'
        $script:AllDevices=@()
        Start-InventoryLoad
        Stop-InventoryLoad
        Wait-WorkflowFixture
        Assert-True -Condition ($EmptyState.Visibility -eq 'Visible' -and $EmptyStateTitle.Text -eq 'Refresh canceled' -and $LoadingOverlay.Visibility -eq 'Collapsed') -Name 'Canceling the first load shows a useful empty state rather than a blank table'

        $stressApplied=$script:WorkflowApplied
        $inventoryOperationScript="Start-Sleep -Milliseconds 5; [pscustomobject]@{Kind='InventoryResult';Devices=@('stress fixture');LoadedAt=[DateTimeOffset]::Now}"
        $stressControlsOk=$true
        for ($cycle=0; $cycle -lt 20; $cycle++) {
            Start-InventoryLoad
            if ($cycle % 2 -eq 0) { Stop-InventoryLoad }
            Wait-WorkflowFixture
            $stressControlsOk=$stressControlsOk -and $RefreshButton.IsEnabled -and $SignInButton.IsEnabled -and $RefreshButtonText.Text -eq 'Refresh'
        }
        Assert-True -Condition ($stressControlsOk -and $script:WorkflowApplied -eq $stressApplied + 10 -and $script:GraphRunspace.RunspaceAvailability -eq 'Available') -Name 'Twenty alternating refresh/cancel cycles leave the worker reusable and controls consistent'

        $script:PendingSecretRequest=[pscustomobject]@{VerificationGeneration=0}
        $script:RecoveryRequestCanceled=$false
        $script:MicrosoftVerificationCancelEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset)
        $null=Start-GraphOperation -Name MicrosoftVerification -ScriptText "Start-Sleep -Milliseconds 20; [pscustomobject]@{Kind='MicrosoftVerificationResult'}"
        Cancel-PendingRecoveryAction
        $wasSignaled=$script:MicrosoftVerificationCancelEvent.WaitOne(0)
        Wait-WorkflowFixture
        Assert-True -Condition ($wasSignaled -and $null -eq $script:PendingSecretRequest -and $script:WorkflowExposed -eq 0 -and $script:WorkflowToast -like 'Recovery action canceled*') -Name 'A late Microsoft verification success cannot revive canceled recovery intent'
        $script:MicrosoftVerificationCancelEvent.Dispose()
        $script:MicrosoftVerificationCancelEvent=$null

        foreach ($kind in @('Credential','BitLockerKey')) {
            $script:RecoveryRequestCanceled=$false
            $script:PendingCredentialAction='Copy'
            $script:PendingBitLockerAction='Reveal'
            $script:PendingCredentialVerificationGeneration=0
            $script:PendingBitLockerVerificationGeneration=0
            $script:ActiveRecoveryTab='LAPS'
            $payload=[pscustomobject]@{Kind=$(if($kind -eq 'Credential'){'CredentialResult'}else{'BitLockerKeyResult'});Password='synthetic';RecoveryKey='synthetic'}
            $null=Start-GraphOperation -Name $kind -ScriptText 'param($Payload) $Payload' -Arguments @($payload)
            if(-not $script:CurrentOperation.AsyncResult.AsyncWaitHandle.WaitOne(2000)){throw 'Synthetic completed-result race did not finish.'}
            Set-RecoveryTab -Tab BitLocker
            Set-RecoveryTab -Tab LAPS
            Wait-WorkflowFixture
            $released=if($kind -eq 'Credential'){$null -eq $payload.Password}else{$null -eq $payload.RecoveryKey}
            Assert-True -Condition ($script:WorkflowExposed -eq 0 -and $released -and $script:WorkflowToast -like 'Recovery action canceled*') -Name "Switching tabs after a $kind result completes discards it before UI completion"
        }
        . (Join-Path $PSScriptRoot 'Test-RecoveryCancellation.ps1')

        $script:PendingSecretRequest=[pscustomobject]@{VerificationGeneration=0}
        $script:LocalVerificationCancellation=[Threading.CancellationTokenSource]::new()
        $script:RecoveryRequestCanceled=$false
        Cancel-PendingRecoveryAction
        Assert-True -Condition $script:LocalVerificationCancellation.IsCancellationRequested -Name 'Changing recovery intent signals cancellation to a pending local verification'
        Complete-LocalSecretVerification -ForcedResult Verified
        Assert-True -Condition ($null -eq $script:PendingSecretRequest -and $script:WorkflowExposed -eq 0) -Name 'A delayed successful local verification cannot revive a canceled recovery action'
        $script:LocalVerificationCancellation.Dispose()
        $script:LocalVerificationCancellation=$null
        $script:IsSignedIn=$false
        Request-SecretAction -Kind LAPS -Action Copy
        Assert-True -Condition ($null -eq $script:PendingSecretRequest) -Name 'Recovery entry point rejects signed-out access even if invoked directly'
        . ([scriptblock]::Create($mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-BitLockerSelection'},$true).Extent.Text))
        Update-BitLockerSelection
        Assert-True -Condition ($BitLockerKeyIdText.Text -eq 'ID 22222222' -and $BitLockerKeyIdText.ToolTip -eq 'Recovery key ID: 22222222-2222-4222-8222-222222222222') -Name 'Recovery details show a compact key ID with the complete identifier on hover without fetching its secret'
        $BitLockerKeySelector.SelectedIndex=-1
        Update-BitLockerSelection
        Assert-True -Condition ($BitLockerKeyIdText.Text -eq '' -and -not $CopyRecoveryKeyButton.IsEnabled) -Name 'Clearing the recovery-key selection also clears its identifying label'
    }
    finally {
        if ($null -ne $script:GraphPowerShell) { $script:GraphPowerShell.Stop(); $script:GraphPowerShell.Dispose() }
        if ($null -ne $script:GraphRunspace) { $script:GraphRunspace.Dispose() }
        $script:GraphPowerShell=$null
        $script:GraphRunspace=$null
        $script:CurrentOperation=$null
        $testWindow.Close()
    }
}

foreach ($case in @(
    @{ Code='Authorization_RequestDenied'; Status=403; Message='token authentication requirement'; Expected='Access was denied*' }
    @{ Code='TooManyRequests'; Status=429; Message='authentication requests'; Expected='*throttling*' }
    @{ Code='ServiceUnavailable'; Status=503; Message='token service unavailable'; Expected='*temporarily unavailable*' }
    @{ Code='RequestTimeout'; Status=408; Message='token request timed out'; Expected='*timed out*' }
    @{ Code='TaskCanceledException'; Status=0; Message='The request timed out'; Expected='*timed out*' }
    @{ Code='WrongAccount'; Status=$null; Message='synthetic'; Expected='*different account*' }
    @{ Code='WrongTenant'; Status=$null; Message='synthetic'; Expected='*different tenant*' }
    @{ Code='MissingScopes'; Status=$null; Message='synthetic'; Expected='*missing required Graph permissions*' }
)) {
    $message=Get-FriendlyLapsErrorMessage -ErrorCode $case.Code -Message $case.Message -StatusCode $case.Status
    Assert-True -Condition ($message -like $case.Expected) -Name "Error guidance follows the actual failure category: $($case.Code)"
}
