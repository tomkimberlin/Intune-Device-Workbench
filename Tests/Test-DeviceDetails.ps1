# Synthetic-only detail copying and compliance, using the production formatter and clipboard algorithm.
& {
    $device = [pscustomobject]@{
        DeviceName='DEMO-DEVICE-ALPHA'; PrimaryUser='Ashley Morgan'; UserPrincipalName='ashley.morgan@contoso.com'
        SerialNumber='DEMO-SERIAL-ALPHA'; OperatingSystem='Windows'; OSVersion='10.0.26100'
        Password='MUST-NOT-COPY-PASSWORD'; RecoveryKey='MUST-NOT-COPY-KEY'; Credentials=@('MUST-NOT-COPY-CREDENTIALS')
    }
    $expected = @('Device: DEMO-DEVICE-ALPHA','Primary user: Ashley Morgan','UPN: ashley.morgan@contoso.com','Serial: DEMO-SERIAL-ALPHA','OS: Windows 10.0.26100') -join [Environment]::NewLine
    Assert-Equal -Actual (Format-DeviceDetails $device) -Expected $expected -Name 'Ticket details copy only the explicit metadata allowlist, never attached recovery fields'
    foreach ($state in @('Unassigned','Unavailable')) {
        $device.PrimaryUser=$state
        Assert-True -Condition ((Format-DeviceDetails $device).Contains("Primary user: $state")) -Name "Ticket details preserve primary-user $state without enrollment-user substitution"
    }
    $device.PrimaryUser='Ashley Morgan'
    $device.DeviceName="DEMO-DEVICE-ALPHA`r`nInjected: text$([char]0x2028)more$([char]0x202E)"
    $normalized=Format-DeviceDetails $device
    Assert-True -Condition (($normalized -split '\r?\n').Count -eq 5 -and $normalized -notmatch '[\p{Cf}\p{Zl}\p{Zp}]') -Name 'Untrusted metadata cannot inject extra ticket lines or invisible direction controls'
    $device.DeviceName='DEMO-DEVICE-ALPHA'
    Assert-Equal -Actual (Format-DeviceDetails $null) -Expected $null -Name 'No device produces no clipboard summary'
    $missing=Format-DeviceDetails ([pscustomobject]@{})
    Assert-True -Condition (($missing -split '\r?\n' | Where-Object {$_ -like '*: Unavailable'}).Count -eq 5) -Name 'Missing and Entra-only metadata are explicitly unavailable rather than invented'

    foreach ($case in @(
        @('compliant','Compliant','#15803D'), @('noncompliant','Not compliant','#B42318'),
        @('ingraceperiod','Grace period','#B45309'), @('conflict','Conflict','#B45309'), @('error','Error','#B42318'),
        @($null,'Unknown','#64748B'), @('unknown','Unknown','#64748B'), @('futureState','Unknown','#64748B'), @(' COMPLIANT ','Compliant','#15803D')
    )) {
        $presentation=Get-DeviceCompliancePresentation $case[0]
        Assert-True -Condition ($presentation.Text -eq $case[1] -and $presentation.Foreground -eq $case[2]) -Name "Compliance state '$($case[0])' has explicit text and a conservative color"
    }

    # Execute the actual event function against the native-call shim, not the user's clipboard.
    $copyAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Copy-SelectedDeviceDetails'},$true)
    $copySource=$copyAst.Extent.Text.Replace('[M365Workbench.Security.SecureClipboard]','[M365Workbench.TestDoubles.SecureClipboard]').Replace('([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle','[IntPtr]1')
    . ([scriptblock]::Create($copySource))
    $selected=$device
    function Get-SelectedDevice { return $selected }
    function Get-SensitiveClockNow { return $script:DetailsClock }
    function Update-ClipboardStatusForSelection { $script:DetailsStatusUpdates++; return $false }
    function Show-Toast { param($Message,$Kind) $script:DetailsToast=$Kind }
    $settings=@{ClipboardClearSeconds=45}
    $script:DetailsClock=[DateTimeOffset]::Parse('2026-10-22T12:00:00Z')
    $script:DetailsStatusUpdates=0
    $script:CurrentOperation=$null; $script:PendingSecretRequest=$null; $script:LocalVerificationTask=$null
    [M365Workbench.TestDoubles.SecureClipboard]::SetSensitiveText('SYNTHETIC-OLD-SECRET',[IntPtr]1)
    $script:ClipboardClearAt=$script:DetailsClock.AddSeconds(1)
    $script:ClipboardKind='LAPS'; $script:ClipboardDeviceId='11111111-1111-4111-8111-111111111111'; $script:ClipboardRecoveryKeyId='synthetic-key-id'
    Copy-SelectedDeviceDetails
    Assert-Equal -Actual ([M365Workbench.TestDoubles.SecureClipboard]::LastText) -Expected $expected -Name 'Actual copy handler replaces a synthetic secret with only the selected ticket details'
    Assert-True -Condition ($script:ClipboardKind -eq 'DeviceDetails' -and $script:ClipboardClearAt -eq $script:DetailsClock.AddSeconds(45) -and $null -eq $script:ClipboardDeviceId -and $null -eq $script:ClipboardRecoveryKeyId -and $script:DetailsStatusUpdates -eq 1) -Name 'Successful details copy replaces secret cleanup metadata and clears obsolete recovery countdown status'

    # Exercise the production timer: the replaced secret's old deadline must not clear details early.
    function Process-OperationOutput { }
    function Set-AppStatus { param($Message) }
    $script:ToastExpiresAt=[DateTimeOffset]::MinValue
    $script:CredentialExpiresAt=[DateTimeOffset]::MinValue
    $script:BitLockerExpiresAt=[DateTimeOffset]::MinValue
    $PasswordText=[pscustomobject]@{Text='••••••••••••••••'}
    $BitLockerKeyText=[pscustomobject]@{Text='••••••-••••••'}
    $tickAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$pollTimer' -and $n.Member.Extent.Text -eq 'Add_Tick'},$true)
    $tickBody=$tickAst.Arguments[0].ScriptBlock.Extent.Text
    $tick=[scriptblock]::Create($tickBody.Substring(1,$tickBody.Length-2).Replace('[M365Workbench.Security.SecureClipboard]','[M365Workbench.TestDoubles.SecureClipboard]'))
    $before=[M365Workbench.TestDoubles.SecureClipboard]::EmptyCount
    $script:DetailsClock=$script:DetailsClock.AddSeconds(2)
    & $tick
    Assert-Equal -Actual ([M365Workbench.TestDoubles.SecureClipboard]::EmptyCount) -Expected $before -Name 'Production timer ignores the replaced secret deadline after details copying'
    $script:DetailsClock=$script:DetailsClock.AddSeconds(44)
    & $tick
    Assert-True -Condition ([M365Workbench.TestDoubles.SecureClipboard]::EmptyCount -eq $before+1 -and $script:ClipboardClearAt -eq [DateTimeOffset]::MinValue -and $null -eq $script:ClipboardKind) -Name 'Production timer clears owned details at their own deadline and resets tracking'
    $script:DetailsClock=[DateTimeOffset]::Parse('2026-10-22T12:00:00Z')

    # A busy clipboard must preserve an outstanding secret cleanup obligation.
    [M365Workbench.TestDoubles.SecureClipboard]::SetSensitiveText('SYNTHETIC-OLD-SECRET',[IntPtr]1)
    $script:ClipboardKind='LAPS'; $script:ClipboardClearAt=$script:DetailsClock.AddSeconds(1)
    [M365Workbench.TestDoubles.SecureClipboard]::Busy=$true
    Copy-SelectedDeviceDetails
    [M365Workbench.TestDoubles.SecureClipboard]::Busy=$false
    Assert-True -Condition ($script:ClipboardKind -eq 'LAPS' -and $script:ClipboardClearAt -eq $script:DetailsClock.AddSeconds(1) -and [M365Workbench.TestDoubles.SecureClipboard]::LastText -eq 'SYNTHETIC-OLD-SECRET' -and $script:DetailsToast -eq 'Error') -Name 'Failed details copy preserves the previous secret deadline and ownership for retry'
    $null=[M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged()

    foreach ($block in @('Credential','BitLockerKey','Inventory','Pending','LocalVerification','NoSelection')) {
        $selected=$device
        $script:CurrentOperation=$null; $script:PendingSecretRequest=$null; $script:LocalVerificationTask=$null
        if ($block -in @('Credential','BitLockerKey','Inventory')) {$script:CurrentOperation=[pscustomobject]@{Name=$block}}
        elseif ($block -eq 'Pending') {$script:PendingSecretRequest=[pscustomobject]@{Kind='LAPS'}}
        elseif ($block -eq 'LocalVerification') {$script:LocalVerificationTask=[pscustomobject]@{IsCompleted=$false}}
        else {$selected=$null}
        $before=[M365Workbench.TestDoubles.SecureClipboard]::EmptyCount
        Copy-SelectedDeviceDetails
        Assert-Equal -Actual ([M365Workbench.TestDoubles.SecureClipboard]::EmptyCount) -Expected $before -Name "Details copy cannot compete with $block or copy a previous selection"
    }
    $selected=$device; $script:CurrentOperation=$null; $script:PendingSecretRequest=$null; $script:LocalVerificationTask=$null
    Copy-SelectedDeviceDetails
    $before=[M365Workbench.TestDoubles.SecureClipboard]::EmptyCount
    [M365Workbench.TestDoubles.SecureClipboard]::Sequence++
    Assert-True -Condition (-not [M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged() -and [M365Workbench.TestDoubles.SecureClipboard]::EmptyCount -eq $before) -Name 'Details cleanup cannot erase clipboard content subsequently written by another app'
}

# Compatibility aliases must forward the same CLI contract to the renamed implementation.
& {
    $tokens=$null; $errors=$null
    $legacyPath=Join-Path $appRoot 'M365Workbench.ps1'
    $legacyAst=[Management.Automation.Language.Parser]::ParseFile($legacyPath,[ref]$tokens,[ref]$errors)
    $actualParameters=@($mainAst.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath}) -join ','
    $legacyParameters=@($legacyAst.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath}) -join ','
    Assert-True -Condition ($errors.Count -eq 0 -and $actualParameters -eq $legacyParameters -and $legacyAst.Extent.Text.Contains("'IntuneDeviceWorkbench.ps1'") -and $legacyAst.Extent.Text.Contains('@PSBoundParameters')) -Name 'Legacy PowerShell entry point parses and forwards every supported argument to the current app'
    $legacyLauncher=[IO.File]::ReadAllText((Join-Path $appRoot 'Launch-M365Workbench.cmd'))
    Assert-True -Condition ($legacyLauncher.Contains('Launch-IntuneDeviceWorkbench.cmd') -and $legacyLauncher.Contains('exit /b %errorlevel%')) -Name 'Legacy command launcher forwards to the current launcher and preserves failure status'
}

# Real WPF layout and accessibility metadata, without showing a window or writing the clipboard.
& {
    $xamlAst=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml'},$true)
    foreach ($size in @(@(1100,680),@(1280,780),@(1600,900))) {
        $reader=[System.Xml.XmlNodeReader]::new([xml]$xamlAst.Right.Expression.Value)
        $layoutWindow=[System.Windows.Markup.XamlReader]::Load($reader); $reader.Close()
        try {
            $layoutWindow.FindName('DetailPanel').Visibility='Visible'
            $layoutWindow.FindName('NoSelectionPanel').Visibility='Collapsed'
            $layoutWindow.FindName('AuthOverlay').Visibility='Collapsed'
            $name=$layoutWindow.FindName('DetailDeviceName'); $name.Text='DEMO-DEVICE-WITH-A-VERY-LONG-NAME'
            $badge=$layoutWindow.FindName('HeaderComplianceBadge'); $badgeText=$layoutWindow.FindName('HeaderComplianceText')
            $badgeText.Text='Not compliant'; $badgeText.FontSize=13.125
            foreach ($tab in @('Laps','BitLocker')) {
                $layoutWindow.FindName('LapsRecoveryPanel').Visibility=if($tab -eq 'Laps'){'Visible'}else{'Collapsed'}
                $layoutWindow.FindName('BitLockerRecoveryPanel').Visibility=if($tab -eq 'BitLocker'){'Visible'}else{'Collapsed'}
                $root=$layoutWindow.Content
                $root.Measure([System.Windows.Size]::new($size[0]-16,$size[1]-39)); $root.Arrange([System.Windows.Rect]::new(0,0,$size[0]-16,$size[1]-39)); $root.UpdateLayout()
                $nameRight=$name.TranslatePoint([System.Windows.Point]::new($name.ActualWidth,0),$name.Parent).X
                $badgeLeft=$badge.TranslatePoint([System.Windows.Point]::new(0,0),$name.Parent).X
                Assert-True -Condition ($name.ActualWidth -gt 0 -and $nameRight -le $badgeLeft -and $badgeText.ActualWidth + 1 -ge $badgeText.DesiredSize.Width) -Name "Long device name and readable compliance badge do not overlap at $($size[0])px ($tab)"
                if ($size[0] -eq 1280) {
                    $copy=$layoutWindow.FindName($(if($tab -eq 'Laps'){'CopyPasswordButton'}else{'CopyRecoveryKeyButton'}))
                    $panel=$layoutWindow.FindName('DetailPanel')
                    $bottom=$copy.TranslatePoint([System.Windows.Point]::new(0,$copy.ActualHeight),$panel).Y
                    Assert-True -Condition ($bottom -le $panel.ActualHeight) -Name "$tab primary Copy remains fully visible at the default size with the new badge"
                }
            }
            $button=$layoutWindow.FindName('CopyDeviceDetailsButton')
            Assert-True -Condition ([System.Windows.Automation.AutomationProperties]::GetName($button) -eq 'Copy device details for a support ticket' -and $button.Focusable -and $button.ToolTip -like '*No recovery secrets*') -Name 'Secondary details action has keyboard focus, an explicit accessible name and its copy boundaries'
        }
        finally {$layoutWindow.Close()}
    }
}
