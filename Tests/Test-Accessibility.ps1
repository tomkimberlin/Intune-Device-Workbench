# Query real WPF automation peers: a literal Name on a TextBlock can hide its
# actual message from accessibility clients even though the window looks correct.
& {
    Add-Type -AssemblyName PresentationFramework
    $xamlNode = $mainAst.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$xaml'
    }, $true)
    $reader = [System.Xml.XmlNodeReader]::new([xml]$xamlNode.Right.Expression.Value)
    $accessibilityWindow = [System.Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    try {
        foreach ($name in @('Set-LiveStatusText', 'Set-AppStatus', 'Show-Toast', 'Stop-SecretVerification')) {
            . ([scriptblock]::Create($mainAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true).Extent.Text))
        }
        foreach ($case in @(
            @{ Control='FooterStatusText'; First='Loading devices and recovery status...'; Second='Microsoft sign-in has expired. Sign in again.'; Live='Polite' }
            @{ Control='ToastText'; First='The clipboard is busy. Nothing was copied; try again.'; Second='Recovery action canceled. No password was exposed.'; Live='Assertive' }
            @{ Control='AuthOverlayStatus'; First='Preparing verification...'; Second='Code copied. Complete sign-in in the browser.'; Live='Polite' }
        )) {
            $control = $accessibilityWindow.FindName($case.Control)
            $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($control)
            $control.Text = $case.First
            Assert-Equal -Actual $peer.GetName() -Expected $case.First -Name "$($case.Control) exposes its complete message to accessibility clients"
            $control.Text = $case.Second
            Assert-Equal -Actual $peer.GetName() -Expected $case.Second -Name "$($case.Control) exposes the changed message rather than a stale or generic label"
            Assert-Equal -Actual ([string]$peer.GetLiveSetting()) -Expected $case.Live -Name "$($case.Control) retains its existing announcement priority"
        }
        foreach ($name in @('FooterStatusText', 'BusyIndicator', 'ToastText', 'ToastBorder', 'ToastIcon', 'CancelVerificationButton', 'AuthOverlayStatus')) {
            Set-Variable -Name $name -Value $accessibilityWindow.FindName($name)
        }
        function Get-SensitiveClockNow { [DateTimeOffset]::Parse('2026-11-04T12:00:00Z') }
        $script:AccessibilityRevocations = 0
        function Clear-SecretVerificationState { $script:AccessibilityRevocations++ }

        $failureMessage = 'Microsoft Graph could not complete the request. Showing the previous inventory.'
        Set-AppStatus -Message $failureMessage
        $footerPeer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($FooterStatusText)
        Assert-True -Condition ($footerPeer.GetName() -eq $failureMessage -and $BusyIndicator.Visibility -eq 'Collapsed') -Name 'The production status update exposes the full failure message and ends its busy indication'

        $toastMessage = 'The clipboard is busy. Nothing was copied; try again.'
        Show-Toast -Message $toastMessage -Kind Error
        $toastPeer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($ToastText)
        Assert-True -Condition ($toastPeer.GetName() -eq $toastMessage -and $ToastBorder.Visibility -eq 'Visible' -and $script:ToastExpiresAt -gt (Get-SensitiveClockNow)) -Name 'The production toast exposes its actual error while retaining its normal visibility deadline'

        Stop-SecretVerification
        $verificationPeer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($AuthOverlayStatus)
        Assert-True -Condition ($verificationPeer.GetName() -eq 'Canceling verification...' -and -not $CancelVerificationButton.IsEnabled -and $script:AccessibilityRevocations -eq 1) -Name 'Canceling verification exposes its current status while still revoking the grant'
    }
    finally { $accessibilityWindow.Close() }
}
