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
    }
    finally { $accessibilityWindow.Close() }
}
