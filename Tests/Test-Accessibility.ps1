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

# A synthetic event sink exercises the production toast/expiry functions without
# installing a UIA listener or claiming screen-reader speech was tested.
& {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
namespace M365Workbench.StatusTests.Controls {
    public class TextBlock {
        public string Text { get; set; }
        public bool IsVisible { get; set; }
        public List<string> Announcements { get; } = new List<string>();
    }
    public class Border {
        public TextBlock Child { get; set; }
        public object Background { get; set; }
        public object BorderBrush { get; set; }
        private string visibility = "Collapsed";
        public string Visibility {
            get => visibility;
            set { visibility = value; Child.IsVisible = value == "Visible"; }
        }
    }
}
namespace M365Workbench.StatusTests.Media {
    public class BrushConverter { public string ConvertFromString(string value) => value; }
}
namespace M365Workbench.StatusTests.Automation.Peers {
    public enum AutomationEvents { LiveRegionChanged }
    public class AutomationPeer {
        public static bool HasListener;
        public static bool ListenerExists(AutomationEvents value) => HasListener;
    }
    public class UIElementAutomationPeer : AutomationPeer {
        private Controls.TextBlock control;
        public static UIElementAutomationPeer CreatePeerForElement(Controls.TextBlock value) => new UIElementAutomationPeer {control=value};
        public void RaiseAutomationEvent(AutomationEvents value) { control.Announcements.Add(control.Text); }
    }
}
'@
    foreach ($name in @('Set-LiveStatusText', 'Show-Toast')) {
        $source = $mainAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true).Extent.Text
        . ([scriptblock]::Create($source.Replace('System.Windows.', 'M365Workbench.StatusTests.').Replace('[Windows.', '[M365Workbench.StatusTests.')))
    }
    $expiry = $mainAst.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($script:ToastExpiresAt -ne')}, $true)
    $ToastText = [M365Workbench.StatusTests.Controls.TextBlock]::new()
    $ToastBorder = [M365Workbench.StatusTests.Controls.Border]::new()
    $ToastBorder.Child = $ToastText
    $ToastIcon = [pscustomobject]@{Text=''}
    $script:AccessibilityClock = [DateTimeOffset]::Parse('2026-11-04T12:00:00Z')
    function Get-SensitiveClockNow { $script:AccessibilityClock }
    [M365Workbench.StatusTests.Automation.Peers.AutomationPeer]::HasListener = $true
    $message = 'The clipboard is busy. Nothing was copied; try again.'
    Show-Toast -Message $message -Kind Error
    Assert-True -Condition ($ToastText.Announcements.Count -eq 1 -and $ToastText.Announcements[0] -eq $message) -Name 'A new visible toast raises an announcement after its complete message is available'

    $script:AccessibilityClock = $script:AccessibilityClock.AddSeconds(5)
    $now = $script:AccessibilityClock
    . ([scriptblock]::Create($expiry.Extent.Text))
    Assert-True -Condition ($ToastBorder.Visibility -eq 'Collapsed') -Name 'The real timer expiry hides the first toast before a repeated operation'
    Show-Toast -Message $message -Kind Error
    Assert-True -Condition ($ToastText.Announcements.Count -eq 2 -and $ToastText.Announcements[1] -eq $message -and $script:ToastExpiresAt -gt $now) -Name 'An identical new toast after expiry gets a fresh announcement and display deadline'

    $passiveEvents = $ToastText.Announcements.Count
    Set-LiveStatusText -Control $ToastText -Message $message
    Assert-True -Condition ($ToastText.Announcements.Count -eq $passiveEvents) -Name 'An unchanged passive status update does not repeat its announcement'
    $ToastBorder.Visibility = 'Collapsed'
    Set-LiveStatusText -Control $ToastText -Message 'Hidden update'
    Assert-True -Condition ($ToastText.Text -eq 'Hidden update' -and $ToastText.Announcements.Count -eq $passiveEvents) -Name 'Hidden status text can update without being announced'
    $ToastBorder.Visibility = 'Visible'
    [M365Workbench.StatusTests.Automation.Peers.AutomationPeer]::HasListener = $false
    Show-Toast -Message 'No listener update' -Kind Info
    Assert-True -Condition ($ToastText.Text -eq 'No listener update' -and $ToastText.Announcements.Count -eq $passiveEvents) -Name 'A missing accessibility listener does not prevent a normal toast update'
}
