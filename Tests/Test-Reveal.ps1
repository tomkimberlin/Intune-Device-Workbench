# Run the production recovery controls and timer against a synthetic clock and clipboard.
& {
    foreach ($name in @('Clear-SecretDisplay','Set-PasswordStatus','Set-BitLockerStatus','Update-ClipboardStatusForSelection','Set-ProtectedClipboardText','Complete-CredentialAction','Complete-BitLockerAction','Invoke-CredentialAction')) {
        $functionAst = $mainAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text.Replace('M365Workbench.Security.SecureClipboard','M365Workbench.TestDoubles.SecureClipboard')))
    }
    $timer = $mainAst.Find({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$pollTimer' -and $n.Member.Value -eq 'Add_Tick' }, $true)
    $timerBody = $timer.Arguments[0].ScriptBlock.Extent.Text
    $tick = [scriptblock]::Create($timerBody.Substring(1,$timerBody.Length-2).Replace('M365Workbench.Security.SecureClipboard','M365Workbench.TestDoubles.SecureClipboard'))
    $window = [Windows.Markup.XamlReader]::Parse($windowMarkup)
    foreach ($name in @('AccountNameText','PasswordText','BitLockerKeyText','CopyAccountButton','CopyPasswordButtonText','CopyRecoveryKeyButtonText','RevealPasswordButton','RevealRecoveryKeyButton','PasswordStatusDot','BitLockerStatusDot','PasswordCountdownText','BitLockerCountdownText','BitLockerKeySelector')) {
        Set-Variable -Name $name -Value $window.FindName($name)
    }
    $windowHandle = [IntPtr]1
    $settings = @{ RevealSeconds=20; ClipboardClearSeconds=45; ExpectedAccount='admin@contoso.com' }
    $clock = @{ Now=[DateTimeOffset]::UnixEpoch }
    $device = [pscustomobject]@{ DeviceName='DEMO-DEVICE-ALPHA'; EntraDeviceId='11111111-1111-4111-8111-111111111111'; LapsAvailable=$true }
    $keyId = '22222222-2222-4222-8222-222222222222'
    $BitLockerKeySelector.ItemsSource = @([pscustomobject]@{ Id=$keyId })
    $BitLockerKeySelector.SelectedIndex = 0
    function Get-SensitiveClockNow { $clock.Now }
    function Get-SelectedDevice { $device }
    function Process-OperationOutput { }
    function Restore-SecretActionControls { }
    function Set-AppStatus { param($Message) }
    function Set-RecoveryActionFocus { param($Kind,$Action) }
    function Show-Toast { param($Message,$Kind) }
    function Request-SecretAction { throw 'Hiding a revealed value must not start another verification' }
    $script:CurrentCredential = $script:CurrentBitLockerKey = $script:LocalVerificationTask = $null
    $script:ToastExpiresAt = [DateTimeOffset]::MinValue
    try {
        foreach ($kind in @('LAPS','BitLocker')) {
            Clear-SecretDisplay
            $script:ClipboardKind = $null
            $clock.Now = [DateTimeOffset]::UnixEpoch
            if ($kind -eq 'LAPS') {
                $payload = [pscustomobject]@{ DeviceId=$device.EntraDeviceId; AccountName='DemoAdmin'; Password='SYNTHETIC-TEST' }
                $complete = 'Complete-CredentialAction'
                $countdown = $PasswordCountdownText
            } else {
                $payload = [pscustomobject]@{ DeviceId=$device.EntraDeviceId; RecoveryKeyId=$keyId; RecoveryKey=('111111-' * 7 + '111111') }
                $complete = 'Complete-BitLockerAction'
                $countdown = $BitLockerCountdownText
            }
            & $complete Reveal $payload
            $clock.Now = $clock.Now.AddSeconds(19)
            & $complete Copy $payload
            & $tick
            Assert-True -Condition ($script:RevealedSecretKind -eq $kind -and $countdown.Text -like 'Hides automatically in 1 second*') -Name "Copying a visible $kind value preserves the original reveal deadline and countdown"
            $clock.Now = $clock.Now.AddSeconds(1)
            & $tick
            Assert-True -Condition ($null -eq $script:RevealedSecretKind -and $null -eq $script:CurrentCredential -and $null -eq $script:CurrentBitLockerKey -and $countdown.Text -like '*clipboard clears in 44 seconds') -Name "After $kind hides, the clipboard countdown continues independently"
        }
        $maskShaped = [pscustomobject]@{ DeviceId=$device.EntraDeviceId; AccountName='DemoAdmin'; Password='••••••••••••••••' }
        Complete-CredentialAction Reveal $maskShaped
        Invoke-CredentialAction Reveal
        Assert-True -Condition ($null -eq $script:RevealedSecretKind -and $null -eq $maskShaped.Password) -Name 'Hide now also clears a password whose text happens to equal the mask'
    }
    finally {
        $null = [M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged()
        $window.Close()
    }
}
