# Actual production wheel handler and WPF templates, with fictional rows only.
# No visible window, input injection, sleep/resume, or live process modification.
& {
    Add-Type -AssemblyName PresentationFramework
    $scrollWindow=[Windows.Markup.XamlReader]::Parse($windowMarkup)
    $DeviceGrid=$scrollWindow.FindName('DeviceGrid')
    $items=@(1..100 | ForEach-Object {[pscustomobject]@{DeviceName=('DEMO-DEVICE-{0:000}' -f $_);PrimaryUser='Synthetic';Model='Fixture'}})
    $DeviceGrid.ItemsSource=$items
    . ([scriptblock]::Create($mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Find-DeviceScrollViewer'},$true).Extent.Text))
    $registration=$mainAst.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$DeviceGrid' -and $n.Member.Value -eq 'Add_PreviewMouseWheel'},$true)
    . ([scriptblock]::Create($registration.Extent.Text))
    function Flush-ScrollLayout {
        for($i=0;$i -lt 3;$i++) {
            $scrollWindow.Content.Measure([Windows.Size]::new(1264,741))
            $scrollWindow.Content.Arrange([Windows.Rect]::new(0,0,1264,741))
            $scrollWindow.Content.UpdateLayout()
            $null=$scrollWindow.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
        }
    }
    function Send-ScrollFixtureWheel {
        param([int]$Delta=-120)
        $wheel=[Windows.Input.MouseWheelEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,$Delta)
        $wheel.RoutedEvent=[Windows.Input.Mouse]::PreviewMouseWheelEvent
        $DeviceGrid.RaiseEvent($wheel)
        Flush-ScrollLayout
        return $wheel.Handled
    }
    try {
        Flush-ScrollLayout
        $viewer=Find-DeviceScrollViewer $DeviceGrid
        $handled=Send-ScrollFixtureWheel
        Assert-True -Condition ($handled -and $viewer.VerticalOffset -eq 36) -Name 'Initial wheel input moves the actual list by three quarters of a row'
        for($cycle=1;$cycle -le 5;$cycle++) {
            $oldViewer=Find-DeviceScrollViewer $DeviceGrid
            $template=$DeviceGrid.Template
            $DeviceGrid.Template=$null
            Flush-ScrollLayout
            $withoutViewerHandled=Send-ScrollFixtureWheel
            $DeviceGrid.Template=$template
            Flush-ScrollLayout
            $viewer=Find-DeviceScrollViewer $DeviceGrid
            $before=$viewer.VerticalOffset
            $handled=Send-ScrollFixtureWheel
            Assert-True -Condition (-not $withoutViewerHandled -and -not [object]::ReferenceEquals($oldViewer,$viewer) -and $handled -and $viewer.VerticalOffset -gt $before) -Name "Wheel survives visual-template rebuild $cycle and does not swallow input while the viewer is absent"
        }
        $viewer.ScrollToVerticalOffset(144)
        Flush-ScrollLayout
        $null=Send-ScrollFixtureWheel -Delta 120
        Assert-Equal -Actual $viewer.VerticalOffset -Expected 108 -Name 'Wheel and scrollbar/direct scrolling continue to share the live viewer'
        $DeviceGrid.ItemsSource=@($items[0]);Flush-ScrollLayout
        Assert-True -Condition (-not (Send-ScrollFixtureWheel)) -Name 'A non-scrollable filtered list leaves wheel input unhandled'
        $DeviceGrid.ItemsSource=$items;Flush-ScrollLayout
        $null=Send-ScrollFixtureWheel
        Assert-True -Condition ((Find-DeviceScrollViewer $DeviceGrid).VerticalOffset -gt 0) -Name 'Wheel resumes after the filter restores overflowing rows'
        Assert-True -Condition (-not (Send-ScrollFixtureWheel -Delta 0)) -Name 'Zero-delta wheel input is not swallowed'
        $viewer=Find-DeviceScrollViewer $DeviceGrid
        $viewer.ScrollToEnd();Flush-ScrollLayout
        $null=Send-ScrollFixtureWheel
        Assert-True -Condition ($viewer.VerticalOffset -le $viewer.ScrollableHeight) -Name 'Wheel movement remains bounded at the bottom of the list'
    }
    finally {$scrollWindow.Close()}
}
