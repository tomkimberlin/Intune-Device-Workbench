[CmdletBinding()]
param(
    [switch]$DemoMode,
    [switch]$NoAutoConnect,
    [string]$RenderPreviewPath,
    [ValidateSet('Workspace', 'MicrosoftVerification', 'LapsClipboard', 'BitLockerClipboard', 'InventoryRefreshing')]
    [string]$RenderPreviewState = 'Workspace'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# All clipboard, reveal and verification deadlines share this elapsed-time clock.
$script:SensitiveClockOrigin = [DateTimeOffset]::UtcNow
$script:SensitiveClock = [Diagnostics.Stopwatch]::StartNew()
function Get-SensitiveClockNow {
    return $script:SensitiveClockOrigin.AddTicks($script:SensitiveClock.Elapsed.Ticks)
}

if (-not [string]::IsNullOrWhiteSpace($RenderPreviewPath) -and -not $DemoMode) {
    throw 'Preview rendering requires -DemoMode. Live tenant data must not be rendered to disk.'
}

$script:AppStarted = $false
try {
if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    throw 'PowerShell 7.4 or newer is required.'
}
$appRoot = $PSScriptRoot
$operationsPath = Join-Path $appRoot 'Operations'
$settingsPath = Join-Path $appRoot 'M365Workbench.settings.psd1'
$coreModulePath = Join-Path $appRoot 'M365Workbench.Core.psm1'
$secureClipboardPath = Join-Path $appRoot 'SecureClipboard.cs'
$windowsHelloPath = Join-Path $appRoot 'WindowsHelloVerifier.cs'
$iconPath = Join-Path $appRoot 'assets\M365Workbench.ico'
$shellIdentityPath = Join-Path $appRoot 'assets\WindowsShellIdentity.cs'
# Retain the installed shortcut identity and settings paths across the display-name change.
$appUserModelId = 'M365Workbench.Desktop'

if ($null -eq ('M365Workbench.WindowsShellIdentity' -as [type])) {
    Add-Type -Path $shellIdentityPath
}
[M365Workbench.WindowsShellIdentity]::SetCurrentProcessAppId($appUserModelId)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if ($DemoMode) {
    $settings = @{
        TenantId                  = 'contoso.onmicrosoft.com'
        TenantObjectId            = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
        ExpectedAccount           = 'laps-admin@contoso.onmicrosoft.com'
        RequiredScopes            = @(
            'Device.Read.All'
            'DeviceManagementManagedDevices.Read.All'
            'DeviceLocalCredential.Read.All'
            'BitlockerKey.ReadBasic.All'
            'BitlockerKey.Read.All'
        )
        GraphModuleMinimumVersion = '2.38.0'
        ClipboardClearSeconds     = 45
        RevealSeconds             = 20
        SecretVerificationMode    = 'Preferred'
        SecretVerificationSeconds = 600
        OnlyRecoveryReadyByDefault = $true
    }
}
elseif (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settings = Import-PowerShellDataFile -LiteralPath $settingsPath
}
else {
    throw "Configuration file not found. Copy 'M365Workbench.settings.example.psd1' to 'M365Workbench.settings.psd1' and enter your tenant settings."
}

$secretVerificationMode = if ($settings.ContainsKey('SecretVerificationMode')) {
    [string]$settings.SecretVerificationMode
}
else {
    'Preferred'
}
if ($secretVerificationMode -notin @('Preferred', 'Required', 'Disabled')) {
    throw "SecretVerificationMode must be Preferred, Required, or Disabled."
}

$secretVerificationSeconds = if ($settings.ContainsKey('SecretVerificationSeconds')) {
    [int]$settings.SecretVerificationSeconds
}
else {
    600
}
if ($secretVerificationSeconds -lt 60 -or $secretVerificationSeconds -gt 3600) {
    throw 'SecretVerificationSeconds must be between 60 and 3600.'
}

Import-Module $coreModulePath -Force
$settings.ClipboardClearSeconds = Get-WorkbenchTimeoutSeconds $settings 'ClipboardClearSeconds' 45
$settings.RevealSeconds = Get-WorkbenchTimeoutSeconds $settings 'RevealSeconds' 20

if ($null -eq ('M365Workbench.Security.SecureClipboard' -as [type])) {
    Add-Type -Path $secureClipboardPath
}
if ($null -eq ('M365Workbench.Security.WindowsHelloVerifier' -as [type])) {
    Add-Type -Path $windowsHelloPath
}
if ($null -eq ('M365Workbench.Security.WindowsSessionNotifications' -as [type])) {
    Add-Type -Path (Join-Path $appRoot 'WindowsSessionNotifications.cs')
}

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    [System.Windows.MessageBox]::Show(
        'Start Intune Device Workbench from its desktop shortcut or Launch-IntuneDeviceWorkbench.cmd so PowerShell uses STA mode.',
        'Intune Device Workbench',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
    exit 1
}

$windowMarkupPath = Join-Path $appRoot 'assets\WorkbenchWindow.xaml'
$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($windowMarkupPath))
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath, [UriKind]::Absolute))
}
if (-not [string]::IsNullOrWhiteSpace($RenderPreviewPath)) {
    # A synthetic off-screen preview should not shrink to the CI desktop work area.
    $window.MinWidth = 1280
    $window.MinHeight = 1000
    $window.Width = 1280
    $window.Height = 1000
    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $window.WindowStartupLocation = 'Manual'
    $window.Left = [System.Windows.SystemParameters]::VirtualScreenLeft - $window.Width - 100
    $window.Top = [System.Windows.SystemParameters]::VirtualScreenTop - $window.Height - 100
}
$windowHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
[M365Workbench.WindowsShellIdentity]::SetWindowAppId($windowHandle, $appUserModelId)

$controlNames = @(
    'AuthDot', 'AuthStatusText', 'SignInButton', 'SearchBox', 'SearchHint', 'ClearSearchButton',
    'EntraOnlyFilterContainer', 'EntraOnlyCheckBox', 'EntraOnlyFilterCount', 'OnlyReadyCheckBox', 'RefreshButton', 'RefreshButtonText', 'RefreshIcon', 'DeviceTableSurface', 'DeviceGrid', 'EmptyState',
    'EmptyStateTitle', 'EmptyStateDescription',
    'LoadingOverlay', 'LoadingText', 'NoSelectionPanel', 'DetailPanel', 'DetailDeviceName',
    'HeaderComplianceBadge', 'HeaderComplianceText', 'CopyDeviceDetailsButton',
    'DetailPrimaryUser', 'DetailUserPrincipalName', 'DetailLapsBadge', 'DetailLapsDot', 'DetailBitLockerBadge', 'OpenIntuneButton', 'OpenEntraButton', 'EntraOnlyNotice',
    'DetailBitLockerDot', 'DetailBitLockerStatus', 'LapsTabButton', 'BitLockerTabButton', 'LapsRecoveryPanel',
    'BitLockerRecoveryPanel', 'AccountNameText', 'PasswordText',
    'PasswordStatusDot', 'PasswordCountdownText', 'CopyPasswordButton', 'CopyPasswordButtonText',
    'RevealPasswordButton', 'CopyAccountButton', 'DetailLapsStatus', 'DetailModel', 'DetailLastSync',
    'DetailBackupDate', 'DetailRefreshDate', 'BitLockerKeySelector', 'BitLockerVolumeText', 'BitLockerKeyIdText', 'BitLockerKeyText',
    'BitLockerStatusDot', 'BitLockerCountdownText', 'BitLockerCreatedText', 'CopyRecoveryKeyButton',
    'CopyRecoveryKeyButtonText', 'RevealRecoveryKeyButton', 'DetailSerial', 'DetailOperatingSystem',
    'DetailEntraActivity', 'DetailEncrypted', 'DetailOwnership', 'DetailJoinType', 'DetailComplianceDot',
    'DetailCompliance', 'DetailManagementBadge', 'DetailSourceDot', 'DetailSource', 'BusyIndicator', 'FooterStatusText', 'DeviceCountText', 'ToastBorder', 'ToastIcon',
    'ToastText', 'AuthOverlay', 'AuthOverlayTitle', 'AuthOverlaySubtitle', 'AuthOverlayInstruction', 'AuthExpectedAccountText', 'DeviceCodeText', 'AuthOverlayStatus',
    'CopyCodeButton', 'OpenSignInButton', 'CancelVerificationButton', 'AuthOverlayFooter'
)

foreach ($name in $controlNames) {
    Set-Variable -Name $name -Value $window.FindName($name)
}

$AuthExpectedAccountText.Text = [string]$settings.ExpectedAccount

$script:GraphRunspace = $null
$script:GraphPowerShell = $null
$script:CurrentOperation = $null
$script:AllDevices = @()
$script:DeviceView = $null
$script:IsSignedIn = $false
$script:LastDeviceCode = $null
$script:SignInPageOpenedForCode = $null
$script:RevealedSecretKind = $null
$script:CurrentCredential = $null
$script:CredentialExpiresAt = [DateTimeOffset]::MinValue
$script:CurrentBitLockerKey = $null
$script:BitLockerExpiresAt = [DateTimeOffset]::MinValue
$script:ClipboardClearAt = [DateTimeOffset]::MinValue
$script:ClipboardDeviceId = $null
$script:ClipboardKind = $null
$script:ClipboardRecoveryKeyId = $null
$script:PendingCredentialAction = $null
$script:PendingBitLockerAction = $null
$script:PendingCredentialVerificationGeneration = $null
$script:PendingBitLockerVerificationGeneration = $null
$script:PendingSecretRequest = $null
$script:RecoveryRequestCanceled = $false
$script:LocalVerificationTask = $null
$script:LocalVerificationCancellation = $null
$script:MicrosoftVerificationCancelEvent = $null
$script:SecretVerifiedUntil = [DateTimeOffset]::MinValue
$script:RecentInteractiveAuthenticationUntil = [DateTimeOffset]::MinValue
$script:SecretVerificationGeneration = 0
$script:AuthenticationDeviceCodeObserved = $false
$script:AuthenticationVerificationGeneration = $null
$script:ActiveRecoveryTab = 'LAPS'
$script:ToastExpiresAt = [DateTimeOffset]::MinValue
$script:SelectionChanging = $false

function Find-DeviceScrollViewer {
    param([Parameter(Mandatory)][System.Windows.DependencyObject]$Parent)

    if ($Parent -is [System.Windows.Controls.ScrollViewer]) {
        return $Parent
    }

    $childCount = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent)
    for ($index = 0; $index -lt $childCount; $index++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $index)
        $viewer = Find-DeviceScrollViewer -Parent $child
        if ($null -ne $viewer) {
            return $viewer
        }
    }

    return $null
}

function Set-LiveStatusText {
    param(
        [Parameter(Mandatory)][System.Windows.Controls.TextBlock]$Control,
        [Parameter(Mandatory)][string]$Message,
        [switch]$AnnounceUnchanged
    )

    if ($Control.Text -ceq $Message -and -not $AnnounceUnchanged) { return }
    $Control.Text = $Message
    # LiveSetting describes priority; WPF still requires an explicit change event.
    if ($Control.IsVisible -and [System.Windows.Automation.Peers.AutomationPeer]::ListenerExists([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)) {
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Control)
        if ($null -ne $peer) {
            $peer.RaiseAutomationEvent([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)
        }
    }
}

function Set-AppStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$Busy
    )

    Set-LiveStatusText -Control $FooterStatusText -Message $Message
    $BusyIndicator.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
}

function Set-AuthenticationDisplay {
    param(
        [bool]$SignedIn,
        [string]$Text
    )

    $script:IsSignedIn = $SignedIn
    $AuthStatusText.Text = $Text
    $AuthDot.Fill = if ($SignedIn) { '#22A06B' } else { '#94A3B8' }
    $SignInButton.Content = if ($SignedIn) { 'Reconnect' } else { 'Sign in' }
}

function Show-Toast {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Error')][string]$Kind = 'Info'
    )

    $brushConverter = [Windows.Media.BrushConverter]::new()
    switch ($Kind) {
        'Success' {
            $ToastBorder.Background = $brushConverter.ConvertFromString('#14532D')
            $ToastBorder.BorderBrush = $brushConverter.ConvertFromString('#166534')
            $ToastIcon.Text = [string][char]0x2713
        }
        'Error' {
            $ToastBorder.Background = $brushConverter.ConvertFromString('#7F1D1D')
            $ToastBorder.BorderBrush = $brushConverter.ConvertFromString('#991B1B')
            $ToastIcon.Text = '!'
        }
        default {
            $ToastBorder.Background = $brushConverter.ConvertFromString('#172033')
            $ToastBorder.BorderBrush = $brushConverter.ConvertFromString('#334155')
            $ToastIcon.Text = 'i'
        }
    }
    $ToastBorder.Visibility = 'Visible'
    Set-LiveStatusText -Control $ToastText -Message $Message -AnnounceUnchanged
    $script:ToastExpiresAt = (Get-SensitiveClockNow).AddSeconds(4)
}

function Set-PasswordStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$DotColor = '#94A3B8',
        [string]$TextColor = '#64748B'
    )

    $brushConverter = [Windows.Media.BrushConverter]::new()
    $PasswordStatusDot.Fill = $brushConverter.ConvertFromString($DotColor)
    $PasswordCountdownText.Foreground = $brushConverter.ConvertFromString($TextColor)
    $PasswordCountdownText.Text = $Message
}

function Set-BitLockerStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$DotColor = '#94A3B8',
        [string]$TextColor = '#64748B'
    )

    $brushConverter = [Windows.Media.BrushConverter]::new()
    $BitLockerStatusDot.Fill = $brushConverter.ConvertFromString($DotColor)
    $BitLockerCountdownText.Foreground = $brushConverter.ConvertFromString($TextColor)
    $BitLockerCountdownText.Text = $Message
}

function Clear-SecretDisplay {
    param(
        [switch]$PreservePasswordStatus,
        [switch]$PreserveBitLockerStatus
    )

    $script:RevealedSecretKind = $null
    if ($null -ne $script:CurrentCredential) {
        $passwordProperty = $script:CurrentCredential.PSObject.Properties['Password']
        if ($null -ne $passwordProperty) {
            $passwordProperty.Value = $null
        }
    }

    $script:CurrentCredential = $null
    $script:CredentialExpiresAt = [DateTimeOffset]::MinValue
    $PasswordText.Text = '••••••••••••••••'
    $CopyPasswordButtonText.Text = 'Copy password'
    if (-not $PreservePasswordStatus) {
        Set-PasswordStatus -Message 'Password remains hidden until requested'
    }
    $RevealPasswordButton.Content = 'Reveal briefly'

    if ($null -ne $script:CurrentBitLockerKey) {
        $keyProperty = $script:CurrentBitLockerKey.PSObject.Properties['RecoveryKey']
        if ($null -ne $keyProperty) {
            $keyProperty.Value = $null
        }
    }
    $script:CurrentBitLockerKey = $null
    $script:BitLockerExpiresAt = [DateTimeOffset]::MinValue
    $BitLockerKeyText.Text = '••••••-••••••-••••••-••••••-••••••-••••••-••••••-••••••'
    $CopyRecoveryKeyButtonText.Text = 'Copy recovery key'
    if (-not $PreserveBitLockerStatus) {
        Set-BitLockerStatus -Message 'Recovery key remains hidden until requested'
    }
    $RevealRecoveryKeyButton.Content = 'Reveal briefly'
}

function Update-ClipboardStatusForSelection {
    $selected = Get-SelectedDevice
    $now = Get-SensitiveClockNow
    if ($null -ne $selected -and
        -not [string]::IsNullOrWhiteSpace([string]$script:ClipboardDeviceId) -and
        [string]::Equals([string]$selected.EntraDeviceId, [string]$script:ClipboardDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
        $script:ClipboardClearAt -gt $now) {
        $seconds = [Math]::Max(0, [Math]::Ceiling(($script:ClipboardClearAt - $now).TotalSeconds))
        $message = "Copied securely • clipboard clears in $seconds seconds"
        if ($script:ClipboardKind -eq 'LAPS' -and $script:RevealedSecretKind -ne 'LAPS') {
            if ($PasswordCountdownText.Text -ne $message) {
                Set-PasswordStatus -Message $message -DotColor '#15803D' -TextColor '#166534'
            }
            return $true
        }
        if ($script:ClipboardKind -eq 'BitLocker' -and $script:RevealedSecretKind -ne 'BitLocker') {
            $selectedKey = $BitLockerKeySelector.SelectedItem
            if ($null -ne $selectedKey -and
                [string]::Equals([string]$selectedKey.Id, [string]$script:ClipboardRecoveryKeyId, [StringComparison]::OrdinalIgnoreCase)) {
                if ($BitLockerCountdownText.Text -ne $message) {
                    Set-BitLockerStatus -Message $message -DotColor '#15803D' -TextColor '#166534'
                }
                return $true
            }
        }
    }

    if ($script:RevealedSecretKind -ne 'LAPS' -and $PasswordCountdownText.Text -ne 'Password remains hidden until requested') {
        Set-PasswordStatus -Message 'Password remains hidden until requested'
    }
    if ($script:RevealedSecretKind -ne 'BitLocker' -and $BitLockerCountdownText.Text -ne 'Recovery key remains hidden until requested') {
        Set-BitLockerStatus -Message 'Recovery key remains hidden until requested'
    }
    return $false
}

function Open-DeviceSignInPage {
    try {
        Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'rundll32.exe') -ArgumentList 'url.dll,FileProtocolHandler', '"https://login.microsoft.com/device"' -ErrorAction Stop
    }
    catch {
        Set-LiveStatusText -Control $AuthOverlayStatus -Message 'Open https://login.microsoft.com/device in your browser and enter the code shown here.'
    }
}

function Set-ProtectedClipboardText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateSet('LAPS','BitLocker','DeviceDetails','Account','DeviceCode')][string]$Kind,
        [AllowNull()][object]$DeviceId,
        [AllowNull()][object]$RecoveryKeyId,
        [int]$ClearSeconds = $settings.ClipboardClearSeconds
    )
    $deadline = (Get-SensitiveClockNow).AddSeconds($ClearSeconds)
    [M365Workbench.Security.SecureClipboard]::SetSensitiveText($Text, $windowHandle)
    # A failed write must leave the previous item's cleanup obligation intact.
    $script:ClipboardClearAt = $deadline
    $script:ClipboardKind = $Kind
    $script:ClipboardDeviceId = $DeviceId
    $script:ClipboardRecoveryKeyId = $RecoveryKeyId
}

function Copy-SelectedDeviceDetails {
    $selected = Get-SelectedDevice
    # A late recovery Copy must never replace the metadata the operator just copied.
    if ($null -eq $selected -or $null -ne $script:CurrentOperation -or
        $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask) { return }

    try {
        $text = Format-DeviceDetails -Device $selected
        Set-ProtectedClipboardText -Text $text -Kind DeviceDetails
        $null = Update-ClipboardStatusForSelection
        Show-Toast -Message "Device details copied • clipboard clears in $($settings.ClipboardClearSeconds) seconds" -Kind Success
    }
    catch {
        Show-Toast -Message 'The clipboard is busy or unavailable. Try again.' -Kind Error
    }
}

function Open-SelectedDevicePortal {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Intune', 'Entra')]
        [string]$Portal
    )

    $selected = Get-SelectedDevice
    $uri = Get-DeviceAdminPortalUri -Portal $Portal -Device $selected
    if ($null -eq $uri) {
        Show-Toast -Message "No $Portal record is available for this device." -Kind Error
        return
    }

    $expectedHost = if ($Portal -eq 'Intune') { 'intune.microsoft.com' } else { 'entra.microsoft.com' }
    if ($uri.Scheme -ne [Uri]::UriSchemeHttps -or
        -not [string]::Equals($uri.Host, $expectedHost, [StringComparison]::OrdinalIgnoreCase)) {
        Show-Toast -Message "The $Portal link could not be validated." -Kind Error
        return
    }

    try {
        Start-Process -FilePath (Join-Path ([Environment]::SystemDirectory) 'rundll32.exe') -ArgumentList 'url.dll,FileProtocolHandler', $uri.AbsoluteUri -ErrorAction Stop
        Show-Toast -Message "Opening $Portal for $([string]$selected.DeviceName)." -Kind Success
    }
    catch {
        Show-Toast -Message "Windows could not open the $Portal admin center." -Kind Error
    }
}

function Clear-AuthenticationClipboard {
    $script:LastDeviceCode = $null
    $script:SignInPageOpenedForCode = $null
    $DeviceCodeText.Text = ''
    $CopyCodeButton.IsEnabled = $false
    $OpenSignInButton.IsEnabled = $false
    try {
        $null = [M365Workbench.Security.SecureClipboard]::ClearIfUnchanged()
        $script:ClipboardClearAt = [DateTimeOffset]::MinValue
        $script:ClipboardDeviceId = $null
        $script:ClipboardKind = $null
        $script:ClipboardRecoveryKeyId = $null
    }
    catch {
        $script:ClipboardClearAt = Get-SensitiveClockNow
    }
}

function Set-DeviceCode {
    param([Parameter(Mandatory)][string]$Code)

    $script:LastDeviceCode = $Code
    $DeviceCodeText.Text = $Code
    $CopyCodeButton.IsEnabled = $true
    $OpenSignInButton.IsEnabled = $true

    try {
        Set-ProtectedClipboardText -Text $Code -Kind DeviceCode
        Set-LiveStatusText -Control $AuthOverlayStatus -Message "Code copied. Sign in as $($settings.ExpectedAccount)."
    }
    catch {
        Set-LiveStatusText -Control $AuthOverlayStatus -Message 'The code is shown above. Copy it manually if needed.'
    }

    if ($script:SignInPageOpenedForCode -ne $Code) {
        $script:SignInPageOpenedForCode = $Code
        Open-DeviceSignInPage
    }
    if ($CancelVerificationButton.Visibility -eq 'Visible') {
        $null = $CancelVerificationButton.Focus()
    }
    else {
        $null = $OpenSignInButton.Focus()
    }
}

function Initialize-GraphWorker {
    if ($null -ne $script:GraphRunspace) {
        return
    }

    $runspace = $null
    $pipeline = $null
    try {
        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
        $runspace.ApartmentState = [Threading.ApartmentState]::MTA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $pipeline = [PowerShell]::Create()
        $pipeline.Runspace = $runspace
        $script:GraphRunspace = $runspace
        $script:GraphPowerShell = $pipeline
    }
    catch {
        if ($null -ne $pipeline) { $pipeline.Dispose() }
        if ($null -ne $runspace) { $runspace.Dispose() }
        throw
    }
}

function Start-GraphOperation {
    param(
        [Parameter(Mandatory)][ValidateSet('Authenticate','Inventory','Credential','BitLockerKey','MicrosoftVerification')][string]$Name,
        [object[]]$Arguments = @()
    )

    if ($null -ne $script:CurrentOperation) {
        return $false
    }

    $inputCollection = [System.Management.Automation.PSDataCollection[psobject]]::new()
    $outputCollection = [System.Management.Automation.PSDataCollection[psobject]]::new()
    $inputCollection.Complete()
    $operation = [pscustomobject]@{
        Name = $Name
        AsyncResult = $null
        Input = $inputCollection
        Output = $outputCollection
        OutputIndex = 0
        CancellationRequested = $false
        StopAsyncResult = $null
    }
    try {
        Initialize-GraphWorker
        $script:GraphPowerShell.Commands.Clear()
        $script:GraphPowerShell.Streams.ClearStreams()
        $null = $script:GraphPowerShell.AddCommand((Join-Path $operationsPath "$Name.ps1"))
        foreach ($argument in $Arguments) { $null = $script:GraphPowerShell.AddArgument($argument) }
        $operation.AsyncResult = $script:GraphPowerShell.BeginInvoke[psobject, psobject]($inputCollection, $outputCollection)
    }
    catch {
        # Deliver startup failures through normal completion so controls recover.
        # Do not retain raw exceptions, which may carry request/session data.
        if ($null -ne $script:GraphPowerShell) { try { $script:GraphPowerShell.Dispose() } catch { } }
        if ($null -ne $script:GraphRunspace) { try { $script:GraphRunspace.Dispose() } catch { } }
        $script:GraphPowerShell = $null
        $script:GraphRunspace = $null
        $outputCollection.Add([pscustomobject]@{ Kind='Error'; ErrorCode='WorkerStartFailed'; Message='The local background worker could not start.'; StatusCode=$null })
    }
    $script:CurrentOperation = $operation
    return $true
}

function Stop-InventoryLoad {
    $operation = $script:CurrentOperation
    if ($null -eq $operation -or $operation.Name -ne 'Inventory' -or $operation.CancellationRequested) { return }
    try {
        if ($null -ne $operation.AsyncResult -and -not $operation.AsyncResult.IsCompleted) {
            # A null callback keeps all PowerShell/UI callbacks on the UI thread.
            $operation.StopAsyncResult = $script:GraphPowerShell.BeginStop($null, $null)
        }
        $operation.CancellationRequested = $true
        $RefreshButton.IsEnabled = $false
        $RefreshButtonText.Text = 'Canceling…'
        Set-AppStatus -Message 'Canceling refresh; waiting for the current request to stop…' -Busy
    }
    catch {
        Show-Toast -Message 'The refresh could not be canceled yet. Try again in a moment.' -Kind Error
    }
}

function Reset-InventoryControls {
    $LoadingOverlay.Visibility = 'Collapsed'
    $RefreshButtonText.Text = 'Refresh'
    $RefreshIcon.Text = [string][char]0xE72C
    $RefreshButton.ToolTip = 'Refresh devices (F5)'
    Restore-SecretActionControls
}

function Cancel-PendingRecoveryAction {
    $retrieving = $null -ne $script:CurrentOperation -and $script:CurrentOperation.Name -in @('Credential', 'BitLockerKey')
    if ($null -eq $script:PendingSecretRequest -and -not $retrieving) { return }
    $script:RecoveryRequestCanceled = $true
    $script:PendingCredentialVerificationGeneration = $null
    $script:PendingBitLockerVerificationGeneration = $null
    if ($null -ne $script:LocalVerificationCancellation) { $script:LocalVerificationCancellation.Cancel() }
    if ($null -ne $script:MicrosoftVerificationCancelEvent) { $null = $script:MicrosoftVerificationCancelEvent.Set() }
    if ($retrieving) {
        $operation = $script:CurrentOperation
        if (-not $operation.CancellationRequested -and $null -ne $operation.AsyncResult -and -not $operation.AsyncResult.IsCompleted) {
            try {
                # Keep the worker occupied until polling observes both completions.
                $operation.StopAsyncResult = $script:GraphPowerShell.BeginStop($null, $null)
                $operation.CancellationRequested = $true
            }
            catch {
                # Intent remains canceled even if the running request cannot stop.
                # Its eventual result will still be discarded by completion.
            }
        }
    }
}

function Update-OperationControls {
    if ($null -ne $script:PendingSecretRequest) {
        Set-SecretActionBusy -Kind ([string]$script:PendingSecretRequest.Kind)
    }
    elseif ($null -ne $script:CurrentOperation) {
        Set-SecretActionBusy -Kind LAPS
        if ($script:CurrentOperation.Name -eq 'Inventory') {
            $RefreshButton.IsEnabled = -not $script:CurrentOperation.CancellationRequested
        }
    }
}

function Restore-SecretActionControls {
    $selected = Get-SelectedDevice
    $lapsAvailable = $script:IsSignedIn -and $null -ne $selected -and [bool]$selected.LapsAvailable
    $bitLockerAvailable = $script:IsSignedIn -and $null -ne $selected -and [bool]$selected.BitLockerAvailable -and $null -ne $BitLockerKeySelector.SelectedItem
    $CopyDeviceDetailsButton.IsEnabled = $null -ne $selected
    $CopyAccountButton.IsEnabled = $null -ne $selected -and
        -not [string]::IsNullOrWhiteSpace($AccountNameText.Text) -and $AccountNameText.Text -ne 'Retrieved with password'
    $CopyPasswordButton.IsEnabled = $lapsAvailable
    $RevealPasswordButton.IsEnabled = $lapsAvailable
    $CopyPasswordButtonText.Text = 'Copy password'
    $CopyRecoveryKeyButton.IsEnabled = $bitLockerAvailable
    $RevealRecoveryKeyButton.IsEnabled = $bitLockerAvailable
    $CopyRecoveryKeyButtonText.Text = 'Copy recovery key'
    $BitLockerKeySelector.IsEnabled = $null -ne $selected -and [bool]$selected.BitLockerAvailable -and @($selected.BitLockerKeys).Count -gt 1
    $RefreshButton.IsEnabled = -not $DemoMode
    $SignInButton.IsEnabled = $true
}

function Set-RecoveryActionFocus {
    param(
        [Parameter(Mandatory)][ValidateSet('LAPS', 'BitLocker')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('Copy', 'Reveal')][string]$Action
    )

    $target = if ($Kind -eq 'LAPS') {
        if ($Action -eq 'Copy') { $CopyPasswordButton } else { $RevealPasswordButton }
    }
    else {
        if ($Action -eq 'Copy') { $CopyRecoveryKeyButton } else { $RevealRecoveryKeyButton }
    }
    if ($null -ne $target -and $target.IsEnabled -and $target.IsVisible) {
        $null = $target.Focus()
    }
    else {
        $null = $DeviceGrid.Focus()
    }
}

function Set-SecretActionBusy {
    param([Parameter(Mandatory)][ValidateSet('LAPS', 'BitLocker')][string]$Kind)

    $CopyDeviceDetailsButton.IsEnabled = $false
    $CopyAccountButton.IsEnabled = $false
    $CopyPasswordButton.IsEnabled = $false
    $RevealPasswordButton.IsEnabled = $false
    $CopyRecoveryKeyButton.IsEnabled = $false
    $RevealRecoveryKeyButton.IsEnabled = $false
    $BitLockerKeySelector.IsEnabled = $false
    $RefreshButton.IsEnabled = $false
    $SignInButton.IsEnabled = $false
}

# Only the WPF dispatcher owns these grants. Background operations return a
# result to the dispatcher, which checks the request generation before using it.
function Set-SecretVerificationGranted {
    param([Parameter(Mandatory)][int]$ExpectedGeneration)
    if ($script:SecretVerificationGeneration -ne $ExpectedGeneration) { return $false }
    $script:SecretVerifiedUntil = (Get-SensitiveClockNow).AddSeconds($secretVerificationSeconds)
    return $true
}

function Set-RecentInteractiveAuthentication {
    param([Parameter(Mandatory)][int]$ExpectedGeneration)
    if ($script:SecretVerificationGeneration -ne $ExpectedGeneration) { return $false }
    $script:RecentInteractiveAuthenticationUntil = (Get-SensitiveClockNow).AddSeconds($secretVerificationSeconds)
    return $true
}

function Use-RecentInteractiveAuthentication {
    param([Parameter(Mandatory)][int]$ExpectedGeneration)
    if ($script:SecretVerificationGeneration -ne $ExpectedGeneration -or
        (Get-SensitiveClockNow) -ge $script:RecentInteractiveAuthenticationUntil) { return $false }
    $script:SecretVerifiedUntil = $script:RecentInteractiveAuthenticationUntil
    return $true
}

function Test-SecretVerificationGeneration {
    param([AllowNull()][Nullable[int]]$Generation)
    return $null -ne $Generation -and $Generation -eq $script:SecretVerificationGeneration -and
        ($secretVerificationMode -eq 'Disabled' -or (Get-SensitiveClockNow) -lt $script:SecretVerifiedUntil)
}

function Clear-SecretVerificationState {
    $script:SecretVerifiedUntil = [DateTimeOffset]::MinValue
    $script:RecentInteractiveAuthenticationUntil = [DateTimeOffset]::MinValue
    $script:SecretVerificationGeneration++
    if ($null -ne $script:LocalVerificationCancellation) {
        try { $script:LocalVerificationCancellation.Cancel() } catch { }
    }
    if ($null -ne $script:MicrosoftVerificationCancelEvent) {
        try { $script:MicrosoftVerificationCancelEvent.Set() } catch { }
    }
}

function Clear-PendingSecretRequest {
    $script:PendingSecretRequest = $null
    if ($null -ne $script:LocalVerificationCancellation) {
        $script:LocalVerificationCancellation.Dispose()
        $script:LocalVerificationCancellation = $null
    }
    $script:LocalVerificationTask = $null
    if ($null -ne $script:MicrosoftVerificationCancelEvent) {
        $script:MicrosoftVerificationCancelEvent.Dispose()
        $script:MicrosoftVerificationCancelEvent = $null
    }
    Restore-SecretActionControls
}

function Stop-SecretVerification {
    Clear-SecretVerificationState
    $CancelVerificationButton.IsEnabled = $false
    Set-LiveStatusText -Control $AuthOverlayStatus -Message 'Canceling verification...'
}

function Fail-SecretVerification {
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$Canceled
    )

    $request = $script:PendingSecretRequest
    $AuthOverlay.Visibility = 'Collapsed'
    $CancelVerificationButton.Visibility = 'Collapsed'
    $CancelVerificationButton.IsEnabled = $true
    Clear-PendingSecretRequest
    Set-AppStatus -Message $Message
    Show-Toast -Message $Message -Kind $(if ($Canceled) { 'Info' } else { 'Error' })
    if ($null -ne $request) {
        Set-RecoveryActionFocus -Kind ([string]$request.Kind) -Action ([string]$request.Action)
    }
    else {
        $null = $DeviceGrid.Focus()
    }
}

function Resume-PendingSecretRequest {
    $request = $script:PendingSecretRequest
    if ($null -eq $request) {
        Restore-SecretActionControls
        return
    }

    $selected = Get-SelectedDevice
    $selectionMatches = $null -ne $selected -and
        [string]::Equals([string]$selected.EntraDeviceId, [string]$request.DeviceId, [StringComparison]::OrdinalIgnoreCase)
    if ($selectionMatches -and [string]$request.Kind -eq 'BitLocker') {
        $selectedKey = $BitLockerKeySelector.SelectedItem
        $selectionMatches = $null -ne $selectedKey -and
            [string]::Equals([string]$selectedKey.Id, [string]$request.RecoveryKeyId, [StringComparison]::OrdinalIgnoreCase)
    }

    $kind = [string]$request.Kind
    $action = [string]$request.Action
    $verificationGeneration = [int]$request.VerificationGeneration
    Clear-PendingSecretRequest
    if (-not $selectionMatches) {
        $selectionMessage = 'The selection changed, so no recovery data was retrieved.'
        Set-AppStatus -Message $selectionMessage
        Show-Toast -Message $selectionMessage -Kind Info
        $null = $DeviceGrid.Focus()
        return
    }

    if ($kind -eq 'LAPS') {
        Invoke-CredentialAction -Action $action -VerificationGranted -VerificationGeneration $verificationGeneration
    }
    else {
        Invoke-BitLockerAction -Action $action -VerificationGranted -VerificationGeneration $verificationGeneration
    }
}

function Start-MicrosoftSecretVerification {
    if ($null -eq $script:PendingSecretRequest -or $null -ne $script:CurrentOperation) {
        Fail-SecretVerification -Message 'Microsoft verification could not start. Try the recovery action again.'
        return
    }
    if ([int]$script:PendingSecretRequest.VerificationGeneration -ne $script:SecretVerificationGeneration) {
        Fail-SecretVerification -Message 'The Windows session changed, so verification was canceled.' -Canceled
        return
    }

    $script:MicrosoftVerificationCancelEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset)
    $nonce = [Guid]::NewGuid().ToString('N')
    $AuthOverlayTitle.Text = 'Verify with Microsoft'
    $AuthOverlaySubtitle.Text = 'Required before accessing recovery data'
    $AuthOverlayInstruction.Text = "Windows verification is not available. Complete Microsoft sign-in as the configured administrator account."
    $AuthOverlayFooter.Text = "Your organization's sign-in policy determines which verification methods are required."
    $AuthOverlay.Visibility = 'Visible'
    $DeviceCodeText.Text = 'Waiting for Microsoft...'
    Set-LiveStatusText -Control $AuthOverlayStatus -Message 'Preparing verification...'
    $CopyCodeButton.IsEnabled = $false
    $OpenSignInButton.IsEnabled = $false
    $CancelVerificationButton.Visibility = 'Visible'
    $CancelVerificationButton.IsEnabled = $true
    $script:LastDeviceCode = $null
    $script:SignInPageOpenedForCode = $null
    Set-AppStatus -Message 'Waiting for Microsoft verification...' -Busy
    $null = $CancelVerificationButton.Focus()

    $powerShellExecutable = Join-Path $PSHOME 'pwsh.exe'
    $started = Start-GraphOperation -Name 'MicrosoftVerification' -Arguments @(
        $settings.TenantId,
        $settings.TenantObjectId,
        $settings.ExpectedAccount,
        [string[]]$settings.RequiredScopes,
        $coreModulePath,
        $settings.GraphModuleMinimumVersion,
        $powerShellExecutable,
        $nonce,
        (Join-Path $operationsPath 'VerifyMicrosoftAccount.ps1'),
        $script:MicrosoftVerificationCancelEvent,
        300
    )
    if (-not $started) {
        Fail-SecretVerification -Message 'Microsoft verification could not start. Try the recovery action again.'
    }
}

function Start-LocalSecretVerification {
    if ($null -eq $script:PendingSecretRequest) {
        return
    }

    try {
        $null = $window.Activate()
        $script:LocalVerificationCancellation = [Threading.CancellationTokenSource]::new()
        $script:LocalVerificationTask = [M365Workbench.Security.WindowsHelloVerifier]::VerifyAsync(
            $windowHandle,
            'Verify to access recovery data in Intune Device Workbench.',
            [M365Workbench.Security.WindowsHelloVerifier]::DefaultTimeoutMilliseconds,
            $script:LocalVerificationCancellation.Token
        )
        Set-AppStatus -Message 'Waiting for Windows verification...' -Busy
    }
    catch {
        Complete-LocalSecretVerification -ForcedResult 'Error'
    }
}

function Complete-LocalSecretVerification {
    param([string]$ForcedResult)

    if ($null -eq $script:PendingSecretRequest) {
        Clear-PendingSecretRequest
        return
    }
    if ($script:RecoveryRequestCanceled) {
        Fail-SecretVerification -Message 'Recovery action canceled. No recovery data was accessed.' -Canceled
        return
    }
    $expectedGeneration = [int]$script:PendingSecretRequest.VerificationGeneration
    if ($expectedGeneration -ne $script:SecretVerificationGeneration) {
        Fail-SecretVerification -Message 'The Windows session changed, so verification was canceled.' -Canceled
        return
    }

    $localResult = $ForcedResult
    if ([string]::IsNullOrWhiteSpace($localResult)) {
        try {
            $outcome = $script:LocalVerificationTask.GetAwaiter().GetResult()
            $localResult = switch ([string]$outcome.State) {
                'PlatformUnavailable' { 'NotSupported' }
                default { [string]$outcome.State }
            }
        }
        catch {
            $localResult = 'Error'
        }
    }

    if ($null -ne $script:LocalVerificationCancellation) {
        $script:LocalVerificationCancellation.Dispose()
        $script:LocalVerificationCancellation = $null
    }
    $script:LocalVerificationTask = $null

    if ([string]::IsNullOrWhiteSpace($localResult)) { $localResult = 'Error' }
    $decision = Get-SecretVerificationDecision -Mode $secretVerificationMode -LocalResult $localResult

    switch ($decision) {
        'Grant' {
            if (Set-SecretVerificationGranted -ExpectedGeneration $expectedGeneration) {
                Resume-PendingSecretRequest
            }
            else {
                Fail-SecretVerification -Message 'The Windows session changed, so verification was canceled.' -Canceled
            }
        }
        'Microsoft' {
            if (Use-RecentInteractiveAuthentication -ExpectedGeneration $expectedGeneration) {
                Resume-PendingSecretRequest
            }
            else {
                Start-MicrosoftSecretVerification
            }
        }
        'Retry' {
            Fail-SecretVerification -Message 'Windows Security is busy. Wait a moment, then try again.'
        }
        'Blocked' {
            Fail-SecretVerification -Message 'Windows verification is required by this configuration but is not available for the current user.'
        }
        'Canceled' {
            Fail-SecretVerification -Message 'Verification canceled. No recovery data was accessed.' -Canceled
        }
        'TimedOut' {
            Fail-SecretVerification -Message 'Windows verification timed out. Try the recovery action again.'
        }
        default {
            Fail-SecretVerification -Message 'Windows could not verify this action. No recovery data was accessed.'
        }
    }
}

function Request-SecretAction {
    param(
        [Parameter(Mandatory)][ValidateSet('LAPS', 'BitLocker')][string]$Kind,
        [Parameter(Mandatory)][ValidateSet('Copy', 'Reveal')][string]$Action
    )

    if (-not $script:IsSignedIn -or $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask -or $null -ne $script:CurrentOperation) {
        return
    }

    $selected = Get-SelectedDevice
    if ($null -eq $selected) {
        return
    }
    $selectedKey = if ($Kind -eq 'BitLocker') { $BitLockerKeySelector.SelectedItem } else { $null }
    if ($Kind -eq 'BitLocker' -and $null -eq $selectedKey) {
        return
    }

    $script:RecoveryRequestCanceled = $false
    $script:PendingSecretRequest = [pscustomobject]@{
        Kind          = $Kind
        Action        = $Action
        DeviceId      = [string]$selected.EntraDeviceId
        RecoveryKeyId = if ($null -eq $selectedKey) { $null } else { [string]$selectedKey.Id }
        VerificationGeneration = $script:SecretVerificationGeneration
    }
    Set-SecretActionBusy -Kind $Kind

    $decision = Get-SecretVerificationDecision `
        -Mode $secretVerificationMode `
        -VerifiedUntil $script:SecretVerifiedUntil -Now (Get-SensitiveClockNow)
    if ($decision -in @('Grant', 'Bypass')) {
        Resume-PendingSecretRequest
        return
    }

    Start-LocalSecretVerification
}

function Start-Authentication {
    if ($DemoMode -or $null -ne $script:CurrentOperation -or $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask) {
        return
    }

    $script:AuthenticationVerificationGeneration = $script:SecretVerificationGeneration

    $AuthOverlayTitle.Text = 'Microsoft sign-in'
    $AuthOverlaySubtitle.Text = 'Connect to load devices'
    $AuthOverlayInstruction.Text = "Use the configured administrator account and follow your organization's sign-in requirements."
    $AuthOverlayFooter.Text = 'Intune Device Workbench continues automatically after sign-in.'
    $AuthOverlay.Visibility = 'Visible'
    $DeviceCodeText.Text = 'Waiting for Microsoft...'
    Set-LiveStatusText -Control $AuthOverlayStatus -Message 'Checking for a reusable secure sign-in...'
    $CopyCodeButton.IsEnabled = $false
    $OpenSignInButton.IsEnabled = $false
    $CancelVerificationButton.Visibility = 'Collapsed'
    $script:LastDeviceCode = $null
    $script:SignInPageOpenedForCode = $null
    $script:AuthenticationDeviceCodeObserved = $false
    $null = $AuthOverlay.Focus()
    Set-AppStatus -Message 'Connecting securely to Microsoft Graph...' -Busy
    Set-AuthenticationDisplay -SignedIn $false -Text 'Connecting...'

    $authenticationStarted = Start-GraphOperation -Name 'Authenticate' -Arguments @(
        $settings.TenantId,
        $settings.TenantObjectId,
        $settings.ExpectedAccount,
        [string[]]$settings.RequiredScopes,
        $coreModulePath,
        $settings.GraphModuleMinimumVersion
    )
    if (-not $authenticationStarted) {
        $script:AuthenticationVerificationGeneration = $null
    }
}

function Start-InventoryLoad {
    if ($DemoMode -or -not $script:IsSignedIn -or $null -ne $script:CurrentOperation -or $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask) {
        return
    }

    Set-InventoryLoadingState
    $null = Start-GraphOperation -Name 'Inventory' -Arguments @($coreModulePath)
}

function Set-InventoryLoadingState {
    Set-AppStatus -Message 'Loading devices and recovery status...' -Busy
    Set-SecretActionBusy -Kind LAPS
    $RefreshButtonText.Text = 'Cancel'
    $RefreshIcon.Text = [string][char]0xE711
    $RefreshButton.ToolTip = 'Cancel the current refresh; keep the previous inventory'
    $RefreshButton.IsEnabled = $true
    if ($script:AllDevices.Count -eq 0) {
        $LoadingText.Text = 'Loading managed devices...'
        $LoadingOverlay.Visibility = 'Visible'
    }
}

function Get-SelectedDevice {
    return $DeviceGrid.SelectedItem
}

function Set-RecoveryTab {
    param([Parameter(Mandatory)][ValidateSet('LAPS', 'BitLocker')][string]$Tab)

    if ($script:ActiveRecoveryTab -ne $Tab) {
        Cancel-PendingRecoveryAction
        Clear-SecretDisplay
    }
    $script:ActiveRecoveryTab = $Tab
    $isLaps = $Tab -eq 'LAPS'
    $LapsRecoveryPanel.Visibility = if ($isLaps) { 'Visible' } else { 'Collapsed' }
    $BitLockerRecoveryPanel.Visibility = if ($isLaps) { 'Collapsed' } else { 'Visible' }

    $brushConverter = [Windows.Media.BrushConverter]::new()
    $LapsTabButton.Background = $brushConverter.ConvertFromString($(if ($isLaps) { '#FFFFFF' } else { '#00FFFFFF' }))
    $BitLockerTabButton.Background = $brushConverter.ConvertFromString($(if ($isLaps) { '#00FFFFFF' } else { '#FFFFFF' }))
    $LapsTabButton.Foreground = $brushConverter.ConvertFromString($(if ($isLaps) { '#1D4ED8' } else { '#64748B' }))
    $BitLockerTabButton.Foreground = $brushConverter.ConvertFromString($(if ($isLaps) { '#64748B' } else { '#1D4ED8' }))
}

function Update-BitLockerSelection {
    $selected = Get-SelectedDevice
    $selectedKey = $BitLockerKeySelector.SelectedItem
    if ($null -eq $selected -or $null -eq $selectedKey) {
        $BitLockerVolumeText.Text = 'No recovery key backed up'
        $BitLockerKeyIdText.Text = ''
        $BitLockerKeyIdText.ToolTip = $null
        $BitLockerCreatedText.Text = [string][char]0x2014
        $CopyRecoveryKeyButton.IsEnabled = $false
        $RevealRecoveryKeyButton.IsEnabled = $false
        return
    }

    $BitLockerVolumeText.Text = [string]$selectedKey.VolumeDisplay
    $keyId = ([string]$selectedKey.Id).ToUpperInvariant()
    $BitLockerKeyIdText.Text = 'ID ' + $keyId.Substring(0, [Math]::Min(8, $keyId.Length))
    $BitLockerKeyIdText.ToolTip = 'Recovery key ID: ' + $keyId
    $BitLockerCreatedText.Text = [string]$selectedKey.CreatedDisplay
    $canRetrieve = [bool]$selected.BitLockerAvailable -and $script:IsSignedIn
    $CopyRecoveryKeyButton.IsEnabled = $canRetrieve
    $RevealRecoveryKeyButton.IsEnabled = $canRetrieve
    $null = Update-ClipboardStatusForSelection
    Update-OperationControls
}

function Update-DetailPanel {
    Clear-SecretDisplay
    $selected = Get-SelectedDevice
    if ($null -eq $selected) {
        $NoSelectionPanel.Visibility = 'Visible'
        $DetailPanel.Visibility = 'Collapsed'
        $CopyDeviceDetailsButton.IsEnabled = $false
        return
    }

    $NoSelectionPanel.Visibility = 'Collapsed'
    $DetailPanel.Visibility = 'Visible'
    $CopyDeviceDetailsButton.IsEnabled = $true
    $DetailDeviceName.Text = [string]$selected.DeviceName
    $DetailPrimaryUser.Text = [string]$selected.PrimaryUser
    $DetailUserPrincipalName.Text = [string]$selected.UserPrincipalName
    $DetailUserPrincipalName.Visibility = if ([string]::IsNullOrWhiteSpace([string]$selected.UserPrincipalName)) { 'Collapsed' } else { 'Visible' }
    $AccountNameText.Text = 'Retrieved with password'
    $DetailLapsStatus.Text = [string]$selected.LapsStatus
    $DetailBitLockerStatus.Text = [string]$selected.BitLockerStatus
    $DetailModel.Text = [string]$selected.Model
    $osDisplay = (([string]$selected.OperatingSystem + ' ' + [string]$selected.OSVersion).Trim())
    $DetailOperatingSystem.Text = if ([string]::IsNullOrWhiteSpace($osDisplay)) { [string][char]0x2014 } else { $osDisplay }
    $DetailLastSync.Text = [string]$selected.LastSyncDisplay
    $DetailEntraActivity.Text = [string]$selected.EntraLastSignInDisplay
    $DetailBackupDate.Text = [string]$selected.LastBackupDisplay
    $DetailRefreshDate.Text = [string]$selected.RefreshDateDisplay
    $DetailSerial.Text = [string]$selected.SerialNumber
    $DetailCompliance.Text = [string]$selected.ComplianceDisplay
    $DetailEncrypted.Text = [string]$selected.IsEncryptedDisplay
    $DetailOwnership.Text = [string]$selected.DeviceOwnerDisplay
    $DetailJoinType.Text = [string]$selected.TrustTypeDisplay
    $DetailSource.Text = [string]$selected.ManagementStateDisplay
    $EntraOnlyNotice.Visibility = if ([bool]$selected.IsEntraOnly) { 'Visible' } else { 'Collapsed' }
    $EntraOnlyNotice.ToolTip = [string]$selected.ManagementStateDescription
    $intunePortalUri = Get-DeviceAdminPortalUri -Portal Intune -Device $selected
    $entraPortalUri = Get-DeviceAdminPortalUri -Portal Entra -Device $selected
    $OpenIntuneButton.IsEnabled = $null -ne $intunePortalUri
    $OpenEntraButton.IsEnabled = $null -ne $entraPortalUri
    $OpenIntuneButton.ToolTip = if ($null -ne $intunePortalUri) { 'Open this device in the Microsoft Intune admin center' } else { 'No matching Intune managed-device record' }
    $OpenEntraButton.ToolTip = if ($null -ne $entraPortalUri) { 'Open this device in the Microsoft Entra admin center' } else { 'No matching Microsoft Entra device object' }

    $brushConverter = [Windows.Media.BrushConverter]::new()
    if ([bool]$selected.LapsAvailable) {
        $DetailLapsBadge.Background = $brushConverter.ConvertFromString('#ECFDF3')
        $DetailLapsDot.Fill = $brushConverter.ConvertFromString('#15803D')
        $DetailLapsStatus.Foreground = $brushConverter.ConvertFromString('#15803D')
    }
    else {
        $DetailLapsBadge.Background = $brushConverter.ConvertFromString('#F1F5F9')
        $DetailLapsDot.Fill = $brushConverter.ConvertFromString('#94A3B8')
        $DetailLapsStatus.Foreground = $brushConverter.ConvertFromString('#64748B')
    }

    if ([bool]$selected.BitLockerAvailable) {
        $DetailBitLockerBadge.Background = $brushConverter.ConvertFromString('#EFF6FF')
        $DetailBitLockerDot.Fill = $brushConverter.ConvertFromString('#2563EB')
        $DetailBitLockerStatus.Foreground = $brushConverter.ConvertFromString('#1D4ED8')
    }
    else {
        $DetailBitLockerBadge.Background = $brushConverter.ConvertFromString('#F1F5F9')
        $DetailBitLockerDot.Fill = $brushConverter.ConvertFromString('#94A3B8')
        $DetailBitLockerStatus.Foreground = $brushConverter.ConvertFromString('#64748B')
    }

    $DetailManagementBadge.ToolTip = [string]$selected.ManagementStateDescription
    if ([bool]$selected.IsEntraOnly) {
        $DetailManagementBadge.Background = $brushConverter.ConvertFromString('#FFF7ED')
        $DetailManagementBadge.BorderBrush = $brushConverter.ConvertFromString('#FED7AA')
        $DetailSourceDot.Fill = $brushConverter.ConvertFromString('#D97706')
        $DetailSource.Foreground = $brushConverter.ConvertFromString('#9A3412')
        $DetailLastSync.Foreground = $brushConverter.ConvertFromString('#B45309')
        $DetailLastSync.ToolTip = [string]$selected.ManagementStateDescription
    }
    else {
        $DetailManagementBadge.Background = $brushConverter.ConvertFromString('#EFF6FF')
        $DetailManagementBadge.BorderBrush = $brushConverter.ConvertFromString('#DBEAFE')
        $DetailSourceDot.Fill = $brushConverter.ConvertFromString('#2563EB')
        $DetailSource.Foreground = $brushConverter.ConvertFromString('#1D4ED8')
        $DetailLastSync.Foreground = $brushConverter.ConvertFromString('#172033')
        $DetailLastSync.ToolTip = $null
    }

    $compliance = Get-DeviceCompliancePresentation -Value $selected.ComplianceState
    $DetailCompliance.Text = $compliance.Text
    $DetailComplianceDot.Fill = $brushConverter.ConvertFromString($compliance.Foreground)
    $HeaderComplianceText.Text = $compliance.Text
    $HeaderComplianceText.Foreground = $brushConverter.ConvertFromString($compliance.Foreground)
    $HeaderComplianceBadge.Background = $brushConverter.ConvertFromString($compliance.Background)
    $HeaderComplianceText.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, "Compliance: $($compliance.Text)")

    $CopyPasswordButton.IsEnabled = [bool]$selected.LapsAvailable -and $script:IsSignedIn
    $RevealPasswordButton.IsEnabled = [bool]$selected.LapsAvailable -and $script:IsSignedIn
    $CopyAccountButton.IsEnabled = $false

    $script:SelectionChanging = $true
    try {
        $BitLockerKeySelector.ItemsSource = @($selected.BitLockerKeys)
        $BitLockerKeySelector.IsEnabled = @($selected.BitLockerKeys).Count -gt 1
        $BitLockerKeySelector.SelectedIndex = if (@($selected.BitLockerKeys).Count -gt 0) { 0 } else { -1 }
    }
    finally {
        $script:SelectionChanging = $false
    }
    Update-BitLockerSelection

    $targetTab = $script:ActiveRecoveryTab
    if ($targetTab -eq 'LAPS' -and -not [bool]$selected.LapsAvailable -and [bool]$selected.BitLockerAvailable) {
        $targetTab = 'BitLocker'
    }
    elseif ($targetTab -eq 'BitLocker' -and -not [bool]$selected.BitLockerAvailable -and [bool]$selected.LapsAvailable) {
        $targetTab = 'LAPS'
    }
    Set-RecoveryTab -Tab $targetTab
    $null = Update-ClipboardStatusForSelection
    Update-OperationControls
}

function Update-FilteredCount {
    if ($null -eq $script:DeviceView) {
        $DeviceCountText.Text = ''
        return
    }

    $visibleCount = $script:DeviceView.Count
    $lapsReadyCount = $script:InventoryCounts.Laps
    $bitLockerReadyCount = $script:InventoryCounts.BitLocker
    $entraOnlyCount = $script:InventoryCounts.EntraOnly
    $EntraOnlyFilterCount.Text = [string]$entraOnlyCount
    $EntraOnlyFilterContainer.Visibility = if ($entraOnlyCount -gt 0) { 'Visible' } else { 'Collapsed' }
    $countParts = [System.Collections.Generic.List[string]]::new()
    $countParts.Add("$visibleCount shown")
    if ($entraOnlyCount -gt 0) {
        $countParts.Add("$entraOnlyCount Entra only")
    }
    $countParts.Add("$lapsReadyCount LAPS")
    $countParts.Add("$bitLockerReadyCount BitLocker")
    $countParts.Add("$($script:AllDevices.Count) total")
    $DeviceCountText.Text = $countParts -join '  •  '
    if ($visibleCount -eq 0) {
        if ($script:AllDevices.Count -eq 0) {
            $EmptyStateTitle.Text = 'No Windows computers found'
            $EmptyStateDescription.Text = 'Refresh the inventory or check the current filters.'
        }
        else {
            $EmptyStateTitle.Text = 'No matching computers'
            $EmptyStateDescription.Text = 'Try another search or include devices without recovery material.'
        }
    }
    $EmptyState.Visibility = if ($visibleCount -eq 0) { 'Visible' } else { 'Collapsed' }
}

function Get-DeviceFilter {
    $query = $SearchBox.Text.Trim().ToLowerInvariant()
    $readyOnly = $OnlyReadyCheckBox.IsChecked -eq $true
    $entraOnly = $EntraOnlyCheckBox.IsChecked -eq $true
    if (-not $readyOnly -and -not $entraOnly -and $query.Length -eq 0) { return $null }
    return [Predicate[object]]{
        param($item)
        return $null -ne $item -and (-not $readyOnly -or $item.RecoveryAvailable) -and
            (-not $entraOnly -or $item.IsEntraOnly) -and
            ($query.Length -eq 0 -or ([string]$item.SearchText).Contains($query))
    }.GetNewClosure()
}

function Refresh-DeviceFilter {
    if ($null -eq $script:DeviceView) { return }
    $script:DeviceView.Filter = Get-DeviceFilter
    Update-FilteredCount
    if ($script:DeviceView.IsEmpty) {
        $DeviceGrid.SelectedItem = $null
        Update-DetailPanel
    }
    elseif ($null -eq $DeviceGrid.SelectedItem -or -not $script:DeviceView.Contains($DeviceGrid.SelectedItem)) {
        $DeviceGrid.SelectedItem = $script:DeviceView.GetItemAt(0)
        $DeviceGrid.ScrollIntoView($DeviceGrid.SelectedItem)
    }
}

function Get-InventorySelectionId {
    param([AllowNull()][object]$Device)
    if ($null -eq $Device) { return $null }
    foreach ($field in @('EntraDeviceId', 'IntuneDeviceId')) {
        $property = $Device.PSObject.Properties[$field]
        $id = [Guid]::Empty
        if ($null -ne $property -and [Guid]::TryParse([string]$property.Value, [ref]$id) -and $id -ne [Guid]::Empty) {
            return [pscustomobject]@{ Field=$field; Id=$id }
        }
    }
    return $null
}

function Set-DeviceInventory {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Devices)

    $previousId = Get-InventorySelectionId (Get-SelectedDevice)
    $previousKeyId = if ($null -ne $BitLockerKeySelector.SelectedItem) { $BitLockerKeySelector.SelectedItem.Id }
    $sorts = @(if ($null -ne $script:DeviceView) { $script:DeviceView.SortDescriptions })

    # Each successful refresh replaces the entire snapshot.
    $script:AllDevices = $Devices
    $script:InventoryCounts = @{ Laps=0; BitLocker=0; EntraOnly=0 }
    $previousRow = $null
    foreach ($device in $Devices) {
        if ($device.LapsAvailable) { $script:InventoryCounts.Laps++ }
        if ($device.BitLockerAvailable) { $script:InventoryCounts.BitLocker++ }
        if ($device.IsEntraOnly) { $script:InventoryCounts.EntraOnly++ }
        if ($null -ne $previousId -and $null -eq $previousRow) {
            $property = $device.PSObject.Properties[$previousId.Field]
            $id = [guid]::Empty
            if ($null -ne $property -and [guid]::TryParse([string]$property.Value, [ref]$id) -and $id -eq $previousId.Id) {
                $previousRow = $device
            }
        }
    }

    # Unchecking fires a synchronous event. Publish only the completed view.
    $script:DeviceView = $null
    if ($script:InventoryCounts.EntraOnly -eq 0 -and $EntraOnlyCheckBox.IsChecked -eq $true) {
        $EntraOnlyCheckBox.IsChecked = $false
    }
    $view = [Windows.Data.ListCollectionView]::new($Devices)
    $view.Filter = Get-DeviceFilter
    $restoreSelection = $null -ne $previousRow -and $view.Contains($previousRow)
    if ($restoreSelection) { $null = $view.MoveCurrentTo($previousRow) }
    $script:DeviceView = $view
    $DeviceGrid.ItemsSource = $view
    # DataGrid clears sort descriptions when it receives a new source.
    if ($sorts.Count) {
        $defer = $view.DeferRefresh()
        try { foreach ($sort in $sorts) { $view.SortDescriptions.Add($sort) } }
        finally { $defer.Dispose() }
    }
    $selection = if ($restoreSelection) { $previousRow } elseif (-not $view.IsEmpty) { $view.GetItemAt(0) }
    $DeviceGrid.SelectedItem = $selection
    foreach ($column in $DeviceGrid.Columns) {
        $sort = $sorts | Where-Object PropertyName -eq $column.SortMemberPath | Select-Object -First 1
        $column.SortDirection = if ($null -ne $sort) { $sort.Direction }
    }
    if ($restoreSelection -and $previousKeyId) {
        foreach ($key in $BitLockerKeySelector.Items) {
            if ($key.Id -eq $previousKeyId) { $BitLockerKeySelector.SelectedItem = $key; break }
        }
    }
    Update-FilteredCount
    if ($null -ne $selection) { $DeviceGrid.ScrollIntoView($selection) } else { Update-DetailPanel }
    $LoadingOverlay.Visibility = 'Collapsed'
    $RefreshButtonText.Text = 'Refresh'
}

function Complete-CredentialAction {
    param(
        [Parameter(Mandatory)][ValidateSet('Copy', 'Reveal')][string]$Action,
        [Parameter(Mandatory)][object]$Credential
    )

    $selected = Get-SelectedDevice
    if ($null -eq $selected -or -not [string]::Equals([string]$selected.EntraDeviceId, [string]$Credential.DeviceId, [StringComparison]::OrdinalIgnoreCase)) {
        $Credential.Password = $null
        Restore-SecretActionControls
        Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
        Show-Toast -Message 'The selection changed, so no password was exposed.' -Kind Info
        Set-RecoveryActionFocus -Kind LAPS -Action $Action
        return
    }

    $script:CurrentCredential = $Credential
    if ($script:RevealedSecretKind -ne 'LAPS') {
        $script:CredentialExpiresAt = (Get-SensitiveClockNow).AddSeconds($settings.RevealSeconds)
    }
    $AccountNameText.Text = [string]$Credential.AccountName
    $CopyAccountButton.IsEnabled = $true
    $CopyPasswordButtonText.Text = 'Copy password'

    if ($Action -eq 'Copy') {
        try {
            Set-ProtectedClipboardText -Text $Credential.Password -Kind LAPS -DeviceId $selected.EntraDeviceId
            $null = Update-ClipboardStatusForSelection
            Show-Toast -Message "Password copied for $($selected.DeviceName)." -Kind Success
        }
        catch {
            Show-Toast -Message 'The clipboard is busy. Nothing was copied; try again.' -Kind Error
        }
    }
    else {
        $script:RevealedSecretKind = 'LAPS'
        $PasswordText.Text = [string]$Credential.Password
        $RevealPasswordButton.Content = 'Hide now'
        Set-PasswordStatus -Message "Hides automatically in $($settings.RevealSeconds) seconds" -DotColor '#2563EB' -TextColor '#1D4ED8'
    }

    Restore-SecretActionControls
    Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
    Set-RecoveryActionFocus -Kind LAPS -Action $Action
}

function Invoke-CredentialAction {
    param(
        [Parameter(Mandatory)][ValidateSet('Copy', 'Reveal')][string]$Action,
        [switch]$VerificationGranted,
        [AllowNull()][Nullable[int]]$VerificationGeneration = $null
    )

    $selected = Get-SelectedDevice
    if ($null -eq $selected -or -not [bool]$selected.LapsAvailable) {
        return
    }

    if ($Action -eq 'Reveal' -and $script:RevealedSecretKind -eq 'LAPS') {
        Clear-SecretDisplay
        return
    }

    if ($DemoMode) {
        $demoCredential = [pscustomobject]@{
            Kind = 'CredentialResult'
            DeviceId = [string]$selected.EntraDeviceId
            AccountName = 'DemoLapsAdmin'
            Password = 'Demo-Only!Laps-2026'
        }
        Complete-CredentialAction -Action $Action -Credential $demoCredential
        return
    }

    if (-not $VerificationGranted) {
        Request-SecretAction -Kind LAPS -Action $Action
        return
    }

    if (-not (Test-SecretVerificationGeneration -Generation $VerificationGeneration)) {
        Restore-SecretActionControls
        Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
        Show-Toast -Message 'Verification expired or the Windows session changed. No password was accessed.' -Kind Info
        Set-RecoveryActionFocus -Kind LAPS -Action $Action
        return
    }

    if ($null -ne $script:CurrentCredential -and
        [string]::Equals([string]$script:CurrentCredential.DeviceId, [string]$selected.EntraDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
        (Get-SensitiveClockNow) -lt $script:CredentialExpiresAt) {
        Complete-CredentialAction -Action $Action -Credential $script:CurrentCredential
        return
    }

    if ($null -ne $script:CurrentOperation) {
        return
    }

    $script:PendingCredentialAction = $Action
    $script:PendingCredentialVerificationGeneration = [int]$VerificationGeneration
    Set-SecretActionBusy -Kind LAPS
    Set-AppStatus -Message "Retrieving the current password for $($selected.DeviceName)..." -Busy
    $null = Start-GraphOperation -Name 'Credential' -Arguments @([string]$selected.EntraDeviceId, $coreModulePath)
}

function Complete-BitLockerAction {
    param(
        [Parameter(Mandatory)][ValidateSet('Copy', 'Reveal')][string]$Action,
        [Parameter(Mandatory)][object]$KeyResult
    )

    $selected = Get-SelectedDevice
    $selectedKey = $BitLockerKeySelector.SelectedItem
    if ($null -eq $selected -or $null -eq $selectedKey -or
        -not [string]::Equals([string]$selected.EntraDeviceId, [string]$KeyResult.DeviceId, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$selectedKey.Id, [string]$KeyResult.RecoveryKeyId, [StringComparison]::OrdinalIgnoreCase)) {
        $KeyResult.RecoveryKey = $null
        Restore-SecretActionControls
        Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
        Show-Toast -Message 'The selection changed, so no recovery key was exposed.' -Kind Info
        Set-RecoveryActionFocus -Kind BitLocker -Action $Action
        return
    }

    $script:CurrentBitLockerKey = $KeyResult
    if ($script:RevealedSecretKind -ne 'BitLocker') {
        $script:BitLockerExpiresAt = (Get-SensitiveClockNow).AddSeconds($settings.RevealSeconds)
    }
    $CopyRecoveryKeyButtonText.Text = 'Copy recovery key'

    if ($Action -eq 'Copy') {
        try {
            Set-ProtectedClipboardText -Text $KeyResult.RecoveryKey -Kind BitLocker -DeviceId $selected.EntraDeviceId -RecoveryKeyId $selectedKey.Id
            $null = Update-ClipboardStatusForSelection
            Show-Toast -Message "BitLocker recovery key copied for $($selected.DeviceName)." -Kind Success
        }
        catch {
            Show-Toast -Message 'The clipboard is busy. Nothing was copied; try again.' -Kind Error
        }
    }
    else {
        $script:RevealedSecretKind = 'BitLocker'
        $BitLockerKeyText.Text = [string]$KeyResult.RecoveryKey
        $RevealRecoveryKeyButton.Content = 'Hide now'
        Set-BitLockerStatus -Message "Hides automatically in $($settings.RevealSeconds) seconds" -DotColor '#2563EB' -TextColor '#1D4ED8'
    }

    Restore-SecretActionControls
    Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
    Set-RecoveryActionFocus -Kind BitLocker -Action $Action
}

function Invoke-BitLockerAction {
    param(
        [Parameter(Mandatory)][ValidateSet('Copy', 'Reveal')][string]$Action,
        [switch]$VerificationGranted,
        [AllowNull()][Nullable[int]]$VerificationGeneration = $null
    )

    $selected = Get-SelectedDevice
    $selectedKey = $BitLockerKeySelector.SelectedItem
    if ($null -eq $selected -or $null -eq $selectedKey -or -not [bool]$selected.BitLockerAvailable) {
        return
    }

    if ($Action -eq 'Reveal' -and $script:RevealedSecretKind -eq 'BitLocker') {
        Clear-SecretDisplay
        Update-BitLockerSelection
        return
    }

    if ($DemoMode) {
        $demoKey = [pscustomobject]@{
            Kind = 'BitLockerKeyResult'
            DeviceId = [string]$selected.EntraDeviceId
            RecoveryKeyId = [string]$selectedKey.Id
            RecoveryKey = '111111-222222-333333-444444-555555-666666-777777-888888'
        }
        Complete-BitLockerAction -Action $Action -KeyResult $demoKey
        return
    }

    if (-not $VerificationGranted) {
        Request-SecretAction -Kind BitLocker -Action $Action
        return
    }

    if (-not (Test-SecretVerificationGeneration -Generation $VerificationGeneration)) {
        Restore-SecretActionControls
        Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
        Show-Toast -Message 'Verification expired or the Windows session changed. No recovery key was accessed.' -Kind Info
        Set-RecoveryActionFocus -Kind BitLocker -Action $Action
        return
    }

    if ($null -ne $script:CurrentBitLockerKey -and
        [string]::Equals([string]$script:CurrentBitLockerKey.DeviceId, [string]$selected.EntraDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$script:CurrentBitLockerKey.RecoveryKeyId, [string]$selectedKey.Id, [StringComparison]::OrdinalIgnoreCase) -and
        (Get-SensitiveClockNow) -lt $script:BitLockerExpiresAt) {
        Complete-BitLockerAction -Action $Action -KeyResult $script:CurrentBitLockerKey
        return
    }

    if ($null -ne $script:CurrentOperation) {
        return
    }

    $script:PendingBitLockerAction = $Action
    $script:PendingBitLockerVerificationGeneration = [int]$VerificationGeneration
    Set-SecretActionBusy -Kind BitLocker
    Set-AppStatus -Message "Retrieving a BitLocker recovery key for $($selected.DeviceName)..." -Busy
    $null = Start-GraphOperation -Name 'BitLockerKey' -Arguments @(
        [string]$selected.EntraDeviceId,
        [string]$selectedKey.Id,
        $coreModulePath
    )
}

function Get-OperationResultObject {
    param([Parameter(Mandatory)][object]$Operation)

    $result = $null
    foreach ($item in @($Operation.Output)) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['Kind']) {
            $result = $item
        }
    }
    return $result
}

function Complete-GraphOperation {
    param([Parameter(Mandatory)][object]$Operation)

    $workerError = $null
    try {
        if ($null -ne $Operation.StopAsyncResult) { $script:GraphPowerShell.EndStop($Operation.StopAsyncResult) }
        if ($null -ne $Operation.AsyncResult) { $null = $script:GraphPowerShell.EndInvoke($Operation.AsyncResult) }
    }
    catch {
        $workerError = $_
    }

    $operationName = [string]$Operation.Name
    $result = Get-OperationResultObject -Operation $Operation
    if ($null -eq $result) {
        if ($null -ne $script:GraphPowerShell -and $script:GraphPowerShell.Streams.Error.Count -gt 0) {
            $workerError = $script:GraphPowerShell.Streams.Error[0]
        }
        if ($Operation.CancellationRequested -and ($null -eq $workerError -or
            $workerError.Exception.GetBaseException() -is [Management.Automation.PipelineStoppedException])) {
            $result = [pscustomobject]@{ Kind = if ($operationName -eq 'Inventory') { 'InventoryCanceled' } else { 'RecoveryCanceled' } }
        }
        elseif ($null -ne $workerError) {
            $result = ConvertTo-GraphOperationError -ErrorRecord $workerError
        }
        else {
            $result = [pscustomobject]@{ Kind = 'Error'; ErrorCode = 'OperationFailed'; Message = 'The background operation did not return a result.'; StatusCode = $null }
        }
    }

    $expectedKind = switch ($operationName) {
        'Authenticate' { 'AuthResult' }
        'Inventory' { 'InventoryResult'; if ($Operation.CancellationRequested) { 'InventoryCanceled' } }
        'Credential' { 'CredentialResult'; if ($Operation.CancellationRequested) { 'RecoveryCanceled' } }
        'BitLockerKey' { 'BitLockerKeyResult'; if ($Operation.CancellationRequested) { 'RecoveryCanceled' } }
        'MicrosoftVerification' { 'MicrosoftVerificationResult'; 'VerificationError'; 'VerificationCanceled' }
    }
    if ([string]$result.Kind -ne 'Error' -and [string]$result.Kind -notin @($expectedKind)) {
        foreach ($field in @('Password','RecoveryKey')) {
            $property = $result.PSObject.Properties[$field]
            if ($null -ne $property) { $property.Value = $null }
        }
        $result = [pscustomobject]@{ Kind='Error'; ErrorCode='UnexpectedOperationResult'; Message='The background operation returned an unexpected result.'; StatusCode=$null }
    }
    if ($null -ne $script:GraphPowerShell) { $script:GraphPowerShell.Streams.ClearStreams() }
    $Operation.Output.Clear()
    $Operation.Input.Dispose()
    $Operation.Output.Dispose()
    $script:CurrentOperation = $null

    $failureCategory = $null
    if ($result.Kind -eq 'Error') {
        $failureCategory = Get-GraphFailureCategory -ErrorCode $result.ErrorCode -Message $result.Message -StatusCode $result.StatusCode
    }
    $connectionLost = $failureCategory -in @('Authentication','Connectivity','Timeout','Service')
    # Cancel discards a snapshot. A concurrent loss of connection still revokes recovery access.
    if ($operationName -eq 'Inventory' -and $Operation.CancellationRequested -and -not $connectionLost) {
        Reset-InventoryControls
        Update-FilteredCount
        if ($script:AllDevices.Count -eq 0) {
            $EmptyStateTitle.Text = 'Refresh canceled'
            $EmptyStateDescription.Text = 'Select Refresh to load computers.'
            $EmptyState.Visibility = 'Visible'
        }
        Set-AppStatus -Message $(if ($script:AllDevices.Count -gt 0) { 'Refresh canceled — showing the previous inventory.' } else { 'Refresh canceled. Select Refresh to try again.' })
        return
    }

    if ($operationName -eq 'MicrosoftVerification') {
        Clear-AuthenticationClipboard
        $AuthOverlay.Visibility = 'Collapsed'
        $CancelVerificationButton.Visibility = 'Collapsed'
        $CancelVerificationButton.IsEnabled = $true
        if ($script:RecoveryRequestCanceled) {
            Fail-SecretVerification -Message 'Recovery action canceled. No recovery data was accessed.' -Canceled
            return
        }
        switch ([string]$result.Kind) {
            'MicrosoftVerificationResult' {
                if ($null -eq $script:PendingSecretRequest) {
                    Fail-SecretVerification -Message 'The Windows session changed, so verification was canceled.' -Canceled
                }
                else {
                    $expectedGeneration = [int]$script:PendingSecretRequest.VerificationGeneration
                    if (Set-SecretVerificationGranted -ExpectedGeneration $expectedGeneration) {
                        Resume-PendingSecretRequest
                    }
                    else {
                        Fail-SecretVerification -Message 'The Windows session changed, so verification was canceled.' -Canceled
                    }
                }
            }
            'VerificationCanceled' {
                Fail-SecretVerification -Message 'Verification canceled. No recovery data was accessed.' -Canceled
            }
            default {
                $verificationErrorCode = if ($null -ne $result.PSObject.Properties['ErrorCode']) { [string]$result.ErrorCode } else { 'MicrosoftVerificationFailed' }
                $verificationMessage = switch ($verificationErrorCode) {
                    'WrongAccount' { "Microsoft verification must use $($settings.ExpectedAccount). No recovery data was accessed." }
                    'WrongTenant' { 'Microsoft verification used a different tenant. No recovery data was accessed.' }
                    'MissingScopes' { 'Microsoft verification did not include the configured recovery permissions. No recovery data was accessed.' }
                    'VerificationTimedOut' { 'Microsoft verification timed out. No recovery data was accessed.' }
                    'InteractiveVerificationNotObserved' { 'Microsoft did not present a fresh verification code. No recovery data was accessed; try again.' }
                    default { 'Microsoft verification could not be completed. No recovery data was accessed.' }
                }
                Fail-SecretVerification -Message $verificationMessage
            }
        }
        return
    }

    if ([string]$result.Kind -eq 'Error') {
        $failedRecoveryKind = $null
        $failedRecoveryAction = $null
        $statusCode = if ($null -eq $result.StatusCode) { $null } else { [Nullable[int]]([int]$result.StatusCode) }
        $friendly = Get-FriendlyLapsErrorMessage -ErrorCode ([string]$result.ErrorCode) -Message ([string]$result.Message) -StatusCode $statusCode -Operation $operationName
        $stageProperty = $result.PSObject.Properties['Stage']
        if ($operationName -eq 'Inventory' -and $null -ne $stageProperty -and -not [string]::IsNullOrWhiteSpace([string]$stageProperty.Value)) {
            $friendly = "$friendly Failed while loading $([string]$stageProperty.Value)."
        }
        if ($operationName -eq 'Authenticate') {
            $AuthOverlay.Visibility = 'Collapsed'
            $script:AuthenticationVerificationGeneration = $null
        }
        if ($operationName -eq 'Authenticate' -or $connectionLost) {
            Clear-AuthenticationClipboard
            Clear-SecretVerificationState
            Clear-SecretDisplay
            $connectionText = switch ($failureCategory) {
                'Authentication' { 'Sign-in required' }
                'Connectivity' { 'Connection unavailable' }
                'Timeout' { 'Connection timed out' }
                'Service' { 'Microsoft unavailable' }
                'Permission' { 'Access denied' }
                default { 'Connection not verified' }
            }
            Set-AuthenticationDisplay -SignedIn $false -Text $connectionText
            if ($failureCategory -ne 'Authentication') { $SignInButton.Content = 'Retry connection' }
            Restore-SecretActionControls
        }
        if ($operationName -eq 'Credential') {
            $failedRecoveryKind = 'LAPS'
            $failedRecoveryAction = $script:PendingCredentialAction
            $script:PendingCredentialAction = $null
            $script:PendingCredentialVerificationGeneration = $null
        }
        if ($operationName -eq 'BitLockerKey') {
            $failedRecoveryKind = 'BitLocker'
            $failedRecoveryAction = $script:PendingBitLockerAction
            $script:PendingBitLockerAction = $null
            $script:PendingBitLockerVerificationGeneration = $null
        }
        if ($operationName -in @('Credential', 'BitLockerKey')) {
            Restore-SecretActionControls
            if ($failedRecoveryAction -in @('Copy', 'Reveal')) {
                Set-RecoveryActionFocus -Kind $failedRecoveryKind -Action ([string]$failedRecoveryAction)
            }
            else {
                $null = $DeviceGrid.Focus()
            }
        }
        if ($operationName -eq 'Inventory') {
            Reset-InventoryControls
            if ($script:AllDevices.Count -eq 0) {
                $EmptyStateTitle.Text = 'Unable to load computers'
                $EmptyStateDescription.Text = 'Check the status below, then try Refresh again.'
                $EmptyState.Visibility = 'Visible'
            }
            else {
                $friendly += ' Showing the previous inventory.'
            }
        }
        $RefreshButton.IsEnabled = $true
        Set-AppStatus -Message $friendly
        Show-Toast -Message $friendly -Kind Error
        return
    }

    switch ($operationName) {
        'Authenticate' {
            Clear-AuthenticationClipboard
            $AuthOverlay.Visibility = 'Collapsed'
            if ($null -eq $result.PSObject.Properties['ConnectionVerified'] -or
                $result.ConnectionVerified -isnot [bool] -or -not $result.ConnectionVerified) {
                $script:AuthenticationVerificationGeneration = $null
                Clear-SecretVerificationState
                Clear-SecretDisplay
                Set-AuthenticationDisplay -SignedIn $false -Text 'Connection not verified'
                $SignInButton.Content = 'Retry connection'
                Restore-SecretActionControls
                Set-AppStatus -Message 'The Microsoft connection was not verified. Select Refresh to retry.'
                return
            }
            Set-AuthenticationDisplay -SignedIn $true -Text ([string]$result.Account)
            if ($script:AuthenticationDeviceCodeObserved -and $null -ne $script:AuthenticationVerificationGeneration) {
                $null = Set-RecentInteractiveAuthentication -ExpectedGeneration ([int]$script:AuthenticationVerificationGeneration)
            }
            $script:AuthenticationVerificationGeneration = $null
            Set-AppStatus -Message 'Signed in. Loading computers...' -Busy
            Start-InventoryLoad
        }
        'Inventory' {
            Set-DeviceInventory -Devices @($result.Devices)
            Reset-InventoryControls
            Set-AppStatus -Message "Ready — updated $(([DateTimeOffset]$result.LoadedAt).ToLocalTime().ToString('h:mm tt'))"
        }
        'Credential' {
            $action = $script:PendingCredentialAction
            $verificationGeneration = $script:PendingCredentialVerificationGeneration
            $script:PendingCredentialAction = $null
            $script:PendingCredentialVerificationGeneration = $null
            if (-not $Operation.CancellationRequested -and -not $script:RecoveryRequestCanceled -and (Test-SecretVerificationGeneration -Generation $verificationGeneration)) {
                Complete-CredentialAction -Action $action -Credential $result
            }
            else {
                if ($null -ne $result.PSObject.Properties['Password']) {
                    $result.Password = $null
                }
                Restore-SecretActionControls
                Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
                Show-Toast -Message $(if ($Operation.CancellationRequested -or $script:RecoveryRequestCanceled) { 'Recovery action canceled. No password was exposed.' } else { 'Verification expired or the Windows session changed. No password was exposed.' }) -Kind Info
                Set-RecoveryActionFocus -Kind LAPS -Action $action
            }
        }
        'BitLockerKey' {
            $action = $script:PendingBitLockerAction
            $verificationGeneration = $script:PendingBitLockerVerificationGeneration
            $script:PendingBitLockerAction = $null
            $script:PendingBitLockerVerificationGeneration = $null
            if (-not $Operation.CancellationRequested -and -not $script:RecoveryRequestCanceled -and (Test-SecretVerificationGeneration -Generation $verificationGeneration)) {
                Complete-BitLockerAction -Action $action -KeyResult $result
            }
            else {
                if ($null -ne $result.PSObject.Properties['RecoveryKey']) {
                    $result.RecoveryKey = $null
                }
                Restore-SecretActionControls
                Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
                Show-Toast -Message $(if ($Operation.CancellationRequested -or $script:RecoveryRequestCanceled) { 'Recovery action canceled. No recovery key was exposed.' } else { 'Verification expired or the Windows session changed. No recovery key was exposed.' }) -Kind Info
                Set-RecoveryActionFocus -Kind BitLocker -Action $action
            }
        }
    }
}

function Process-OperationOutput {
    if ($null -eq $script:CurrentOperation) {
        return
    }

    $operation = $script:CurrentOperation
    while ($operation.OutputIndex -lt $operation.Output.Count) {
        $item = $operation.Output[$operation.OutputIndex]
        $operation.OutputIndex++
        if ($operation.Name -in @('Authenticate', 'MicrosoftVerification')) {
            $deviceCode = Get-DeviceCodeFromMessage -Message $item
            if ($null -ne $deviceCode) {
                if ($operation.Name -eq 'Authenticate') {
                    $script:AuthenticationDeviceCodeObserved = $true
                }
                Set-DeviceCode -Code $deviceCode.UserCode
            }
        }
    }

    if (($null -eq $operation.AsyncResult -or $operation.AsyncResult.IsCompleted) -and
        ($null -eq $operation.StopAsyncResult -or $operation.StopAsyncResult.IsCompleted)) {
        Complete-GraphOperation -Operation $operation
    }
}

function Get-DemoInventory {
    $now = [DateTimeOffset]::Now
    $managed = @(
        [pscustomobject]@{ id='c1111111-1111-4111-8111-111111111111'; deviceName='DEMO-DEVICE-ALPHA'; azureADDeviceId='11111111-1111-1111-1111-111111111111'; userDisplayName='Ashley Morgan'; userPrincipalName='ashley.morgan@contoso.com'; serialNumber='DEMO-SERIAL-ALPHA'; operatingSystem='Windows'; osVersion='10.0.26100'; model='ZBook Power G11'; manufacturer='HP'; lastSyncDateTime=$now.AddMinutes(-14); complianceState='compliant'; managedDeviceOwnerType='company'; deviceEnrollmentType='windowsAzureADJoin'; isEncrypted=$true; managementAgent='mdm'; enrolledDateTime=$now.AddMonths(-9) },
        [pscustomobject]@{ id='c2222222-2222-4222-8222-222222222222'; deviceName='DEMO-DEVICE-BRAVO'; azureADDeviceId='22222222-2222-2222-2222-222222222222'; userDisplayName='Jason Reed'; userPrincipalName='jason.reed@contoso.com'; serialNumber='DEMO-SERIAL-BRAVO'; operatingSystem='Windows'; osVersion='10.0.26100'; model='ThinkPad P16s'; manufacturer='Lenovo'; lastSyncDateTime=$now.AddHours(-2); complianceState='compliant'; managedDeviceOwnerType='company'; deviceEnrollmentType='windowsAzureADJoin'; isEncrypted=$true; managementAgent='mdm'; enrolledDateTime=$now.AddMonths(-6) },
        [pscustomobject]@{ id='c3333333-3333-4333-8333-333333333333'; deviceName='DEMO-DEVICE-CHARLIE'; azureADDeviceId='33333333-3333-3333-3333-333333333333'; userDisplayName='Brandon Cole'; userPrincipalName='brandon.cole@contoso.com'; serialNumber='DEMO-SERIAL-CHARLIE'; operatingSystem='Windows'; osVersion='10.0.26100'; model='Z2 Tower G9'; manufacturer='HP'; lastSyncDateTime=$now.AddDays(-1); complianceState='noncompliant'; managedDeviceOwnerType='company'; deviceEnrollmentType='windowsAzureADJoin'; isEncrypted=$false; managementAgent='mdm'; enrolledDateTime=$now.AddMonths(-14) },
        [pscustomobject]@{ id='c4444444-4444-4444-8444-444444444444'; deviceName='DEMO-DEVICE-DELTA'; azureADDeviceId='44444444-4444-4444-4444-444444444444'; userDisplayName=''; userPrincipalName=''; serialNumber='DEMO-SERIAL-DELTA'; operatingSystem='Windows'; osVersion='10.0.26100'; model='EliteBook 860 G11'; manufacturer='HP'; lastSyncDateTime=$now.AddDays(-4); complianceState='compliant'; managedDeviceOwnerType='company'; deviceEnrollmentType='windowsAutoEnrollment'; isEncrypted=$true; managementAgent='mdm'; enrolledDateTime=$now.AddMonths(-2) },
        [pscustomobject]@{ id='c5555555-5555-4555-8555-555555555555'; deviceName='DEMO-DEVICE-ECHO'; azureADDeviceId='55555555-5555-5555-5555-555555555555'; userDisplayName='Former User'; userPrincipalName='former.user@contoso.com'; serialNumber='DEMO-SERIAL-ECHO'; operatingSystem='Windows'; osVersion='10.0.22631'; model='Precision 3660'; manufacturer='Dell'; lastSyncDateTime=$now.AddDays(-74); complianceState='unknown'; managedDeviceOwnerType='company'; deviceEnrollmentType='windowsAzureADJoin'; isEncrypted=$true; managementAgent='mdm'; enrolledDateTime=$now.AddYears(-3) }
    )
    $laps = @(
        [pscustomobject]@{ id='11111111-1111-1111-1111-111111111111'; deviceName='DEMO-DEVICE-ALPHA'; lastBackupDateTime=$now.AddDays(-5); refreshDateTime=$now.AddDays(25) },
        [pscustomobject]@{ id='22222222-2222-2222-2222-222222222222'; deviceName='DEMO-DEVICE-BRAVO'; lastBackupDateTime=$now.AddDays(-12); refreshDateTime=$now.AddDays(18) },
        [pscustomobject]@{ id='33333333-3333-3333-3333-333333333333'; deviceName='DEMO-DEVICE-CHARLIE'; lastBackupDateTime=$now.AddDays(-2); refreshDateTime=$now.AddDays(28) },
        [pscustomobject]@{ id='44444444-4444-4444-4444-444444444444'; deviceName='DEMO-DEVICE-DELTA'; lastBackupDateTime=$now.AddDays(-20); refreshDateTime=$now.AddDays(10) }
    )
    $bitLocker = @(
        [pscustomobject]@{ id='a1111111-1111-4111-8111-111111111111'; deviceId='11111111-1111-1111-1111-111111111111'; createdDateTime=$now.AddMonths(-9); volumeType='operatingSystemVolume' },
        [pscustomobject]@{ id='a1111111-1111-4111-8111-111111111112'; deviceId='11111111-1111-1111-1111-111111111111'; createdDateTime=$now.AddMonths(-8); volumeType='fixedDataVolume' },
        [pscustomobject]@{ id='a2222222-2222-4222-8222-222222222222'; deviceId='22222222-2222-2222-2222-222222222222'; createdDateTime=$now.AddMonths(-6); volumeType='operatingSystemVolume' },
        [pscustomobject]@{ id='a4444444-4444-4444-8444-444444444444'; deviceId='44444444-4444-4444-4444-444444444444'; createdDateTime=$now.AddMonths(-2); volumeType='operatingSystemVolume' },
        [pscustomobject]@{ id='a5555555-5555-4555-8555-555555555555'; deviceId='55555555-5555-5555-5555-555555555555'; createdDateTime=$now.AddYears(-3); volumeType='operatingSystemVolume' }
    )
    $entra = @(
        [pscustomobject]@{ id='b1111111-1111-4111-8111-111111111111'; deviceId='11111111-1111-1111-1111-111111111111'; displayName='DEMO-DEVICE-ALPHA'; operatingSystem='Windows'; operatingSystemVersion='10.0.26100'; trustType='AzureAd'; approximateLastSignInDateTime=$now.AddMinutes(-12); accountEnabled=$true; manufacturer='HP'; model='ZBook Power G11' },
        [pscustomobject]@{ id='b2222222-2222-4222-8222-222222222222'; deviceId='22222222-2222-2222-2222-222222222222'; displayName='DEMO-DEVICE-BRAVO'; operatingSystem='Windows'; operatingSystemVersion='10.0.26100'; trustType='AzureAd'; approximateLastSignInDateTime=$now.AddHours(-2); accountEnabled=$true; manufacturer='Lenovo'; model='ThinkPad P16s' },
        [pscustomobject]@{ id='b3333333-3333-4333-8333-333333333333'; deviceId='33333333-3333-3333-3333-333333333333'; displayName='DEMO-DEVICE-CHARLIE'; operatingSystem='Windows'; operatingSystemVersion='10.0.26100'; trustType='ServerAd'; approximateLastSignInDateTime=$now.AddDays(-1); accountEnabled=$true; manufacturer='HP'; model='Z2 Tower G9' },
        [pscustomobject]@{ id='b4444444-4444-4444-8444-444444444444'; deviceId='44444444-4444-4444-4444-444444444444'; displayName='DEMO-DEVICE-DELTA'; operatingSystem='Windows'; operatingSystemVersion='10.0.26100'; trustType='AzureAd'; approximateLastSignInDateTime=$now.AddDays(-4); accountEnabled=$true; manufacturer='HP'; model='EliteBook 860 G11' },
        [pscustomobject]@{ id='b5555555-5555-4555-8555-555555555555'; deviceId='55555555-5555-5555-5555-555555555555'; displayName='DEMO-DEVICE-ECHO'; operatingSystem='Windows'; operatingSystemVersion='10.0.22631'; trustType='AzureAd'; approximateLastSignInDateTime=$now.AddDays(-74); accountEnabled=$false; manufacturer='Dell'; model='Precision 3660' },
        [pscustomobject]@{ id='b6666666-6666-4666-8666-666666666666'; deviceId='66666666-6666-6666-6666-666666666666'; displayName='DEMO-DEVICE-FOXTROT'; operatingSystem='Windows'; operatingSystemVersion='10.0.19045'; trustType='AzureAd'; approximateLastSignInDateTime=$now.AddDays(-143); accountEnabled=$false; manufacturer='HP'; model='ProDesk 600 G5' }
    )
    $primaryUsers = @{
        'c1111111-1111-4111-8111-111111111111' = @([pscustomobject]@{displayName='Ashley Morgan';userPrincipalName='ashley.morgan@contoso.com'})
        'c2222222-2222-4222-8222-222222222222' = @([pscustomobject]@{displayName='Jason Reed';userPrincipalName='jason.reed@contoso.com'})
        'c3333333-3333-4333-8333-333333333333' = @([pscustomobject]@{displayName='Brandon Cole';userPrincipalName='brandon.cole@contoso.com'})
        'c4444444-4444-4444-8444-444444444444' = @()
        'c5555555-5555-4555-8555-555555555555' = @()
    }
    return @(Merge-IntuneLapsDeviceData -ManagedDevices $managed -LapsMetadata $laps -BitLockerMetadata $bitLocker -EntraDevices $entra -PrimaryUsersByManagedDeviceId $primaryUsers)
}

function Save-WindowPreview {
    param([Parameter(Mandatory)][string]$Path)

    $window.UpdateLayout()
    # Render the actual client visual, without the unpainted native window frame.
    $visual = $window.Content
    $width = [Math]::Max(1, [int][Math]::Ceiling($visual.ActualWidth))
    $height = [Math]::Max(1, [int][Math]::Ceiling($visual.ActualHeight))
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    # The client grid is transparent over the window background in the real UI.
    $drawing = [System.Windows.Media.DrawingVisual]::new()
    $context = $drawing.RenderOpen()
    try {
        $bounds = [System.Windows.Rect]::new(0, 0, $width, $height)
        $context.DrawRectangle($window.Background, $null, $bounds)
    }
    finally { $context.Close() }
    $bitmap.Render($drawing)
    # Render in client coordinates. A VisualBrush auto-fits descendant bounds,
    # including invisible overflow, which can squeeze the UI and leave a gutter.
    $bitmap.Render($visual)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}

$searchDebounceTimer = [System.Windows.Threading.DispatcherTimer]::new()
$searchDebounceTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$searchDebounceTimer.Add_Tick({ $searchDebounceTimer.Stop(); Refresh-DeviceFilter })
$SearchBox.Add_TextChanged({
    $SearchHint.Visibility = if ([string]::IsNullOrEmpty($SearchBox.Text) -and -not $SearchBox.IsKeyboardFocusWithin) { 'Visible' } else { 'Collapsed' }
    $ClearSearchButton.Visibility = if ([string]::IsNullOrEmpty($SearchBox.Text)) { 'Collapsed' } else { 'Visible' }
    $searchDebounceTimer.Stop()
    $searchDebounceTimer.Start()
})
$SearchBox.Add_GotKeyboardFocus({ $SearchHint.Visibility = 'Collapsed' })
$SearchBox.Add_LostKeyboardFocus({
    if ([string]::IsNullOrEmpty($SearchBox.Text)) {
        $SearchHint.Visibility = 'Visible'
    }
})
$ClearSearchButton.Add_Click({ $SearchBox.Clear(); $SearchBox.Focus() })
$OnlyReadyCheckBox.Add_Checked({ Refresh-DeviceFilter })
$OnlyReadyCheckBox.Add_Unchecked({ Refresh-DeviceFilter })
$EntraOnlyCheckBox.Add_Checked({ Refresh-DeviceFilter })
$EntraOnlyCheckBox.Add_Unchecked({ Refresh-DeviceFilter })
$DeviceTableSurface.Add_SizeChanged({
    param($sender, $eventArgs)

    if ($sender.ActualWidth -le 0 -or $sender.ActualHeight -le 0) {
        return
    }

    # Border.CornerRadius rounds its paint but does not clip child controls in WPF.
    # Apply the same radius as a geometry so the DataGrid cannot bleed into the corners.
    $bounds = [System.Windows.Rect]::new(0, 0, $sender.ActualWidth, $sender.ActualHeight)
    $sender.Clip = [System.Windows.Media.RectangleGeometry]::new($bounds, 10, 10)
})
$DeviceGrid.Add_PreviewMouseWheel({
    param($sender, $eventArgs)

    if ($eventArgs.Delta -eq 0) {
        return
    }

    # Templates can be rebuilt during a long-running session. Never retain a
    # visual child: an old viewer still accepts commands but no longer moves rows.
    $viewer = Find-DeviceScrollViewer -Parent $DeviceGrid
    if ($null -eq $viewer -or $viewer.ScrollableHeight -le 0) {
        return
    }

    # WPF can interpret one wheel detent as several complete DataGrid rows.
    # Scale the raw wheel delta to three quarters of a row for precise, smooth movement.
    $pixelsPerDetent = [double]$DeviceGrid.RowHeight * 0.75
    $scrollDelta = ([double]$eventArgs.Delta / 120.0) * $pixelsPerDetent
    $maximumOffset = $viewer.ScrollableHeight
    $targetOffset = [Math]::Max(0.0, [Math]::Min($maximumOffset, $viewer.VerticalOffset - $scrollDelta))
    $viewer.ScrollToVerticalOffset($targetOffset)
    $eventArgs.Handled = $true
})
$DeviceGrid.Add_SelectionChanged({ Cancel-PendingRecoveryAction; Update-DetailPanel })
$CopyDeviceDetailsButton.Add_Click({ Copy-SelectedDeviceDetails })
$OpenIntuneButton.Add_Click({ Open-SelectedDevicePortal -Portal Intune })
$OpenEntraButton.Add_Click({ Open-SelectedDevicePortal -Portal Entra })
$LapsTabButton.Add_Click({ Set-RecoveryTab -Tab 'LAPS' })
$BitLockerTabButton.Add_Click({ Set-RecoveryTab -Tab 'BitLocker' })
$BitLockerKeySelector.Add_SelectionChanged({
    if (-not $script:SelectionChanging) {
        Cancel-PendingRecoveryAction
        Clear-SecretDisplay
        Update-BitLockerSelection
    }
})
$CopyPasswordButton.Add_Click({ Invoke-CredentialAction -Action 'Copy' })
$RevealPasswordButton.Add_Click({ Invoke-CredentialAction -Action 'Reveal' })
$CopyRecoveryKeyButton.Add_Click({ Invoke-BitLockerAction -Action 'Copy' })
$RevealRecoveryKeyButton.Add_Click({ Invoke-BitLockerAction -Action 'Reveal' })
$CopyAccountButton.Add_Click({
    # Do not let a late recovery Copy overwrite a newer username copy.
    if ($null -eq (Get-SelectedDevice) -or $null -ne $script:CurrentOperation -or
        $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask) { return }
    if (-not [string]::IsNullOrWhiteSpace($AccountNameText.Text) -and $AccountNameText.Text -ne 'Retrieved with password') {
        try {
            Set-ProtectedClipboardText -Text $AccountNameText.Text -Kind Account -ClearSeconds 20
            if ($script:RevealedSecretKind -ne 'LAPS') {
                Set-PasswordStatus -Message 'Password remains hidden until requested'
            }
            Show-Toast -Message 'Local administrator username copied.' -Kind Success
        }
        catch { Show-Toast -Message 'The clipboard is busy. Try again.' -Kind Error }
    }
})
$RefreshButton.Add_Click({
    if ($null -ne $script:CurrentOperation -and $script:CurrentOperation.Name -eq 'Inventory') { Stop-InventoryLoad }
    elseif ($script:IsSignedIn) { Start-InventoryLoad } else { Start-Authentication }
})
$SignInButton.Add_Click({ Start-Authentication })
$CopyCodeButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:LastDeviceCode)) {
        try {
            Set-ProtectedClipboardText -Text $script:LastDeviceCode -Kind DeviceCode
            Set-LiveStatusText -Control $AuthOverlayStatus -Message 'Code copied. Complete sign-in in the browser.'
        }
        catch { Set-LiveStatusText -Control $AuthOverlayStatus -Message 'Copy the code manually, then continue in the browser.' }
    }
})
$OpenSignInButton.Add_Click({ Open-DeviceSignInPage })
$CancelVerificationButton.Add_Click({ Stop-SecretVerification })
$window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    $modifiers = $eventArgs.KeyboardDevice.Modifiers
    if ($AuthOverlay.Visibility -eq 'Visible') {
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape -and $CancelVerificationButton.Visibility -eq 'Visible') {
            Stop-SecretVerification
            $eventArgs.Handled = $true
        }
        elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::F5 -or
            ($modifiers -eq [System.Windows.Input.ModifierKeys]::Control -and $eventArgs.Key -eq [System.Windows.Input.Key]::F) -or
            ($modifiers -eq ([System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Shift) -and $eventArgs.Key -eq [System.Windows.Input.Key]::C)) {
            $eventArgs.Handled = $true
        }
        return
    }
    if ($modifiers -eq [System.Windows.Input.ModifierKeys]::Control -and $eventArgs.Key -eq [System.Windows.Input.Key]::F) {
        $SearchBox.Focus()
        $SearchBox.SelectAll()
        $eventArgs.Handled = $true
    }
    elseif ($modifiers -eq ([System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Shift) -and
        $eventArgs.Key -eq [System.Windows.Input.Key]::C) {
        if ($script:ActiveRecoveryTab -eq 'BitLocker' -and $CopyRecoveryKeyButton.IsEnabled) {
            Invoke-BitLockerAction -Action 'Copy'
            $eventArgs.Handled = $true
        }
        elseif ($script:ActiveRecoveryTab -eq 'LAPS' -and $CopyPasswordButton.IsEnabled) {
            Invoke-CredentialAction -Action 'Copy'
            $eventArgs.Handled = $true
        }
    }
    elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::F5 -and $null -eq $script:CurrentOperation) {
        if ($script:IsSignedIn) { Start-InventoryLoad } else { Start-Authentication }
        $eventArgs.Handled = $true
    }
    elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
        Cancel-PendingRecoveryAction
        if ($null -ne $script:RevealedSecretKind) {
            $selected = Get-SelectedDevice
            $preserveLapsStatus = $script:ClipboardKind -eq 'LAPS' -and $null -ne $selected -and
                [string]::Equals([string]$selected.EntraDeviceId, [string]$script:ClipboardDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
                $script:ClipboardClearAt -gt (Get-SensitiveClockNow)
            $preserveBitLockerStatus = $script:ClipboardKind -eq 'BitLocker' -and $null -ne $selected -and
                [string]::Equals([string]$selected.EntraDeviceId, [string]$script:ClipboardDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
                $script:ClipboardClearAt -gt (Get-SensitiveClockNow)
            Clear-SecretDisplay -PreservePasswordStatus:$preserveLapsStatus -PreserveBitLockerStatus:$preserveBitLockerStatus
            if ($preserveLapsStatus -or $preserveBitLockerStatus) { $null = Update-ClipboardStatusForSelection }
        }
        $eventArgs.Handled = $true
    }
})

$pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(125)
$pollTimer.Add_Tick({
    Process-OperationOutput
    if ($null -ne $script:LocalVerificationTask -and $script:LocalVerificationTask.IsCompleted) {
        Complete-LocalSecretVerification
    }
    $now = Get-SensitiveClockNow

    if ($script:ToastExpiresAt -ne [DateTimeOffset]::MinValue -and $now -ge $script:ToastExpiresAt) {
        $ToastBorder.Visibility = 'Collapsed'
        $script:ToastExpiresAt = [DateTimeOffset]::MinValue
    }
    if ($script:ClipboardClearAt -ne [DateTimeOffset]::MinValue -and $now -lt $script:ClipboardClearAt) {
        $null = Update-ClipboardStatusForSelection
    }
    elseif ($script:ClipboardClearAt -ne [DateTimeOffset]::MinValue -and $now -ge $script:ClipboardClearAt) {
        $clipboardDeviceId = [string]$script:ClipboardDeviceId
        $clipboardKind = [string]$script:ClipboardKind
        $clipboardRecoveryKeyId = [string]$script:ClipboardRecoveryKeyId
        $clipboardCleared = $false
        $clipboardCleanupComplete = $false
        try {
            $clipboardCleared = [M365Workbench.Security.SecureClipboard]::ClearIfUnchanged($false)
            $clipboardCleanupComplete = $true
        }
        catch {
            # Keep ownership and retry. Contention does not mean somebody replaced the secret.
            $script:ClipboardClearAt = $now.AddSeconds(1)
            Set-AppStatus -Message 'Clipboard is busy — secure cleanup will retry'
        }
        if ($clipboardCleanupComplete) {
            $script:ClipboardClearAt = [DateTimeOffset]::MinValue
            $script:ClipboardDeviceId = $null
            $script:ClipboardKind = $null
            $script:ClipboardRecoveryKeyId = $null
            $selected = Get-SelectedDevice
            if ($null -ne $selected -and [string]::Equals([string]$selected.EntraDeviceId, $clipboardDeviceId, [StringComparison]::OrdinalIgnoreCase)) {
                $message = if ($clipboardCleared) { 'Protected clipboard cleared' } else { 'Clipboard content was replaced' }
                if ($clipboardKind -eq 'LAPS' -and $script:RevealedSecretKind -ne 'LAPS') {
                    Set-PasswordStatus -Message $message -DotColor '#64748B'
                }
                elseif ($clipboardKind -eq 'BitLocker' -and $script:RevealedSecretKind -ne 'BitLocker' -and
                    $null -ne $BitLockerKeySelector.SelectedItem -and
                    [string]::Equals([string]$BitLockerKeySelector.SelectedItem.Id, $clipboardRecoveryKeyId, [StringComparison]::OrdinalIgnoreCase)) {
                    Set-BitLockerStatus -Message $message -DotColor '#64748B'
                }
            }
        }
    }
    if ($script:CredentialExpiresAt -ne [DateTimeOffset]::MinValue -and $now -ge $script:CredentialExpiresAt) {
        $selected = Get-SelectedDevice
        $preserveClipboardStatus = $script:ClipboardKind -eq 'LAPS' -and $null -ne $selected -and
            [string]::Equals([string]$selected.EntraDeviceId, [string]$script:ClipboardDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
            $script:ClipboardClearAt -gt $now
        Clear-SecretDisplay -PreservePasswordStatus:$preserveClipboardStatus
        if ($preserveClipboardStatus) { $null = Update-ClipboardStatusForSelection }
    }
    elseif ($script:RevealedSecretKind -eq 'LAPS' -and $script:CredentialExpiresAt -ne [DateTimeOffset]::MinValue) {
        $seconds = [Math]::Max(0, [Math]::Ceiling(($script:CredentialExpiresAt - $now).TotalSeconds))
        $message = "Hides automatically in $seconds seconds"
        if ($PasswordCountdownText.Text -ne $message) { $PasswordCountdownText.Text = $message }
    }
    if ($script:BitLockerExpiresAt -ne [DateTimeOffset]::MinValue -and $now -ge $script:BitLockerExpiresAt) {
        $selected = Get-SelectedDevice
        $preserveClipboardStatus = $script:ClipboardKind -eq 'BitLocker' -and $null -ne $selected -and
            [string]::Equals([string]$selected.EntraDeviceId, [string]$script:ClipboardDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
            $script:ClipboardClearAt -gt $now
        Clear-SecretDisplay -PreserveBitLockerStatus:$preserveClipboardStatus
        if ($preserveClipboardStatus) { $null = Update-ClipboardStatusForSelection }
    }
    elseif ($script:RevealedSecretKind -eq 'BitLocker' -and $script:BitLockerExpiresAt -ne [DateTimeOffset]::MinValue) {
        $seconds = [Math]::Max(0, [Math]::Ceiling(($script:BitLockerExpiresAt - $now).TotalSeconds))
        $message = "Hides automatically in $seconds seconds"
        if ($BitLockerCountdownText.Text -ne $message) { $BitLockerCountdownText.Text = $message }
    }
})

# WPF's window procedure runs on the PowerShell/UI thread. SystemEvents invokes
# callbacks on its own thread, where a PowerShell scriptblock has no runspace.
$sessionMessageHook = [System.Windows.Interop.HwndSourceHook]{
    param([IntPtr]$hwnd, [int]$message, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)

    # WM_WTSSESSION_CHANGE: console/remote disconnect, logoff, SessionLock.
    if ($message -eq 0x02B1 -and $wParam.ToInt32() -in @(2, 4, 6, 7)) {
        Clear-SecretVerificationState
        Clear-SecretDisplay
        try {
            $null = [M365Workbench.Security.SecureClipboard]::ClearIfUnchanged($false)
            $script:ClipboardClearAt = [DateTimeOffset]::MinValue
            $script:ClipboardDeviceId = $null
            $script:ClipboardKind = $null
            $script:ClipboardRecoveryKeyId = $null
        }
        catch { $script:ClipboardClearAt = (Get-SensitiveClockNow) }
    }
    return [IntPtr]::Zero
}
$sessionWindowHandle = ([System.Windows.Interop.WindowInteropHelper]::new($window)).EnsureHandle()
$sessionWindowSource = [System.Windows.Interop.HwndSource]::FromHwnd($sessionWindowHandle)
$sessionWindowSource.AddHook($sessionMessageHook)
[M365Workbench.Security.WindowsSessionNotifications]::Register($sessionWindowHandle)
$window.Add_Closing({
    param($sender, $eventArgs)
    try { $null = [M365Workbench.Security.SecureClipboard]::ClearIfUnchanged() }
    catch {
        # Keep the timer alive until Windows releases our clipboard item.
        $eventArgs.Cancel = $true
        $script:ClipboardClearAt = Get-SensitiveClockNow
        Show-Toast -Message 'Clipboard is busy. Secure cleanup will retry; close the app again in a moment.' -Kind Error
        return
    }
    [M365Workbench.Security.WindowsSessionNotifications]::Unregister($sessionWindowHandle)
    $sessionWindowSource.RemoveHook($sessionMessageHook)
})

$window.Add_Loaded({
    $script:AppStarted = $true
    $onlyRecoveryReady = if ($settings.ContainsKey('OnlyRecoveryReadyByDefault')) {
        [bool]$settings.OnlyRecoveryReadyByDefault
    }
    elseif ($settings.ContainsKey('OnlyLapsReadyByDefault')) {
        [bool]$settings.OnlyLapsReadyByDefault
    }
    else {
        $true
    }
    $OnlyReadyCheckBox.IsChecked = $onlyRecoveryReady
    if ($DemoMode) {
        Set-AuthenticationDisplay -SignedIn $true -Text 'Demo data'
        Set-DeviceInventory -Devices (Get-DemoInventory)
        Set-AppStatus -Message 'Demo mode — no tenant connection'
        $SignInButton.Visibility = 'Collapsed'
        $RefreshButton.IsEnabled = $false
    }
    elseif ($NoAutoConnect) {
        Set-AuthenticationDisplay -SignedIn $false -Text 'Sign-in required'
        Set-AppStatus -Message 'Sign in to load computers'
    }
    else {
        Start-Authentication
    }

    $pollTimer.Start()

    if (-not [string]::IsNullOrWhiteSpace($RenderPreviewPath)) {
        if ($RenderPreviewState -eq 'MicrosoftVerification') {
            $AuthOverlayTitle.Text = 'Verify with Microsoft'
            $AuthOverlaySubtitle.Text = 'Required before accessing recovery data'
            $AuthOverlayInstruction.Text = 'Windows verification is not available. Complete Microsoft sign-in as the configured administrator account.'
            $AuthOverlayFooter.Text = "Your organization's sign-in policy determines which verification methods are required."
            $DeviceCodeText.Text = 'Z9Y8X7W6V'
            Set-LiveStatusText -Control $AuthOverlayStatus -Message "Code copied. Sign in as $($settings.ExpectedAccount)."
            $CopyCodeButton.IsEnabled = $true
            $OpenSignInButton.IsEnabled = $true
            $CancelVerificationButton.Visibility = 'Visible'
            $AuthOverlay.Visibility = 'Visible'
            Set-AppStatus -Message 'Waiting for Microsoft verification...' -Busy
        }
        elseif ($RenderPreviewState -in @('LapsClipboard','BitLockerClipboard')) {
            $previewTab = if ($RenderPreviewState -eq 'LapsClipboard') { 'LAPS' } else { 'BitLocker' }
            Set-RecoveryTab -Tab $previewTab
            $AccountNameText.Text = 'DemoLocalAdmin'
            # Preview state only: no secret retrieval or real clipboard write.
            $script:ClipboardDeviceId = [string]$DeviceGrid.SelectedItem.EntraDeviceId
            $script:ClipboardKind = $previewTab
            $script:ClipboardRecoveryKeyId = if ($previewTab -eq 'BitLocker') { [string]$BitLockerKeySelector.SelectedItem.Id } else { $null }
            $script:ClipboardClearAt = (Get-SensitiveClockNow).AddSeconds(45)
            $null = Update-ClipboardStatusForSelection
        }
        elseif ($RenderPreviewState -eq 'InventoryRefreshing') {
            # Presentation only; preview mode never starts a Graph operation.
            Set-InventoryLoadingState
        }
        elseif ($DemoMode) {
            Set-RecoveryTab -Tab 'LAPS'
            if ($null -ne $DeviceGrid.SelectedItem -and $DeviceGrid.Columns.Count -gt 3) {
                $DeviceGrid.CurrentCell = [System.Windows.Controls.DataGridCellInfo]::new($DeviceGrid.SelectedItem, $DeviceGrid.Columns[3])
                $null = $DeviceGrid.Focus()
            }
        }
        $window.Dispatcher.BeginInvoke([Action]{
            Save-WindowPreview -Path $RenderPreviewPath
            $window.Close()
        }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    }
})

$window.Add_Closed({
    $searchDebounceTimer.Stop()
    $pollTimer.Stop()
    Clear-SecretVerificationState
    Clear-SecretDisplay
    try { $null = [M365Workbench.Security.SecureClipboard]::ClearIfUnchanged() } catch { }
    if ($null -ne $script:GraphPowerShell) {
        if ($null -ne $script:CurrentOperation -and $null -ne $script:CurrentOperation.AsyncResult -and -not $script:CurrentOperation.AsyncResult.IsCompleted) {
            try { $script:GraphPowerShell.Stop() } catch { }
        }
        $script:GraphPowerShell.Dispose()
    }
    if ($null -ne $script:GraphRunspace) {
        $script:GraphRunspace.Close()
        $script:GraphRunspace.Dispose()
    }
    # Deliberately do not call Disconnect-MgGraph; retain the secure CurrentUser cache.
})

    $null = $window.ShowDialog()
}
catch {
    Add-Type -AssemblyName PresentationFramework
    $safeMessage = if ($script:AppStarted) {
        'Intune Device Workbench encountered an unexpected local error. Restart the app and try again.'
    }
    else {
        'Intune Device Workbench could not start. Check that PowerShell 7.4 or newer is installed, the application files are complete, and M365Workbench.settings.psd1 contains valid settings.'
    }
    [System.Windows.MessageBox]::Show(
        $safeMessage,
        'Intune Device Workbench',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    # Do not write raw exception records: they can retain Graph response values.
    exit 1
}
