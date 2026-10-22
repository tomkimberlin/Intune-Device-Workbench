# Real WPF layout at the supported minimum/default sizes. No tenant data or clipboard writes.
& {
    Add-Type -AssemblyName PresentationFramework
    $xamlAst = $mainAst.Find({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml'}, $true)
    foreach ($size in @(@(1100,680), @(1280,780), @(1600,900))) {
        $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlAst.Right.Expression.Value)
        $qualityWindow = [System.Windows.Markup.XamlReader]::Load($reader)
        $reader.Close()
        $qualityWindow.FindName('DetailPanel').Visibility = 'Visible'
        $qualityWindow.FindName('NoSelectionPanel').Visibility = 'Collapsed'
        $qualityWindow.FindName('AuthOverlay').Visibility = 'Collapsed'
        $qualityWindow.FindName('DetailDeviceName').Text = 'DEMO-DEVICE-ALPHA'
        $qualityWindow.FindName('DetailPrimaryUser').Text = 'Ashley Morgan'
        $qualityWindow.FindName('DetailUserPrincipalName').Text = 'ashley.morgan@contoso.com'
        $qualityWindow.FindName('AccountNameText').Text = 'DemoLocalAdministratorWithALongerAccountName'
        foreach ($tab in @('Laps','BitLocker')) {
            $qualityWindow.FindName('LapsRecoveryPanel').Visibility = if($tab -eq 'Laps'){'Visible'}else{'Collapsed'}
            $qualityWindow.FindName('BitLockerRecoveryPanel').Visibility = if($tab -eq 'BitLocker'){'Visible'}else{'Collapsed'}
            $status = $qualityWindow.FindName($(if($tab -eq 'Laps'){'PasswordCountdownText'}else{'BitLockerCountdownText'}))
            # Also exercise enlarged text, not just the default font size.
            $status.FontSize = 13.125
            foreach ($message in @('Copied securely • clipboard clears in 45 seconds','Protected clipboard cleared','Clipboard is busy — secure cleanup will retry')) {
                $status.Text = $message
                $root = $qualityWindow.Content
                $root.Measure([System.Windows.Size]::new($size[0]-16,$size[1]-39))
                $root.Arrange([System.Windows.Rect]::new(0,0,$size[0]-16,$size[1]-39))
                $root.UpdateLayout()
                $card = $status.Parent.Parent.Parent
                $origin = $status.TranslatePoint([System.Windows.Point]::new(0,0),$card)
                $available = $card.ActualWidth - $card.Padding.Right - $card.BorderThickness.Right - $origin.X
                $reference = [System.Windows.Controls.TextBlock]::new()
                $reference.Text=$message; $reference.FontFamily=$status.FontFamily; $reference.FontSize=$status.FontSize
                $reference.FontWeight=$status.FontWeight; $reference.TextWrapping='Wrap'
                [System.Windows.Media.TextOptions]::SetTextFormattingMode($reference,[System.Windows.Media.TextOptions]::GetTextFormattingMode($status))
                $reference.Measure([System.Windows.Size]::new([Math]::Max(1,$available),[double]::PositiveInfinity))
                $fits = $available -gt 0 -and $status.DesiredSize.Width -le $available + 1 -and $status.ActualHeight + 1 -ge $reference.DesiredSize.Height
                Assert-True -Condition $fits -Name "$tab status fits its card at $($size[0])px: $message"
            }
        }
        $footer=$qualityWindow.FindName('FooterStatusText')
        $footer.Text='Microsoft Graph could not complete the request. Retry, then check the tenant connection and permissions. Showing the previous inventory.'
        $counts=$qualityWindow.FindName('DeviceCountText')
        $counts.Text='5,000 shown • 500 Entra only • 5,000 LAPS • 5,000 BitLocker • 5,000 total'
        $qualityWindow.FindName('BusyIndicator').Visibility='Visible'
        $root.Measure([System.Windows.Size]::new($size[0]-16,$size[1]-39))
        $root.Arrange([System.Windows.Rect]::new(0,0,$size[0]-16,$size[1]-39))
        $root.UpdateLayout()
        $footerRight=$footer.TranslatePoint([System.Windows.Point]::new($footer.ActualWidth,0),$root).X
        $countsLeft=$counts.TranslatePoint([System.Windows.Point]::new(0,0),$root).X
        Assert-True -Condition ($footerRight -le $countsLeft -and $footer.ToolTip -eq $footer.Text) -Name "Long footer messages cannot overlap counts and remain available as a tooltip at $($size[0])px"
        if ($size[0] -eq 1280) {
            $qualityWindow.FindName('BitLockerCountdownText').Text='Copied securely • clipboard clears in 45 seconds'
            $qualityWindow.FindName('BitLockerKeyIdText').Text='ID ABCDEF12'
            foreach ($fontSize in @(10.5,13.125)) {
                $qualityWindow.FindName('BitLockerCountdownText').FontSize=$fontSize
                foreach ($volume in @('Operating system volume','Fixed data volume','Removable data volume')) {
                    $qualityWindow.FindName('BitLockerVolumeText').Text=$volume
                    $root.Measure([System.Windows.Size]::new($size[0]-16,$size[1]-39))
                    $root.Arrange([System.Windows.Rect]::new(0,0,$size[0]-16,$size[1]-39))
                    $root.UpdateLayout()
                    $copy=$qualityWindow.FindName('CopyRecoveryKeyButton')
                    $panel=$qualityWindow.FindName('DetailPanel')
                    $bottom=$copy.TranslatePoint([System.Windows.Point]::new(0,$copy.ActualHeight),$panel).Y
                    $volumeText=$qualityWindow.FindName('BitLockerVolumeText')
                    Assert-True -Condition ($bottom -le $panel.ActualHeight -and $volumeText.TextWrapping -eq 'NoWrap' -and $volumeText.ToolTip -eq $volume) -Name "BitLocker Copy stays fully visible at the default size at $fontSize pt with a key ID and $volume (button bottom $bottom; viewport $($panel.ActualHeight))"
                }
            }
        }
        $qualityWindow.Close()
    }
}

# Cached recovery values must use the same monotonic clock as the hiding timer.
& {
    foreach ($name in @('Invoke-CredentialAction','Invoke-BitLockerAction')) {
        . ([scriptblock]::Create($mainAst.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true).Extent.Text))
    }
    $DemoMode = $false
    $coreModulePath = $modulePath
    $PasswordText = [pscustomobject]@{Text='••••••••••••••••'}
    $BitLockerKeyText = [pscustomobject]@{Text='••••••-••••••'}
    $BitLockerKeySelector = [pscustomobject]@{SelectedItem=[pscustomobject]@{Id='22222222-2222-4222-8222-222222222222'}}
    function Get-SelectedDevice { [pscustomobject]@{EntraDeviceId='11111111-1111-4111-8111-111111111111';DeviceName='DEMO-DEVICE-ALPHA';LapsAvailable=$true;BitLockerAvailable=$true} }
    function Test-SecretVerificationGeneration { param($Generation) return $true }
    function Get-SensitiveClockNow { return $script:QualityClock }
    function Set-SecretActionBusy { param($Kind) }
    function Set-AppStatus { param($Message,[switch]$Busy) }
    function Start-GraphOperation { param($Name,$ScriptText,$Arguments) $script:QualityReads++; return $true }
    function Complete-CredentialAction { param($Action,$Credential) $script:QualityCacheUses++ }
    function Complete-BitLockerAction { param($Action,$KeyResult) $script:QualityCacheUses++ }
    $credentialOperationScript = 'unused fixture'
    $bitLockerKeyOperationScript = 'unused fixture'
    $script:CurrentOperation = $null
    $script:CurrentCredential = [pscustomobject]@{Password='synthetic'}
    $script:CurrentCredentialDeviceId = '11111111-1111-4111-8111-111111111111'
    $script:CurrentBitLockerKey = [pscustomobject]@{RecoveryKey='synthetic'}
    $script:CurrentBitLockerDeviceId = $script:CurrentCredentialDeviceId
    $script:CurrentBitLockerKeyId = $BitLockerKeySelector.SelectedItem.Id
    foreach ($expired in @($false,$true)) {
        $script:QualityClock = [DateTimeOffset]::Parse($(if($expired){'2099-01-01Z'}else{'2000-01-01Z'}))
        $script:CredentialExpiresAt = $script:QualityClock.AddSeconds($(if($expired){-1}else{20}))
        $script:BitLockerExpiresAt = $script:CredentialExpiresAt
        $script:QualityReads = 0
        $script:QualityCacheUses = 0
        Invoke-CredentialAction -Action Copy -VerificationGranted -VerificationGeneration 1
        Invoke-BitLockerAction -Action Copy -VerificationGranted -VerificationGeneration 1
        Assert-True -Condition ($script:QualityReads -eq $(if($expired){2}else{0}) -and $script:QualityCacheUses -eq $(if($expired){0}else{2})) -Name "Both recovery caches honor elapsed-time expiry despite a different wall clock (expired=$expired)"
    }
}

& {
    foreach ($name in @('Complete-GraphOperation','Get-OperationResultObject','Restore-SecretActionControls','Reset-InventoryControls')) {
        . ([scriptblock]::Create($mainAst.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true).Extent.Text))
    }
    function Get-SelectedDevice { [pscustomobject]@{LapsAvailable=$true;BitLockerAvailable=$true;BitLockerKeys=@(1)} }
    function Clear-SecretVerificationState { $script:QualityRevoked=$true }
    function Clear-SecretDisplay { $script:QualityHidden=$true }
    function Clear-AuthenticationClipboard { $script:QualityClipboardCleanup=$true }
    function Set-AuthenticationDisplay { param($SignedIn,$Text) $script:IsSignedIn=$SignedIn }
    function Set-AppStatus { param($Message) }
    function Show-Toast { param($Message,$Kind) }
    foreach ($name in @('CopyPasswordButton','RevealPasswordButton','CopyPasswordButtonText','CopyRecoveryKeyButton','RevealRecoveryKeyButton','CopyRecoveryKeyButtonText','RefreshButton','SignInButton','LoadingOverlay','RefreshButtonText','RefreshIcon')) {
        Set-Variable -Name $name -Value ([pscustomobject]@{IsEnabled=$true;Text='';Visibility='Visible';ToolTip=''})
    }
    $BitLockerKeySelector=[pscustomobject]@{SelectedItem=[pscustomobject]@{Id='synthetic'};IsEnabled=$true}
    $script:IsSignedIn=$true
    $script:QualityRevoked=$false
    $script:QualityHidden=$false
    $script:QualityClipboardCleanup=$false
    $script:AllDevices=@('synthetic')
    $script:GraphPowerShell=[pscustomobject]@{Streams=[pscustomobject]@{}}
    $script:GraphPowerShell.Streams | Add-Member -MemberType ScriptMethod -Name ClearStreams -Value { }
    $script:GraphPowerShell | Add-Member -MemberType ScriptMethod -Name EndInvoke -Value {param($AsyncResult)}
    $inputFixture=[System.Management.Automation.PSDataCollection[psobject]]::new()
    $outputFixture=[System.Management.Automation.PSDataCollection[psobject]]::new()
    $outputFixture.Add([pscustomobject]@{Kind='Error';ErrorCode='InvalidAuthenticationToken';Message='Synthetic expired sign-in';StatusCode=401})
    Complete-GraphOperation ([pscustomobject]@{Name='Inventory';AsyncResult=$null;Input=$inputFixture;Output=$outputFixture;StopAsyncResult=$null;CancellationRequested=$false})
    Assert-True -Condition (-not $script:IsSignedIn -and $script:QualityRevoked -and $script:QualityHidden) -Name 'Actual Graph 401 result invalidates sign-in, verification, and displayed secrets'
    Assert-True -Condition (-not $CopyPasswordButton.IsEnabled -and -not $RevealPasswordButton.IsEnabled -and -not $CopyRecoveryKeyButton.IsEnabled -and -not $RevealRecoveryKeyButton.IsEnabled) -Name 'Recovery actions stay disabled after sign-in expiry'
    Assert-True -Condition $script:QualityClipboardCleanup -Name 'Expired sign-in requests immediate protected-clipboard cleanup'
}
