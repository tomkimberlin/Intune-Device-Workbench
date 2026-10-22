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

# Anchor short-lived UI/clipboard deadlines to elapsed time, not the adjustable
# Windows clock. Keep DateTimeOffset only as the existing deadline representation.
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

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Intune Device Workbench · 2026.10.22"
        Width="1280" Height="780" MinWidth="1100" MinHeight="680"
        WindowStartupLocation="CenterScreen"
        Background="#F5F7FB"
        FontFamily="Segoe UI"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="PrimaryBrush" Color="#2563EB"/>
    <SolidColorBrush x:Key="PrimaryHoverBrush" Color="#1D4ED8"/>
    <SolidColorBrush x:Key="PrimaryPressedBrush" Color="#1E40AF"/>
    <SolidColorBrush x:Key="PrimarySoftBrush" Color="#EFF6FF"/>
    <SolidColorBrush x:Key="TextBrush" Color="#0F172A"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#64748B"/>
    <SolidColorBrush x:Key="BorderBrush" Color="#D8E1EC"/>
    <SolidColorBrush x:Key="SubtleBorderBrush" Color="#E8EDF4"/>
    <SolidColorBrush x:Key="SuccessBrush" Color="#15803D"/>
    <SolidColorBrush x:Key="SuccessSoftBrush" Color="#ECFDF3"/>
    <SolidColorBrush x:Key="DangerBrush" Color="#B42318"/>
    <SolidColorBrush x:Key="DangerSoftBrush" Color="#FEF3F2"/>

    <Style x:Key="ButtonFocusVisual">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Border BorderBrush="#93C5FD" BorderThickness="2" CornerRadius="9" Margin="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource PrimaryBrush}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="MinHeight" Value="40"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ButtonFocusVisual}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource PrimaryHoverBrush}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="{StaticResource PrimaryPressedBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="MinHeight" Value="40"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ButtonFocusVisual}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#F1F5F9"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#E2E8F0"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PortalLinkButton" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1D4ED8"/>
      <Setter Property="BorderBrush" Value="#D8E4F4"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ButtonFocusVisual}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#EFF6FF"/><Setter TargetName="ButtonBorder" Property="BorderBrush" Value="#93C5FD"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#DBEAFE"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.42"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="IconButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#64748B"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ButtonFocusVisual}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#EEF2F7"/><Setter Property="Foreground" Value="#334155"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#E2E8F0"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FilterCheckBox" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource ButtonFocusVisual}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <Border x:Name="CheckBoxBorder" Width="18" Height="18" CornerRadius="5" Background="White" BorderBrush="#CBD5E1" BorderThickness="1.2" Margin="0,0,8,0">
                <Path x:Name="CheckMark" Data="M0,3.5 L3,6.5 L10,0" Width="10" Height="7" Stretch="Fill" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CheckBoxBorder" Property="BorderBrush" Value="#2563EB"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="CheckBoxBorder" Property="BorderBrush" Value="#2563EB"/><Setter TargetName="CheckBoxBorder" Property="BorderThickness" Value="2"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="CheckBoxBorder" Property="Background" Value="#2563EB"/><Setter TargetName="CheckBoxBorder" Property="BorderBrush" Value="#2563EB"/><Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="RecoveryKeyPickerItem" TargetType="{x:Type ComboBoxItem}">
      <Setter Property="ToolTip" Value="{Binding Id}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#172033"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Margin" Value="3,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ComboBoxItem}">
            <Border x:Name="RecoveryKeyItemSurface"
                    Background="{TemplateBinding Background}"
                    CornerRadius="6"
                    Padding="{TemplateBinding Padding}"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                SnapsToDevicePixels="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="RecoveryKeyItemSurface" Property="Background" Value="#F1F6FF"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="RecoveryKeyItemSurface" Property="Background" Value="#E8F1FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.48"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="RecoveryKeyPicker" TargetType="{x:Type ComboBox}">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#172033"/>
      <Setter Property="BorderBrush" Value="#D8E1EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="ItemContainerStyle" Value="{StaticResource RecoveryKeyPickerItem}"/>
      <Setter Property="ItemTemplate">
        <Setter.Value>
          <DataTemplate>
            <Grid Margin="0,1">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <TextBlock Text="{Binding VolumeDisplay}"
                         Foreground="#172033"
                         FontSize="11.5"
                         FontWeight="SemiBold"
                         TextTrimming="CharacterEllipsis"/>
              <TextBlock Grid.Row="1"
                         Foreground="#64748B"
                         FontSize="10"
                         Margin="0,2,0,0"
                         TextTrimming="CharacterEllipsis">
                <Run Text="Backed up "/><Run Text="{Binding CreatedDisplay}"/>
              </TextBlock>
            </Grid>
          </DataTemplate>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type ComboBox}">
            <Grid SnapsToDevicePixels="True">
              <Border x:Name="RecoveryKeyPickerSurface"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      CornerRadius="8">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="38"/>
                  </Grid.ColumnDefinitions>
                  <ContentPresenter Margin="12,5,6,5"
                                    VerticalAlignment="Center"
                                    HorizontalAlignment="Stretch"
                                    Content="{TemplateBinding SelectionBoxItem}"
                                    ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                    ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                    SnapsToDevicePixels="True"/>
                  <Border Grid.Column="1" Background="Transparent">
                    <Path x:Name="RecoveryKeyPickerChevron"
                          Data="M 1 1 L 5 5 L 9 1"
                          Width="10"
                          Height="6"
                          Stretch="Fill"
                          Stroke="#64748B"
                          StrokeThickness="1.5"
                          StrokeStartLineCap="Round"
                          StrokeEndLineCap="Round"
                          StrokeLineJoin="Round"
                          HorizontalAlignment="Center"
                          VerticalAlignment="Center"/>
                  </Border>
                </Grid>
              </Border>
              <ToggleButton x:Name="RecoveryKeyPickerToggle"
                            Background="Transparent"
                            BorderThickness="0"
                            Focusable="False"
                            ClickMode="Press"
                            Cursor="{TemplateBinding Cursor}"
                            IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="{x:Type ToggleButton}">
                    <Border Background="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup"
                     AllowsTransparency="True"
                     Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}"
                     Placement="Bottom"
                     PopupAnimation="Fade">
                <Border x:Name="RecoveryKeyDropDownSurface"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        Background="White"
                        BorderBrush="#D8E1EC"
                        BorderThickness="1"
                        CornerRadius="9"
                        Margin="0,5,0,8"
                        Padding="2">
                  <Border.Effect>
                    <DropShadowEffect Color="#172033" BlurRadius="18" ShadowDepth="5" Opacity="0.18"/>
                  </Border.Effect>
                  <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}"
                                CanContentScroll="True"
                                HorizontalScrollBarVisibility="Disabled"
                                VerticalScrollBarVisibility="Auto"
                                SnapsToDevicePixels="True">
                    <ScrollViewer.Resources>
                      <Style TargetType="{x:Type ScrollBar}">
                        <Setter Property="Width" Value="8"/>
                        <Setter Property="Margin" Value="3,4,1,4"/>
                        <Setter Property="Background" Value="Transparent"/>
                        <Setter Property="Focusable" Value="False"/>
                        <Setter Property="Template">
                          <Setter.Value>
                            <ControlTemplate TargetType="{x:Type ScrollBar}">
                              <Grid Background="Transparent">
                                <Track x:Name="PART_Track"
                                       Orientation="Vertical"
                                       IsDirectionReversed="True"
                                       Minimum="{TemplateBinding Minimum}"
                                       Maximum="{TemplateBinding Maximum}"
                                       Value="{TemplateBinding Value}"
                                       ViewportSize="{TemplateBinding ViewportSize}">
                                  <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/>
                                  </Track.DecreaseRepeatButton>
                                  <Track.Thumb>
                                    <Thumb x:Name="RecoveryKeyScrollThumb" Width="4" MinHeight="26" HorizontalAlignment="Center" Background="#CBD5E1">
                                      <Thumb.Template>
                                        <ControlTemplate TargetType="{x:Type Thumb}">
                                          <Border x:Name="RecoveryKeyScrollThumbSurface" Background="{TemplateBinding Background}" CornerRadius="2"/>
                                          <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="RecoveryKeyScrollThumbSurface" Property="Background" Value="#94A3B8"/></Trigger>
                                            <Trigger Property="IsDragging" Value="True"><Setter TargetName="RecoveryKeyScrollThumbSurface" Property="Background" Value="#64748B"/></Trigger>
                                          </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                      </Thumb.Template>
                                    </Thumb>
                                  </Track.Thumb>
                                  <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/>
                                  </Track.IncreaseRepeatButton>
                                </Track>
                              </Grid>
                            </ControlTemplate>
                          </Setter.Value>
                        </Setter>
                      </Style>
                    </ScrollViewer.Resources>
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"
                                    SnapsToDevicePixels="True"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="RecoveryKeyPickerSurface" Property="BorderBrush" Value="#AFC2DB"/>
                <Setter TargetName="RecoveryKeyPickerSurface" Property="Background" Value="#FBFDFF"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="RecoveryKeyPickerSurface" Property="BorderBrush" Value="#2563EB"/>
              </Trigger>
              <Trigger Property="IsDropDownOpen" Value="True">
                <Setter TargetName="RecoveryKeyPickerSurface" Property="BorderBrush" Value="#2563EB"/>
                <Setter TargetName="RecoveryKeyPickerSurface" Property="Background" Value="#F8FBFF"/>
                <Setter TargetName="RecoveryKeyPickerChevron" Property="RenderTransform">
                  <Setter.Value><RotateTransform Angle="180" CenterX="5" CenterY="3"/></Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Cursor" Value="Arrow"/>
                <Setter TargetName="RecoveryKeyPickerSurface" Property="Background" Value="#F8FAFC"/>
                <Setter TargetName="RecoveryKeyPickerSurface" Property="BorderBrush" Value="#E2E8F0"/>
                <Setter TargetName="RecoveryKeyPickerChevron" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="LabelText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource MutedBrush}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="0,11,0,3"/>
    </Style>

    <Style x:Key="ValueText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F8FAFC"/>
      <Setter Property="Foreground" Value="#475569"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="12,11"/>
      <Setter Property="BorderBrush" Value="#D8E1EC"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="SeparatorBrush" Value="#D8E1EC"/>
      <Setter Property="SeparatorVisibility" Value="Visible"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F1F5F9"/></Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border x:Name="DeviceCellFrame"
                    Background="{TemplateBinding Background}"
                    BorderBrush="#D8E1EC"
                    BorderThickness="0,0,1,0"
                    SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#E8F1FF"/>
          <Setter Property="Foreground" Value="#163A72"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E9EEF5"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="MinHeight" Value="46"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#F6F9FE"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#E8F1FF"/></Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#172033"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="FontSize" Value="11"/>
    </Style>
  </Window.Resources>

  <Grid x:Name="RootGrid">
    <Grid.RowDefinitions>
      <RowDefinition Height="88"/>
      <RowDefinition Height="78"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="40"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="White" BorderBrush="#E4E9F0" BorderThickness="0,0,0,1">
      <Grid Margin="24,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="13"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Border Width="46" Height="46" CornerRadius="13" VerticalAlignment="Center">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
              <GradientStop Color="#2563EB" Offset="0"/>
              <GradientStop Color="#4338CA" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
          <Viewbox Width="46" Height="46" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Grid Width="56" Height="56">
              <Path Data="M15,24 L19,41 L28,31 L37,41 L41,24" Stroke="White" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Fill="Transparent" Stretch="None" HorizontalAlignment="Left" VerticalAlignment="Top"/>
              <Border Width="36" Height="6" Background="White" CornerRadius="3" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,20,0,0"/>
              <Border Width="10" Height="9" Background="#7DD3FC" CornerRadius="2.25" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,12,14,0"/>
            </Grid>
          </Viewbox>
        </Border>
        <StackPanel Grid.Column="2" VerticalAlignment="Center">
          <TextBlock Text="Intune Device Workbench" FontSize="23" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}"/>
          <TextBlock Text="Devices, LAPS, and BitLocker" FontSize="12.5" Foreground="{StaticResource MutedBrush}" Margin="0,4,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Background="#F1F5F9" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="18" Padding="12,7" Margin="0,0,10,0">
            <Grid VerticalAlignment="Center">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Ellipse x:Name="AuthDot" Width="8" Height="8" Fill="#94A3B8" Margin="0,0,7,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="AuthStatusText" Grid.Column="1" Text="Checking sign-in..." FontSize="12" FontWeight="SemiBold" Foreground="#475569" VerticalAlignment="Center" MaxWidth="320" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
            </Grid>
          </Border>
          <Button x:Name="SignInButton" Content="Sign in" Style="{StaticResource SecondaryButton}" MinWidth="92"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="1" Margin="24,14,24,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="455"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Border Grid.Column="0" Height="50" Background="White" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="9">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="42"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="16" Foreground="#64748B" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          <TextBox x:Name="SearchBox" Grid.Column="1" BorderThickness="0" Background="Transparent" FontSize="14" Foreground="{StaticResource TextBrush}" VerticalContentAlignment="Center" Padding="2,10,0,10" AutomationProperties.Name="Search computers"/>
          <TextBlock x:Name="SearchHint" Grid.Column="1" Text="Search computer, user, serial, or model" Foreground="#94A3B8" FontSize="14" IsHitTestVisible="False" VerticalAlignment="Center" Margin="2,0,0,0"/>
          <Border Grid.Column="2" Background="#F1F5F9" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="5" Padding="6,3" Margin="7,0,10,0" VerticalAlignment="Center" HorizontalAlignment="Right" IsHitTestVisible="False">
            <TextBlock Text="Ctrl + F" Foreground="#64748B" FontSize="10" FontWeight="SemiBold"/>
          </Border>
          <Button x:Name="ClearSearchButton" Grid.Column="3" Width="38" Content="×" Style="{StaticResource IconButton}" FontSize="18" Padding="8" Visibility="Collapsed" ToolTip="Clear search" AutomationProperties.Name="Clear search"/>
        </Grid>
      </Border>
      <Border x:Name="EntraOnlyFilterContainer" Grid.Column="2" Height="50" MinWidth="146" Background="White" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="9" Padding="12,0" Margin="14,0,0,0" Visibility="Collapsed">
        <CheckBox x:Name="EntraOnlyCheckBox" Style="{StaticResource FilterCheckBox}" VerticalAlignment="Center" ToolTip="Show devices found in Microsoft Entra with no matching Intune managed-device record" AutomationProperties.Name="Show Entra-only devices">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="Entra only" Foreground="#9A3412" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <Border Background="#FFEDD5" CornerRadius="9" MinWidth="20" Height="20" Margin="7,0,0,0" Padding="5,0">
              <TextBlock x:Name="EntraOnlyFilterCount" Text="0" Foreground="#9A3412" FontSize="10.5" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </StackPanel>
        </CheckBox>
      </Border>
      <Border Grid.Column="3" Height="50" Background="White" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="9" Padding="12,0" Margin="10,0">
        <CheckBox x:Name="OnlyReadyCheckBox" Content="Recovery-ready only" Style="{StaticResource FilterCheckBox}" VerticalAlignment="Center" IsChecked="True" ToolTip="Show devices with LAPS or BitLocker recovery material"/>
      </Border>
      <Button x:Name="RefreshButton" Grid.Column="4" Style="{StaticResource SecondaryButton}" MinWidth="108" Height="50" ToolTip="Refresh devices (F5)">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="RefreshIcon" Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,7,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="RefreshButtonText" Text="Refresh" VerticalAlignment="Center"/>
        </StackPanel>
      </Button>
    </Grid>

    <Grid Grid.Row="2" Margin="24,0,24,14">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="330"/></Grid.ColumnDefinitions>

      <Grid Grid.Column="0" Margin="0,0,14,0">
        <Border x:Name="DeviceTableSurface" Background="White" CornerRadius="10" ClipToBounds="True">
          <Grid>
          <DataGrid x:Name="DeviceGrid"
                    AutoGenerateColumns="False"
                    IsReadOnly="True"
                    SelectionMode="Single"
                    SelectionUnit="FullRow"
                    HeadersVisibility="Column"
                    GridLinesVisibility="None"
                    BorderThickness="0"
                    Background="White"
                    AlternationCount="2"
                    AlternatingRowBackground="#FBFCFE"
                    RowHeaderWidth="0"
                    ColumnHeaderHeight="42"
                    RowHeight="48"
                    CanUserAddRows="False"
                    CanUserDeleteRows="False"
                    CanUserReorderColumns="False"
                    ScrollViewer.CanContentScroll="True"
                    EnableRowVirtualization="True"
                    VirtualizingPanel.IsVirtualizing="True"
                    VirtualizingPanel.VirtualizationMode="Recycling"
                    VirtualizingPanel.ScrollUnit="Pixel">
            <DataGrid.Resources>
              <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#E8F1FF"/>
              <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#163A72"/>
              <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#EEF4FD"/>
              <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#163A72"/>
              <SolidColorBrush x:Key="DeviceListScrollThumbBrush" Color="#CBD5E1"/>
              <Style TargetType="ScrollBar">
                <Setter Property="Width" Value="12"/>
                <Setter Property="MinWidth" Value="12"/>
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="Margin" Value="1,4,3,7"/>
                <Setter Property="Focusable" Value="False"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                      <Grid Background="Transparent">
                        <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}">
                          <Track.DecreaseRepeatButton>
                            <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/>
                          </Track.DecreaseRepeatButton>
                          <Track.Thumb>
                            <Thumb x:Name="DeviceListVerticalThumb" Width="6" MinHeight="32" HorizontalAlignment="Center" Background="{StaticResource DeviceListScrollThumbBrush}">
                              <Thumb.Template>
                                <ControlTemplate TargetType="Thumb">
                                  <Border x:Name="ThumbBorder" Background="{TemplateBinding Background}" CornerRadius="3"/>
                                  <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="#94A3B8"/></Trigger>
                                    <Trigger Property="IsDragging" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="#64748B"/></Trigger>
                                  </ControlTemplate.Triggers>
                                </ControlTemplate>
                              </Thumb.Template>
                            </Thumb>
                          </Track.Thumb>
                          <Track.IncreaseRepeatButton>
                            <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/>
                          </Track.IncreaseRepeatButton>
                        </Track>
                      </Grid>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
                <Style.Triggers>
                  <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="MinWidth" Value="0"/>
                    <Setter Property="Height" Value="12"/>
                    <Setter Property="MinHeight" Value="12"/>
                    <Setter Property="Margin" Value="4,1,7,3"/>
                    <Setter Property="Template">
                      <Setter.Value>
                        <ControlTemplate TargetType="ScrollBar">
                          <Grid Background="Transparent">
                            <Track x:Name="PART_Track" Orientation="Horizontal" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}">
                              <Track.DecreaseRepeatButton>
                                <RepeatButton Command="{x:Static ScrollBar.PageLeftCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/>
                              </Track.DecreaseRepeatButton>
                              <Track.Thumb>
                                <Thumb x:Name="DeviceListHorizontalThumb" Height="6" MinWidth="32" VerticalAlignment="Center" Background="{StaticResource DeviceListScrollThumbBrush}">
                                  <Thumb.Template>
                                    <ControlTemplate TargetType="Thumb">
                                      <Border x:Name="ThumbBorder" Background="{TemplateBinding Background}" CornerRadius="3"/>
                                      <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="#94A3B8"/></Trigger>
                                        <Trigger Property="IsDragging" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="#64748B"/></Trigger>
                                      </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                  </Thumb.Template>
                                </Thumb>
                              </Track.Thumb>
                              <Track.IncreaseRepeatButton>
                                <RepeatButton Command="{x:Static ScrollBar.PageRightCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/>
                              </Track.IncreaseRepeatButton>
                            </Track>
                          </Grid>
                        </ControlTemplate>
                      </Setter.Value>
                    </Setter>
                  </Trigger>
                </Style.Triggers>
              </Style>
            </DataGrid.Resources>
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="Computer" SortMemberPath="DeviceName" Width="135">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <TextBlock Text="{Binding DeviceName}" FontWeight="SemiBold" Foreground="#183153" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding DeviceName}" Margin="12,0"/>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Primary user" SortMemberPath="PrimaryUser" Width="155">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <TextBlock x:Name="PrimaryUserCell" Text="{Binding PrimaryUser}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding UserPrincipalName}" Margin="12,0"/>
                    <DataTemplate.Triggers>
                      <DataTrigger Binding="{Binding PrimaryUser}" Value="Unassigned"><Setter TargetName="PrimaryUserCell" Property="Foreground" Value="#94A3B8"/><Setter TargetName="PrimaryUserCell" Property="FontStyle" Value="Italic"/></DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Model" SortMemberPath="Model" Width="125">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><TextBlock Text="{Binding Model}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" ToolTip="{Binding Model}" Margin="12,0"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Recovery" SortMemberPath="RecoveryAvailable" Width="128">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <StackPanel Orientation="Horizontal" Margin="10,0" VerticalAlignment="Center">
                      <Border x:Name="LapsPill" Background="{StaticResource SuccessSoftBrush}" CornerRadius="10" Padding="7,3" HorizontalAlignment="Left" ToolTip="Windows LAPS password available">
                        <TextBlock x:Name="LapsPillText" Text="LAPS" Foreground="{StaticResource SuccessBrush}" FontSize="10.5" FontWeight="SemiBold"/>
                      </Border>
                      <Border x:Name="BitLockerPill" Background="{StaticResource PrimarySoftBrush}" CornerRadius="10" Padding="7,3" HorizontalAlignment="Left" Margin="5,0,0,0" ToolTip="{Binding BitLockerStatus}">
                        <TextBlock x:Name="BitLockerPillText" Text="{Binding BitLockerStatus}" Foreground="#1D4ED8" FontSize="10.5" FontWeight="SemiBold"/>
                      </Border>
                    </StackPanel>
                    <DataTemplate.Triggers>
                      <DataTrigger Binding="{Binding LapsAvailable}" Value="False">
                        <Setter TargetName="LapsPill" Property="Background" Value="#F1F5F9"/>
                        <Setter TargetName="LapsPillText" Property="Foreground" Value="#94A3B8"/>
                        <Setter TargetName="LapsPill" Property="ToolTip" Value="No Entra-backed LAPS password"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding BitLockerAvailable}" Value="False">
                        <Setter TargetName="BitLockerPill" Property="Background" Value="#F1F5F9"/>
                        <Setter TargetName="BitLockerPillText" Property="Foreground" Value="#94A3B8"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="LAPS changed" SortMemberPath="LastBackupDateTime" Width="145">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate><TextBlock Text="{Binding LastBackupDisplay}" VerticalAlignment="Center" Margin="12,0"/></DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
              <DataGridTemplateColumn Header="Last Intune sync" SortMemberPath="LastSyncDateTime" Width="*" MinWidth="155">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0">
                      <Ellipse x:Name="StaleDot" Width="6" Height="6" Fill="#D97706" Margin="0,0,6,0" Visibility="Collapsed"/>
                      <TextBlock x:Name="LastSyncCell" Text="{Binding LastSyncDisplay}" TextTrimming="CharacterEllipsis"/>
                      <Border x:Name="EntraOnlyPill" Background="#FFF7ED" BorderBrush="#FED7AA" BorderThickness="1" CornerRadius="10" Padding="7,3" Visibility="Collapsed" ToolTip="{Binding ManagementStateDescription}">
                        <StackPanel Orientation="Horizontal">
                          <Ellipse Width="6" Height="6" Fill="#D97706" Margin="0,0,6,0" VerticalAlignment="Center"/>
                          <TextBlock Text="Entra only" Foreground="#9A3412" FontSize="10.5" FontWeight="SemiBold"/>
                        </StackPanel>
                      </Border>
                    </StackPanel>
                    <DataTemplate.Triggers>
                      <DataTrigger Binding="{Binding IsStale}" Value="True">
                        <Setter TargetName="StaleDot" Property="Visibility" Value="Visible"/>
                        <Setter TargetName="LastSyncCell" Property="Foreground" Value="#B45309"/>
                      </DataTrigger>
                      <DataTrigger Binding="{Binding IsEntraOnly}" Value="True">
                        <Setter TargetName="LastSyncCell" Property="Visibility" Value="Collapsed"/>
                        <Setter TargetName="EntraOnlyPill" Property="Visibility" Value="Visible"/>
                      </DataTrigger>
                    </DataTemplate.Triggers>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>
          <StackPanel x:Name="EmptyState" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed">
            <Border Background="#F1F5F9" CornerRadius="26" Width="52" Height="52" HorizontalAlignment="Center" Margin="0,0,0,13">
              <TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="20" Foreground="#64748B" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="EmptyStateTitle" Text="No matching computers" FontSize="17" FontWeight="SemiBold" Foreground="#334155" HorizontalAlignment="Center"/>
            <TextBlock x:Name="EmptyStateDescription" Text="Try another search or include devices without recovery material." Foreground="#64748B" Margin="0,6,0,0"/>
          </StackPanel>
            <Border x:Name="LoadingOverlay" Background="#F8FFFFFF" Panel.ZIndex="10" Visibility="Collapsed">
              <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                <ProgressBar Width="150" Height="4" IsIndeterminate="True" Foreground="{StaticResource PrimaryBrush}"/>
                <TextBlock x:Name="LoadingText" Text="Loading managed devices..." Foreground="#475569" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,14,0,0"/>
                <TextBlock Text="Checking Intune, Entra, LAPS, and BitLocker" Foreground="#94A3B8" FontSize="11" HorizontalAlignment="Center" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
          </Grid>
        </Border>
        <Border x:Name="DeviceTableOutline" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="10" IsHitTestVisible="False" Panel.ZIndex="20"/>
      </Grid>

      <Border Grid.Column="1" Background="White" BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="10" Padding="18">
        <Grid>
          <StackPanel x:Name="NoSelectionPanel" VerticalAlignment="Center">
            <Border Background="{StaticResource PrimarySoftBrush}" CornerRadius="31" Width="62" Height="62" HorizontalAlignment="Center">
              <Viewbox Width="28" Height="28" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Grid Width="24" Height="24">
                  <Path Data="M12,2 L20,5 L20,11 C20,16.1 16.6,20.2 12,22 C7.4,20.2 4,16.1 4,11 L4,5 Z" Stroke="#2563EB" StrokeThickness="1.65" StrokeLineJoin="Round" Fill="Transparent"/>
                  <Path Data="M9,11 L9,9.5 C9,7.7 10.3,6.4 12,6.4 C13.7,6.4 15,7.7 15,9.5 L15,11 M8,11 L16,11 L16,17 L8,17 Z" Stroke="#2563EB" StrokeThickness="1.5" StrokeLineJoin="Round" Fill="Transparent"/>
                </Grid>
              </Viewbox>
            </Border>
            <TextBlock Text="Select a computer" FontSize="17" FontWeight="SemiBold" Foreground="#334155" HorizontalAlignment="Center" Margin="0,15,0,0"/>
            <TextBlock Text="Select a computer to view device and recovery details." TextWrapping="Wrap" TextAlignment="Center" Foreground="#64748B" Margin="18,7,18,0" LineHeight="18"/>
          </StackPanel>

          <ScrollViewer x:Name="DetailPanel" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Visibility="Collapsed" Margin="0,0,-8,0">
            <ScrollViewer.Resources>
              <Style TargetType="ScrollBar">
                <Setter Property="Width" Value="7"/>
                <Setter Property="Margin" Value="10,3,2,3"/>
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                      <Grid Background="Transparent">
                        <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}">
                          <Track.DecreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
                          <Track.Thumb>
                            <Thumb MinHeight="34" Background="#CBD5E1">
                              <Thumb.Template>
                                <ControlTemplate TargetType="Thumb">
                                  <Border x:Name="ThumbBorder" Background="{TemplateBinding Background}" CornerRadius="3.5"/>
                                  <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBorder" Property="Background" Value="#94A3B8"/></Trigger></ControlTemplate.Triggers>
                                </ControlTemplate>
                              </Thumb.Template>
                            </Thumb>
                          </Track.Thumb>
                          <Track.IncreaseRepeatButton><RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Background="Transparent" BorderThickness="0" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
                        </Track>
                      </Grid>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </ScrollViewer.Resources>
            <StackPanel Margin="0,0,16,0">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="DetailDeviceName" FontSize="20" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" VerticalAlignment="Center"/>
                  <Border x:Name="HeaderComplianceBadge" Grid.Column="1" CornerRadius="9" Padding="6,3" Margin="8,0,0,0" VerticalAlignment="Center" Background="#F1F5F9" ToolTip="Compliance reported by Intune at the last inventory refresh; not a live health check.">
                    <TextBlock x:Name="HeaderComplianceText" Text="Unknown" FontSize="10.5" FontWeight="SemiBold" Foreground="#64748B" AutomationProperties.Name="Compliance: Unknown"/>
                  </Border>
                </Grid>
                <TextBlock x:Name="DetailPrimaryUser" Foreground="#475569" FontSize="12" FontWeight="SemiBold" Margin="0,3,0,0" TextWrapping="Wrap"/>
                <TextBlock x:Name="DetailUserPrincipalName" Foreground="{StaticResource MutedBrush}" FontSize="11.5" Margin="0,2,0,0" TextWrapping="Wrap"/>
              </StackPanel>

              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Border x:Name="DetailLapsBadge" Background="{StaticResource SuccessSoftBrush}" CornerRadius="11" Padding="8,4" HorizontalAlignment="Left">
                  <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="DetailLapsDot" Width="7" Height="7" Fill="{StaticResource SuccessBrush}" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailLapsStatus" Foreground="{StaticResource SuccessBrush}" FontSize="11" FontWeight="SemiBold"/>
                  </StackPanel>
                </Border>
                <Border x:Name="DetailBitLockerBadge" Background="{StaticResource PrimarySoftBrush}" CornerRadius="11" Padding="8,4" HorizontalAlignment="Left" Margin="6,0,0,0">
                  <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="DetailBitLockerDot" Width="7" Height="7" Fill="#2563EB" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailBitLockerStatus" Foreground="#1D4ED8" FontSize="11" FontWeight="SemiBold"/>
                  </StackPanel>
                </Border>
              </StackPanel>

              <Grid Margin="0,11,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Button x:Name="OpenIntuneButton" Grid.Column="0" Style="{StaticResource PortalLinkButton}" IsEnabled="False" AutomationProperties.Name="Open selected device in Intune">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Open in Intune" VerticalAlignment="Center"/>
                    <TextBlock Text="&#xE8A7;" FontFamily="Segoe MDL2 Assets" FontSize="10.5" Margin="6,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <Button x:Name="OpenEntraButton" Grid.Column="2" Style="{StaticResource PortalLinkButton}" IsEnabled="False" AutomationProperties.Name="Open selected device in Entra">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Open in Entra" VerticalAlignment="Center"/>
                    <TextBlock Text="&#xE8A7;" FontFamily="Segoe MDL2 Assets" FontSize="10.5" Margin="6,0,0,0" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
              </Grid>

              <Border x:Name="EntraOnlyNotice" Background="#FFF7ED" BorderBrush="#F59E0B" BorderThickness="3,0,0,0" CornerRadius="7" Padding="10,8" Margin="0,11,0,0" Visibility="Collapsed">
                <StackPanel>
                  <TextBlock Text="Entra only" Foreground="#9A3412" FontSize="11.5" FontWeight="SemiBold"/>
                  <TextBlock Text="No matching Intune managed-device record" Foreground="#B45309" FontSize="10.5" Margin="0,2,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>

              <Border Background="#F1F5F9" CornerRadius="9" Padding="3" Margin="0,14,0,0">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Button x:Name="LapsTabButton" Grid.Column="0" Content="LAPS" Style="{StaticResource SecondaryButton}" Height="34" MinHeight="34" Padding="10,5" BorderThickness="0"/>
                  <Button x:Name="BitLockerTabButton" Grid.Column="1" Content="BitLocker" Style="{StaticResource SecondaryButton}" Height="34" MinHeight="34" Padding="10,5" BorderThickness="0" Background="Transparent"/>
                </Grid>
              </Border>

              <StackPanel x:Name="LapsRecoveryPanel">
                <Border Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="9" Padding="13" Margin="0,10,0,0">
                  <StackPanel>
                    <TextBlock Text="LOCAL ADMINISTRATOR" Foreground="#64748B" FontSize="9.5" FontWeight="Bold" VerticalAlignment="Center"/>
                    <TextBlock x:Name="AccountNameText" Text="Retrieved with password" Foreground="#334155" FontSize="13" FontWeight="SemiBold" Margin="0,5,0,0" TextWrapping="Wrap"/>
                    <TextBlock x:Name="PasswordText" Text="••••••••••••••••" FontFamily="Cascadia Mono, Consolas" FontSize="18" FontWeight="SemiBold" Foreground="#0F172A" Margin="0,10,0,0" TextWrapping="Wrap"/>
                    <Grid Margin="0,5,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Ellipse x:Name="PasswordStatusDot" Width="6" Height="6" Fill="#94A3B8" Margin="0,4,6,0" VerticalAlignment="Top"/>
                      <TextBlock x:Name="PasswordCountdownText" Grid.Column="1" Text="Password remains hidden until requested" Foreground="#64748B" FontSize="10.5" TextWrapping="Wrap"/>
                    </Grid>
                    <Grid Margin="0,10,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Grid.RowDefinitions><RowDefinition Height="22"/><RowDefinition Height="22"/></Grid.RowDefinitions>
                      <TextBlock Grid.Row="0" Text="Changed" Foreground="#64748B" FontSize="10.5" VerticalAlignment="Center"/>
                      <TextBlock x:Name="DetailBackupDate" Grid.Row="0" Grid.Column="1" Foreground="#334155" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                      <TextBlock Grid.Row="1" Text="Next refresh" Foreground="#64748B" FontSize="10.5" VerticalAlignment="Center"/>
                      <TextBlock x:Name="DetailRefreshDate" Grid.Row="1" Grid.Column="1" Foreground="#334155" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </Grid>
                  </StackPanel>
                </Border>

                <Button x:Name="CopyPasswordButton" Style="{StaticResource PrimaryButton}" Height="44" Margin="0,10,0,8" IsEnabled="False" ToolTip="Copy password (Ctrl + Shift + C)" AutomationProperties.Name="Copy local administrator password">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="CopyPasswordButtonText" Text="Copy password" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <Button x:Name="RevealPasswordButton" Grid.Column="0" Content="Reveal briefly" Style="{StaticResource SecondaryButton}" Height="38" FontSize="11" IsEnabled="False" ToolTip="Reveal for a short, timed interval"/>
                  <Button x:Name="CopyAccountButton" Grid.Column="2" Content="Copy username" Style="{StaticResource SecondaryButton}" Height="38" FontSize="11" IsEnabled="False" ToolTip="Copy the local administrator account name"/>
                </Grid>
              </StackPanel>

              <StackPanel x:Name="BitLockerRecoveryPanel" Visibility="Collapsed">
                <TextBlock Text="RECOVERY KEY" Foreground="#64748B" FontSize="9.5" FontWeight="Bold" Margin="0,11,0,6"/>
                <ComboBox x:Name="BitLockerKeySelector"
                          Style="{StaticResource RecoveryKeyPicker}"
                          TextSearch.TextPath="Id"
                          MaxDropDownHeight="232"
                          IsEnabled="False"
                          ToolTip="Choose a BitLocker recovery-key record"
                          AutomationProperties.Name="BitLocker recovery key record"/>
                <Border Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="9" Padding="13" Margin="0,9,0,0">
                  <StackPanel>
                    <Grid>
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <TextBlock x:Name="BitLockerVolumeText" Text="No recovery key" Foreground="#334155" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}"/>
                      <TextBlock x:Name="BitLockerKeyIdText" Grid.Column="1" Foreground="#64748B" FontSize="10" FontFamily="Cascadia Mono, Consolas" Margin="8,0,0,0" VerticalAlignment="Center"/>
                    </Grid>
                    <TextBlock x:Name="BitLockerKeyText" Text="••••••-••••••-••••••-••••••-••••••-••••••-••••••-••••••" FontFamily="Cascadia Mono, Consolas" FontSize="13" FontWeight="SemiBold" Foreground="#0F172A" Margin="0,10,0,0" TextWrapping="Wrap" LineHeight="19"/>
                    <Grid Margin="0,6,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <Ellipse x:Name="BitLockerStatusDot" Width="6" Height="6" Fill="#94A3B8" Margin="0,4,6,0" VerticalAlignment="Top"/>
                      <TextBlock x:Name="BitLockerCountdownText" Grid.Column="1" Text="Recovery key remains hidden until requested" Foreground="#64748B" FontSize="10.5" TextWrapping="Wrap"/>
                    </Grid>
                    <Grid Margin="0,9,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="92"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                      <TextBlock Text="Backed up" Foreground="#64748B" FontSize="10.5" VerticalAlignment="Center"/>
                      <TextBlock x:Name="BitLockerCreatedText" Grid.Column="1" Foreground="#334155" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </Grid>
                  </StackPanel>
                </Border>
                <Button x:Name="CopyRecoveryKeyButton" Style="{StaticResource PrimaryButton}" Height="44" Margin="0,10,0,8" IsEnabled="False" ToolTip="Copy recovery key (Ctrl + Shift + C)" AutomationProperties.Name="Copy BitLocker recovery key">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="CopyRecoveryKeyButtonText" Text="Copy recovery key" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <Button x:Name="RevealRecoveryKeyButton" Content="Reveal briefly" Style="{StaticResource SecondaryButton}" Height="38" FontSize="11" IsEnabled="False" ToolTip="Reveal for a short, timed interval"/>
              </StackPanel>

              <Border BorderBrush="#E8EDF4" BorderThickness="0,1,0,0" Margin="0,15,0,0" Padding="0,13,0,0">
                <StackPanel>
                  <Grid Margin="0,0,0,5">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock Text="DEVICE DETAILS" Foreground="#64748B" FontSize="9.5" FontWeight="Bold" VerticalAlignment="Center"/>
                    <Button x:Name="CopyDeviceDetailsButton" Grid.Column="1" Content="Copy details" Style="{StaticResource PortalLinkButton}" Padding="7,3" MinHeight="26" IsEnabled="False" ToolTip="Copy device name, primary user/UPN, serial and OS from the current inventory. No recovery secrets. Clipboard clears automatically." AutomationProperties.Name="Copy device details for a support ticket"/>
                  </Grid>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/>
                    </Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Model" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailModel" Grid.Row="0" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="1" Text="OS" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailOperatingSystem" Grid.Row="1" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="2" Text="Last Intune sync" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailLastSync" Grid.Row="2" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="3" Text="Entra activity" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailEntraActivity" Grid.Row="3" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="4" Text="Serial number" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailSerial" Grid.Row="4" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="5" Text="Compliance" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                      <Ellipse x:Name="DetailComplianceDot" Width="7" Height="7" Fill="#94A3B8" Margin="0,0,6,0"/>
                      <TextBlock x:Name="DetailCompliance" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold"/>
                    </StackPanel>
                    <TextBlock Grid.Row="6" Text="Encrypted" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailEncrypted" Grid.Row="6" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="7" Text="Ownership" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailOwnership" Grid.Row="7" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="8" Text="Join type" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <TextBlock x:Name="DetailJoinType" Grid.Row="8" Grid.Column="1" Foreground="#172033" FontSize="11.5" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="9" Text="Management" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/>
                    <Border x:Name="DetailManagementBadge" Grid.Row="9" Grid.Column="1" Background="#EFF6FF" BorderBrush="#DBEAFE" BorderThickness="1" CornerRadius="10" Padding="7,3" HorizontalAlignment="Left" VerticalAlignment="Center">
                      <StackPanel Orientation="Horizontal">
                        <Ellipse x:Name="DetailSourceDot" Width="6" Height="6" Fill="#2563EB" Margin="0,0,6,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="DetailSource" Foreground="#1D4ED8" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Border>
                  </Grid>
                </StackPanel>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </Border>
    </Grid>

    <Border Grid.Row="3" Background="White" BorderBrush="#E4E9F0" BorderThickness="0,1,0,0">
      <Grid Margin="24,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <Grid VerticalAlignment="Center" Margin="0,0,12,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="#64748B" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <ProgressBar x:Name="BusyIndicator" Grid.Column="1" Width="64" Height="3" IsIndeterminate="True" Foreground="{StaticResource PrimaryBrush}" Visibility="Collapsed" Margin="0,0,10,0"/>
          <TextBlock x:Name="FooterStatusText" Grid.Column="2" Text="Starting..." Foreground="#64748B" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" AutomationProperties.Name="Application status" AutomationProperties.LiveSetting="Polite"/>
        </Grid>
        <TextBlock x:Name="DeviceCountText" Grid.Column="1" Foreground="#64748B" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <Border x:Name="ToastBorder" Grid.RowSpan="4" Panel.ZIndex="40" Background="#172033" BorderBrush="#334155" BorderThickness="1" CornerRadius="9" Padding="13,11" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,28,58" Visibility="Collapsed">
      <Border.Effect><DropShadowEffect Color="#33000000" BlurRadius="14" ShadowDepth="3" Opacity="0.5"/></Border.Effect>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="25"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Width="20" Height="20" CornerRadius="10" Background="#20FFFFFF" VerticalAlignment="Top">
          <TextBlock x:Name="ToastIcon" Text="✓" Foreground="White" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock x:Name="ToastText" Grid.Column="1" Foreground="White" FontSize="12.5" FontWeight="SemiBold" MaxWidth="400" TextWrapping="Wrap" VerticalAlignment="Center" AutomationProperties.Name="Notification" AutomationProperties.LiveSetting="Assertive"/>
      </Grid>
    </Border>

    <Border x:Name="AuthOverlay" Grid.RowSpan="4" Panel.ZIndex="50" Background="#EAF5F7FB" Visibility="Collapsed" Focusable="True" AutomationProperties.Name="Microsoft authentication dialog" KeyboardNavigation.TabNavigation="Cycle" KeyboardNavigation.ControlTabNavigation="Cycle" KeyboardNavigation.DirectionalNavigation="Cycle">
      <Border Background="White" BorderBrush="#CFD8E5" BorderThickness="1" CornerRadius="14" Padding="28" Width="560" HorizontalAlignment="Center" VerticalAlignment="Center" KeyboardNavigation.TabNavigation="Cycle" KeyboardNavigation.ControlTabNavigation="Cycle" KeyboardNavigation.DirectionalNavigation="Cycle">
        <Border.Effect><DropShadowEffect Color="#260F172A" BlurRadius="24" ShadowDepth="6" Opacity="0.55"/></Border.Effect>
        <StackPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="48"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Width="42" Height="42" CornerRadius="11" Background="{StaticResource PrimarySoftBrush}">
              <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="18" Foreground="#2563EB" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock x:Name="AuthOverlayTitle" Text="Microsoft sign-in" FontSize="21" FontWeight="SemiBold" Foreground="{StaticResource TextBrush}" TextWrapping="Wrap"/>
              <TextBlock x:Name="AuthOverlaySubtitle" Text="Connect to load devices" Foreground="#64748B" FontSize="12" Margin="0,3,0,0" TextWrapping="Wrap"/>
            </StackPanel>
          </Grid>
          <TextBlock x:Name="AuthOverlayInstruction" Text="Use the configured administrator account and follow your organization's sign-in requirements." TextWrapping="Wrap" Foreground="#64748B" Margin="0,16,0,12" LineHeight="18"/>
          <Border Background="#F8FAFC" BorderBrush="#E2E8F0" BorderThickness="1" CornerRadius="8" Padding="11,8" Margin="0,0,0,14">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Ellipse Width="7" Height="7" Fill="#2563EB" Margin="0,0,8,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="AuthExpectedAccountText" Grid.Column="1" Text="Administrator account" Foreground="#334155" FontSize="11.5" FontWeight="SemiBold" TextWrapping="Wrap"/>
            </Grid>
          </Border>
          <Border Background="#EEF4FF" BorderBrush="#DBEAFE" BorderThickness="1" CornerRadius="10" Padding="18">
            <StackPanel>
              <TextBlock Text="DEVICE CODE" FontSize="9.5" FontWeight="Bold" Foreground="#64748B" HorizontalAlignment="Center"/>
              <TextBlock x:Name="DeviceCodeText" Text="Waiting for Microsoft..." FontFamily="Cascadia Mono, Consolas" FontSize="28" FontWeight="Bold" Foreground="#172033" HorizontalAlignment="Center" Margin="0,7,0,0"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="AuthOverlayStatus" Text="Preparing sign-in..." Foreground="#475569" HorizontalAlignment="Stretch" TextAlignment="Center" TextWrapping="Wrap" Margin="0,12,0,17" AutomationProperties.Name="Verification status" AutomationProperties.LiveSetting="Polite"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="10"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Button x:Name="CopyCodeButton" Grid.Column="0" Content="Copy code" Style="{StaticResource SecondaryButton}" IsEnabled="False"/>
            <Button x:Name="OpenSignInButton" Grid.Column="2" Content="Open sign-in page" Style="{StaticResource PrimaryButton}" IsEnabled="False"/>
          </Grid>
          <Button x:Name="CancelVerificationButton" Content="Cancel verification" Style="{StaticResource SecondaryButton}" Height="34" Margin="0,10,0,0" Visibility="Collapsed" AutomationProperties.Name="Cancel Microsoft verification"/>
          <TextBlock x:Name="AuthOverlayFooter" Text="Intune Device Workbench continues automatically after sign-in." Foreground="#94A3B8" FontSize="10.5" TextAlignment="Center" TextWrapping="Wrap" HorizontalAlignment="Center" Margin="20,14,20,0"/>
        </StackPanel>
      </Border>
    </Border>
  </Grid>
</Window>
'@

$reader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)
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
$script:CurrentCredential = $null
$script:CurrentCredentialDeviceId = $null
$script:CredentialExpiresAt = [DateTimeOffset]::MinValue
$script:CurrentBitLockerKey = $null
$script:CurrentBitLockerKeyId = $null
$script:CurrentBitLockerDeviceId = $null
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
$script:SecretVerifiedDeadlineTimestamp = [int64]0
$script:RecentInteractiveAuthenticationDeadlineTimestamp = [int64]0
$script:SecretVerificationGeneration = 0
$script:VerificationStateLock = [object]::new()
$script:AuthenticationDeviceCodeObserved = $false
$script:AuthenticationVerificationGeneration = $null
$script:ActiveRecoveryTab = 'LAPS'
$script:ToastExpiresAt = [DateTimeOffset]::MinValue
$script:SelectionChanging = $false

$authOperationScript = @'
param($TenantId, $ExpectedTenantObjectId, $ExpectedAccount, $RequiredScopes, $CoreModulePath, $MinimumGraphVersion)
& {
    $ErrorActionPreference = 'Stop'
    Import-Module $CoreModulePath -Force
    Import-Module Microsoft.Graph.Authentication -MinimumVersion ([version]$MinimumGraphVersion) -ErrorAction Stop

    try {
        $context = Get-MgContext
        $validation = Test-LapsGraphContext -Context $context -ExpectedAccount $ExpectedAccount -ExpectedTenantId $ExpectedTenantObjectId -RequiredScopes $RequiredScopes
        if (-not $validation.IsValid) {
            Connect-MgGraph `
                -TenantId $TenantId `
                -UseDeviceCode `
                -Scopes $RequiredScopes `
                -ContextScope CurrentUser `
                -NoWelcome `
                -ErrorAction Stop

            $context = Get-MgContext
            $validation = Test-LapsGraphContext -Context $context -ExpectedAccount $ExpectedAccount -ExpectedTenantId $ExpectedTenantObjectId -RequiredScopes $RequiredScopes
        }

        if (-not $validation.IsValid) {
            [pscustomobject]@{
                Kind = 'Error'
                ErrorCode = $validation.Reason
                Message = switch ($validation.Reason) {
                    'WrongAccount' { "Signed in as $($context.Account), not $ExpectedAccount." }
                    'WrongTenant' { "The Graph session is connected to tenant $($context.TenantId), not $ExpectedTenantObjectId." }
                    default { "The Graph session is missing required scopes: $($validation.MissingScopes -join ', ')." }
                }
                StatusCode = $null
            }
            return
        }

        [pscustomobject]@{
            Kind = 'AuthResult'
            Account = [string]$context.Account
            TenantId = [string]$context.TenantId
            Scopes = @($context.Scopes)
        }
    }
    catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties['ResponseStatusCode']) { $statusCode = [int]$_.Exception.ResponseStatusCode }
        $errorCode = if ($_.Exception.PSObject.Properties['ErrorCode']) { [string]$_.Exception.ErrorCode } else { [string]$_.FullyQualifiedErrorId }
        [pscustomobject]@{ Kind = 'Error'; ErrorCode = $errorCode; Message = [string]$_.Exception.Message; StatusCode = $statusCode }
    }
}
'@

$microsoftVerificationChildScript = @'
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$config = $null

function Write-VerificationResult {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Nonce,
        [string]$ErrorCode = ''
    )

    $payload = [pscustomobject]@{ Status = $Status; ErrorCode = $ErrorCode } | ConvertTo-Json -Compress
    $encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    [Console]::Out.WriteLine("M365WB_VERIFY_RESULT::$Nonce::$encodedPayload")
    [Console]::Out.Flush()
}

try {
    $configJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:M365WB_VERIFY_CONFIG))
    $config = $configJson | ConvertFrom-Json
    Import-Module ([string]$config.CoreModulePath) -Force
    Import-Module Microsoft.Graph.Authentication -MinimumVersion ([version]$config.MinimumGraphVersion) -ErrorAction Stop

    Connect-MgGraph `
        -TenantId ([string]$config.TenantId) `
        -UseDeviceCode `
        -Scopes ([string[]]$config.RequiredScopes) `
        -ContextScope Process `
        -NoWelcome `
        -ErrorAction Stop 6>&1 |
        ForEach-Object {
            [Console]::Out.WriteLine([string]$_)
            [Console]::Out.Flush()
        }

    $context = Get-MgContext
    $validation = Test-LapsGraphContext `
        -Context $context `
        -ExpectedAccount ([string]$config.ExpectedAccount) `
        -ExpectedTenantId ([Guid]$config.ExpectedTenantObjectId) `
        -RequiredScopes ([string[]]$config.RequiredScopes)

    if (-not $validation.IsValid) {
        Write-VerificationResult -Status 'Rejected' -Nonce ([string]$config.Nonce) -ErrorCode ([string]$validation.Reason)
        exit 3
    }

    Write-VerificationResult -Status 'Verified' -Nonce ([string]$config.Nonce)
    exit 0
}
catch {
    $errorCode = if ($_.Exception.PSObject.Properties['ErrorCode']) { [string]$_.Exception.ErrorCode } else { 'ConnectionFailed' }
    try {
        if ($null -ne $config -and -not [string]::IsNullOrWhiteSpace([string]$config.Nonce)) {
            Write-VerificationResult -Status 'Failed' -Nonce ([string]$config.Nonce) -ErrorCode $errorCode
        }
    }
    catch { }
    exit 2
}
'@

$microsoftVerificationOperationScript = @'
param($TenantId, $ExpectedTenantObjectId, $ExpectedAccount, $RequiredScopes, $CoreModulePath, $MinimumGraphVersion, $PowerShellExecutable, $Nonce, $ChildScript, $CancelEvent, $TimeoutSeconds)
& {
    $ErrorActionPreference = 'Stop'
    Import-Module $CoreModulePath -Force

    $process = $null
    $canceled = $false
    $timedOut = $false
    $deviceCodeObserved = $false
    $childStatus = $null
    $childErrorCode = $null
    try {
        $config = @{
            TenantId                = [string]$TenantId
            ExpectedTenantObjectId  = [string]$ExpectedTenantObjectId
            ExpectedAccount         = [string]$ExpectedAccount
            RequiredScopes          = [string[]]$RequiredScopes
            CoreModulePath          = [string]$CoreModulePath
            MinimumGraphVersion     = [string]$MinimumGraphVersion
            Nonce                   = [string]$Nonce
        }
        $configJson = $config | ConvertTo-Json -Compress -Depth 4
        $encodedConfig = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($configJson))
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([string]$ChildScript))

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = [string]$PowerShellExecutable
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.ArgumentList.Add('-NoLogo')
        $startInfo.ArgumentList.Add('-NoProfile')
        $startInfo.ArgumentList.Add('-NonInteractive')
        $startInfo.ArgumentList.Add('-EncodedCommand')
        $startInfo.ArgumentList.Add($encodedCommand)
        $startInfo.Environment['M365WB_VERIFY_CONFIG'] = $encodedConfig

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'The Microsoft verification process could not be started.'
        }

        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $sentinelPrefix = "M365WB_VERIFY_RESULT::$Nonce::"

        :readLoop while ($true) {
            if ($CancelEvent.WaitOne(0)) {
                $canceled = $true
                try { $process.Kill($true) } catch { }
                break readLoop
            }
            if ($stopwatch.Elapsed.TotalSeconds -ge [double]$TimeoutSeconds) {
                $timedOut = $true
                try { $process.Kill($true) } catch { }
                break readLoop
            }

            $lineTask = $process.StandardOutput.ReadLineAsync()
            while (-not $lineTask.Wait(100)) {
                if ($CancelEvent.WaitOne(0)) {
                    $canceled = $true
                    try { $process.Kill($true) } catch { }
                    break readLoop
                }
                if ($stopwatch.Elapsed.TotalSeconds -ge [double]$TimeoutSeconds) {
                    $timedOut = $true
                    try { $process.Kill($true) } catch { }
                    break readLoop
                }
            }

            $line = $lineTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                break
            }

            $deviceCode = Get-DeviceCodeFromMessage -Message $line
            if ($null -ne $deviceCode) {
                $deviceCodeObserved = $true
                Write-Output $line
                continue
            }

            if ($line.StartsWith($sentinelPrefix, [StringComparison]::Ordinal)) {
                try {
                    $encodedPayload = $line.Substring($sentinelPrefix.Length)
                    $payloadJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedPayload))
                    $payload = $payloadJson | ConvertFrom-Json
                    $childStatus = [string]$payload.Status
                    $childErrorCode = [string]$payload.ErrorCode
                }
                catch {
                    $childStatus = 'InvalidResult'
                }
            }
        }

        if (-not $process.HasExited) {
            $null = $process.WaitForExit(5000)
        }

        if ($CancelEvent.WaitOne(0)) {
            $canceled = $true
        }

        if ($canceled) {
            [pscustomobject]@{ Kind = 'VerificationCanceled' }
            return
        }
        if ($timedOut) {
            [pscustomobject]@{ Kind = 'VerificationError'; ErrorCode = 'VerificationTimedOut' }
            return
        }
        if ($process.ExitCode -eq 0 -and $childStatus -eq 'Verified' -and $deviceCodeObserved) {
            [pscustomobject]@{ Kind = 'MicrosoftVerificationResult' }
            return
        }
        if ($process.ExitCode -eq 0 -and $childStatus -eq 'Verified' -and -not $deviceCodeObserved) {
            [pscustomobject]@{ Kind = 'VerificationError'; ErrorCode = 'InteractiveVerificationNotObserved' }
            return
        }

        [pscustomobject]@{
            Kind = 'VerificationError'
            ErrorCode = if ([string]::IsNullOrWhiteSpace($childErrorCode)) { 'MicrosoftVerificationFailed' } else { $childErrorCode }
        }
    }
    catch {
        [pscustomobject]@{ Kind = 'VerificationError'; ErrorCode = 'MicrosoftVerificationFailed' }
    }
    finally {
        if ($null -ne $process) {
            if (-not $process.HasExited) {
                try { $process.Kill($true) } catch { }
            }
            $process.Dispose()
        }
    }
}
'@

$inventoryOperationScript = @'
param($CoreModulePath)
& {
    $ErrorActionPreference = 'Stop'
    Import-Module $CoreModulePath -Force
    $stage = 'managed device inventory'

    function Invoke-PagedGraphGet {
        param([Parameter(Mandatory)][string]$Uri)

        $items = [System.Collections.Generic.List[object]]::new()
        $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $next = $Uri
        while (-not [string]::IsNullOrWhiteSpace($next)) {
            $pageUri = [uri]$next
            if (-not $pageUri.IsAbsoluteUri -or $pageUri.Scheme -ne 'https' -or
                $pageUri.Host -ne 'graph.microsoft.com' -or -not $pageUri.IsDefaultPort -or
                $pageUri.UserInfo -or $pageUri.Fragment -or -not $pageUri.AbsolutePath.StartsWith('/v1.0/')) {
                throw 'Microsoft Graph returned an untrusted inventory page link.'
            }
            if (-not $visited.Add($pageUri.AbsoluteUri) -or $visited.Count -gt 10000) {
                throw 'Microsoft Graph inventory pagination did not complete safely.'
            }
            $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
            foreach ($item in @($response.value)) {
                if ($null -ne $item) { $items.Add($item) }
            }
            $nextProperty = $response.PSObject.Properties['@odata.nextLink']
            $next = if ($null -eq $nextProperty) { $null } else { [string]$nextProperty.Value }
        }
        return @($items)
    }

    try {
        $managedUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,azureADDeviceId,serialNumber,operatingSystem,osVersion,model,manufacturer,lastSyncDateTime,complianceState,managementState,managedDeviceOwnerType,deviceEnrollmentType,isEncrypted,managementAgent,enrolledDateTime"
        $lapsUri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials?`$select=id,deviceName,lastBackupDateTime,refreshDateTime"
        $bitLockerUri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys"
        $entraUri = "https://graph.microsoft.com/v1.0/devices?`$select=id,deviceId,displayName,accountEnabled,operatingSystem,operatingSystemVersion,trustType,approximateLastSignInDateTime,registrationDateTime,isManaged,isCompliant,deviceOwnership,manufacturer,model"

        $managedDevices = @(Invoke-PagedGraphGet -Uri $managedUri)
        $stage = 'Intune primary users'
        $primaryUsers = Get-IntunePrimaryUserMap -ManagedDevices $managedDevices
        $stage = 'LAPS metadata'
        $lapsMetadata = @(Invoke-PagedGraphGet -Uri $lapsUri)
        $stage = 'BitLocker metadata'
        $bitLockerMetadata = @(Invoke-PagedGraphGet -Uri $bitLockerUri)
        $stage = 'Entra device inventory'
        $entraDevices = @(Invoke-PagedGraphGet -Uri $entraUri)
        $rows = @(Merge-IntuneLapsDeviceData -ManagedDevices $managedDevices -LapsMetadata $lapsMetadata -BitLockerMetadata $bitLockerMetadata -EntraDevices $entraDevices -PrimaryUsersByManagedDeviceId $primaryUsers)

        [pscustomobject]@{
            Kind = 'InventoryResult'
            Devices = $rows
            TotalCount = $rows.Count
            LapsReadyCount = @($rows | Where-Object LapsAvailable).Count
            BitLockerReadyCount = @($rows | Where-Object BitLockerAvailable).Count
            LoadedAt = [DateTimeOffset]::Now
        }
    }
    catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties['ResponseStatusCode']) { $statusCode = [int]$_.Exception.ResponseStatusCode }
        $errorCode = if ($_.Exception.PSObject.Properties['ErrorCode']) { [string]$_.Exception.ErrorCode } else { [string]$_.FullyQualifiedErrorId }
        [pscustomobject]@{ Kind = 'Error'; ErrorCode = $errorCode; Message = [string]$_.Exception.Message; StatusCode = $statusCode; Stage = $stage }
    }
}
'@

$credentialOperationScript = @'
param($DeviceId, $CoreModulePath)
& {
    $ErrorActionPreference = 'Stop'
    Import-Module $CoreModulePath -Force
    $response = $null
    $credential = $null
    $password = $null

    try {
        $parsedId = [Guid]::Empty
        if (-not [Guid]::TryParse($DeviceId, [ref]$parsedId) -or $parsedId -eq [Guid]::Empty) {
            throw 'The selected computer does not have a usable Microsoft Entra device ID.'
        }

        $escapedId = [Uri]::EscapeDataString($parsedId.ToString())
        $uri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/$escapedId`?`$select=id,deviceName,lastBackupDateTime,refreshDateTime,credentials"
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        if ($null -ne $response.PSObject.Properties['value'] -and $null -ne $response.value) {
            $response = $response.value
        }

        if ([guid]$response.id -ne $parsedId) {
            throw 'Microsoft Graph returned a LAPS credential for a different device.'
        }

        $credential = Select-CurrentLapsCredential -Credentials @($response.credentials)
        if ($null -eq $credential) {
            [pscustomobject]@{ Kind = 'Error'; ErrorCode = 'NoCredential'; Message = 'No current LAPS credential was returned.'; StatusCode = 404 }
            return
        }

        $password = $null
        try {
            $password = ConvertFrom-LapsPasswordBase64 -PasswordBase64 ([string]$credential.passwordBase64)
        }
        finally {
            $credential.passwordBase64 = $null
        }

        [pscustomobject]@{
            Kind = 'CredentialResult'
            DeviceId = $parsedId.ToString()
            DeviceName = [string]$response.deviceName
            AccountName = [string]$credential.accountName
            AccountSid = [string]$credential.accountSid
            BackupDateTime = [DateTimeOffset]$credential.backupDateTime
            Password = $password
        }
    }
    catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties['ResponseStatusCode']) { $statusCode = [int]$_.Exception.ResponseStatusCode }
        $errorCode = if ([string]$_.Exception.Message -match '(?i)LAPS password payload') {
            'PasswordDecodeFailed'
        }
        elseif ($_.Exception.PSObject.Properties['ErrorCode']) {
            [string]$_.Exception.ErrorCode
        }
        else {
            [string]$_.FullyQualifiedErrorId
        }
        [pscustomobject]@{ Kind = 'Error'; ErrorCode = $errorCode; Message = [string]$_.Exception.Message; StatusCode = $statusCode }
    }
    finally {
        if ($null -ne $response -and $null -ne $response.PSObject.Properties['credentials']) {
            foreach ($item in @($response.credentials)) {
                if ($null -ne $item -and $null -ne $item.PSObject.Properties['passwordBase64']) { $item.passwordBase64 = $null }
            }
        }
        $password = $null
        $credential = $null
        $response = $null
    }
}
'@

$bitLockerKeyOperationScript = @'
param($DeviceId, $RecoveryKeyId, $CoreModulePath)
& {
    $ErrorActionPreference = 'Stop'
    Import-Module $CoreModulePath -Force
    $response = $null
    $recoveryKey = $null

    try {
        $parsedDeviceId = [Guid]::Empty
        $parsedKeyId = [Guid]::Empty
        if (-not [Guid]::TryParse($DeviceId, [ref]$parsedDeviceId) -or $parsedDeviceId -eq [Guid]::Empty) {
            throw 'The selected computer does not have a usable Microsoft Entra device ID.'
        }
        if (-not [Guid]::TryParse($RecoveryKeyId, [ref]$parsedKeyId) -or $parsedKeyId -eq [Guid]::Empty) {
            throw 'The selected BitLocker recovery-key record is invalid.'
        }

        $escapedKeyId = [Uri]::EscapeDataString($parsedKeyId.ToString())
        $uri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/$escapedKeyId`?`$select=id,key,deviceId,createdDateTime,volumeType"
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
        if ([guid]$response.id -ne $parsedKeyId) {
            throw 'Microsoft Graph returned a different BitLocker recovery-key record.'
        }
        if (-not [string]::Equals([string]$response.deviceId, $parsedDeviceId.ToString(), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Microsoft Graph returned a BitLocker key for a different device.'
        }

        $recoveryKey = ([string]$response.key).Trim()
        if (-not (Test-BitLockerRecoveryKey -Value $recoveryKey)) {
            throw 'Microsoft Graph did not return a valid 48-digit BitLocker recovery key.'
        }

        [pscustomobject]@{
            Kind = 'BitLockerKeyResult'
            DeviceId = $parsedDeviceId.ToString()
            RecoveryKeyId = $parsedKeyId.ToString()
            CreatedDateTime = [DateTimeOffset]$response.createdDateTime
            VolumeType = [string]$response.volumeType
            RecoveryKey = $recoveryKey
        }
    }
    catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties['ResponseStatusCode']) { $statusCode = [int]$_.Exception.ResponseStatusCode }
        $errorCode = if ([string]$_.Exception.Message -match '(?i)48-digit BitLocker') {
            'RecoveryKeyValidationFailed'
        }
        elseif ($_.Exception.PSObject.Properties['ErrorCode']) {
            [string]$_.Exception.ErrorCode
        }
        else {
            [string]$_.FullyQualifiedErrorId
        }
        [pscustomobject]@{ Kind = 'Error'; ErrorCode = $errorCode; Message = [string]$_.Exception.Message; StatusCode = $statusCode }
    }
    finally {
        if ($null -ne $response -and $null -ne $response.PSObject.Properties['key']) { $response.key = $null }
        $recoveryKey = $null
        $response = $null
    }
}
'@

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

function Set-AppStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [switch]$Busy
    )

    $FooterStatusText.Text = $Message
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
    $ToastText.Text = $Message
    $ToastBorder.Visibility = 'Visible'
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

    if ($null -ne $script:CurrentCredential) {
        $passwordProperty = $script:CurrentCredential.PSObject.Properties['Password']
        if ($null -ne $passwordProperty) {
            $passwordProperty.Value = $null
        }
    }

    $script:CurrentCredential = $null
    $script:CurrentCredentialDeviceId = $null
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
    $script:CurrentBitLockerKeyId = $null
    $script:CurrentBitLockerDeviceId = $null
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
        if ($script:ClipboardKind -eq 'LAPS') {
            if ($PasswordCountdownText.Text -ne $message) {
                Set-PasswordStatus -Message $message -DotColor '#15803D' -TextColor '#166534'
            }
            return $true
        }
        if ($script:ClipboardKind -eq 'BitLocker') {
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

    if ($PasswordText.Text -eq '••••••••••••••••' -and $PasswordCountdownText.Text -ne 'Password remains hidden until requested') {
        Set-PasswordStatus -Message 'Password remains hidden until requested'
    }
    if ($BitLockerKeyText.Text -like '••••••-*' -and $BitLockerCountdownText.Text -ne 'Recovery key remains hidden until requested') {
        Set-BitLockerStatus -Message 'Recovery key remains hidden until requested'
    }
    return $false
}

function Open-DeviceSignInPage {
    Start-Process -FilePath 'rundll32.exe' -ArgumentList 'url.dll,FileProtocolHandler', '"https://login.microsoft.com/device"' | Out-Null
}

function Copy-SelectedDeviceDetails {
    $selected = Get-SelectedDevice
    # A late recovery Copy must never replace the metadata the operator just copied.
    if ($null -eq $selected -or $null -ne $script:CurrentOperation -or
        $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask) { return }

    try {
        $text = Format-DeviceDetails -Device $selected
        [M365Workbench.Security.SecureClipboard]::SetSensitiveText($text, ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle)
        # Commit tracking only after a successful write, including when a secret was copied before it.
        $script:ClipboardClearAt = (Get-SensitiveClockNow).AddSeconds([int]$settings.ClipboardClearSeconds)
        $script:ClipboardDeviceId = $null
        $script:ClipboardKind = 'DeviceDetails'
        $script:ClipboardRecoveryKeyId = $null
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
        Start-Process -FilePath 'rundll32.exe' -ArgumentList 'url.dll,FileProtocolHandler', $uri.AbsoluteUri | Out-Null
        Show-Toast -Message "Opening $Portal for $([string]$selected.DeviceName)." -Kind Success
    }
    catch {
        Show-Toast -Message "Windows could not open the $Portal admin center." -Kind Error
    }
}

function Clear-AuthenticationClipboard {
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
    $AuthOverlayStatus.Text = "Code copied. Sign in as $($settings.ExpectedAccount)."
    $CopyCodeButton.IsEnabled = $true
    $OpenSignInButton.IsEnabled = $true

    try {
        [M365Workbench.Security.SecureClipboard]::SetSensitiveText($Code, ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle)
    }
    catch {
        $AuthOverlayStatus.Text = 'The code is shown above. Copy it manually if needed.'
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
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ScriptText,
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
        $null = $script:GraphPowerShell.AddScript($ScriptText)
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
    $CopyPasswordButton.IsEnabled = $lapsAvailable
    $RevealPasswordButton.IsEnabled = $lapsAvailable
    $CopyPasswordButtonText.Text = 'Copy password'
    $CopyRecoveryKeyButton.IsEnabled = $bitLockerAvailable
    $RevealRecoveryKeyButton.IsEnabled = $bitLockerAvailable
    $CopyRecoveryKeyButtonText.Text = 'Copy recovery key'
    $BitLockerKeySelector.IsEnabled = $null -ne $selected -and [bool]$selected.BitLockerAvailable -and @($selected.BitLockerKeys).Count -gt 1
    $RefreshButton.IsEnabled = $true
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
    $CopyPasswordButton.IsEnabled = $false
    $RevealPasswordButton.IsEnabled = $false
    $CopyRecoveryKeyButton.IsEnabled = $false
    $RevealRecoveryKeyButton.IsEnabled = $false
    $BitLockerKeySelector.IsEnabled = $false
    $RefreshButton.IsEnabled = $false
    $SignInButton.IsEnabled = $false
}

function Get-SecretVerificationSnapshot {
    [Threading.Monitor]::Enter($script:VerificationStateLock)
    try {
        $timestampNow = [Diagnostics.Stopwatch]::GetTimestamp()
        $verifiedUntil = if ($script:SecretVerifiedDeadlineTimestamp -gt $timestampNow) {
            $remainingSeconds = [double]($script:SecretVerifiedDeadlineTimestamp - $timestampNow) / [double][Diagnostics.Stopwatch]::Frequency
            [DateTimeOffset]::Now.AddSeconds($remainingSeconds)
        }
        else {
            [DateTimeOffset]::MinValue
        }
        $recentAuthenticationUntil = if ($script:RecentInteractiveAuthenticationDeadlineTimestamp -gt $timestampNow) {
            $remainingSeconds = [double]($script:RecentInteractiveAuthenticationDeadlineTimestamp - $timestampNow) / [double][Diagnostics.Stopwatch]::Frequency
            [DateTimeOffset]::Now.AddSeconds($remainingSeconds)
        }
        else {
            [DateTimeOffset]::MinValue
        }
        return [pscustomobject]@{
            Generation = $script:SecretVerificationGeneration
            VerifiedUntil = $verifiedUntil
            RecentInteractiveAuthenticationUntil = $recentAuthenticationUntil
        }
    }
    finally {
        [Threading.Monitor]::Exit($script:VerificationStateLock)
    }
}

function Set-SecretVerificationGranted {
    param([Parameter(Mandatory)][int]$ExpectedGeneration)

    [Threading.Monitor]::Enter($script:VerificationStateLock)
    try {
        if ($script:SecretVerificationGeneration -ne $ExpectedGeneration) {
            return $false
        }
        $script:SecretVerifiedUntil = [DateTimeOffset]::Now.AddSeconds($secretVerificationSeconds)
        $script:SecretVerifiedDeadlineTimestamp = [Diagnostics.Stopwatch]::GetTimestamp() + ([int64]$secretVerificationSeconds * [Diagnostics.Stopwatch]::Frequency)
        return $true
    }
    finally {
        [Threading.Monitor]::Exit($script:VerificationStateLock)
    }
}

function Set-RecentInteractiveAuthentication {
    param([Parameter(Mandatory)][int]$ExpectedGeneration)

    [Threading.Monitor]::Enter($script:VerificationStateLock)
    try {
        if ($script:SecretVerificationGeneration -ne $ExpectedGeneration) {
            return $false
        }
        $script:RecentInteractiveAuthenticationUntil = [DateTimeOffset]::Now.AddSeconds($secretVerificationSeconds)
        $script:RecentInteractiveAuthenticationDeadlineTimestamp = [Diagnostics.Stopwatch]::GetTimestamp() + ([int64]$secretVerificationSeconds * [Diagnostics.Stopwatch]::Frequency)
        return $true
    }
    finally {
        [Threading.Monitor]::Exit($script:VerificationStateLock)
    }
}

function Use-RecentInteractiveAuthentication {
    param([Parameter(Mandatory)][int]$ExpectedGeneration)

    [Threading.Monitor]::Enter($script:VerificationStateLock)
    try {
        if ($script:SecretVerificationGeneration -ne $ExpectedGeneration -or
            [Diagnostics.Stopwatch]::GetTimestamp() -ge $script:RecentInteractiveAuthenticationDeadlineTimestamp) {
            return $false
        }
        $script:SecretVerifiedUntil = $script:RecentInteractiveAuthenticationUntil
        $script:SecretVerifiedDeadlineTimestamp = $script:RecentInteractiveAuthenticationDeadlineTimestamp
        return $true
    }
    finally {
        [Threading.Monitor]::Exit($script:VerificationStateLock)
    }
}

function Test-SecretVerificationGeneration {
    param([AllowNull()][object]$Generation)

    [Threading.Monitor]::Enter($script:VerificationStateLock)
    try {
        if ($null -eq $Generation -or [int]$Generation -ne $script:SecretVerificationGeneration) {
            return $false
        }
        if ($secretVerificationMode -eq 'Disabled') {
            return $true
        }
        return [Diagnostics.Stopwatch]::GetTimestamp() -lt $script:SecretVerifiedDeadlineTimestamp
    }
    finally {
        [Threading.Monitor]::Exit($script:VerificationStateLock)
    }
}

function Clear-SecretVerificationState {
    [Threading.Monitor]::Enter($script:VerificationStateLock)
    try {
        $script:SecretVerifiedUntil = [DateTimeOffset]::MinValue
        $script:RecentInteractiveAuthenticationUntil = [DateTimeOffset]::MinValue
        $script:SecretVerifiedDeadlineTimestamp = [int64]0
        $script:RecentInteractiveAuthenticationDeadlineTimestamp = [int64]0
        $script:SecretVerificationGeneration++
    }
    finally {
        [Threading.Monitor]::Exit($script:VerificationStateLock)
    }
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
    $AuthOverlayStatus.Text = 'Canceling verification...'
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
    $verificationSnapshot = Get-SecretVerificationSnapshot
    if ([int]$script:PendingSecretRequest.VerificationGeneration -ne [int]$verificationSnapshot.Generation) {
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
    $AuthOverlayStatus.Text = 'Preparing verification...'
    $CopyCodeButton.IsEnabled = $false
    $OpenSignInButton.IsEnabled = $false
    $CancelVerificationButton.Visibility = 'Visible'
    $CancelVerificationButton.IsEnabled = $true
    $script:LastDeviceCode = $null
    $script:SignInPageOpenedForCode = $null
    Set-AppStatus -Message 'Waiting for Microsoft verification...' -Busy
    $null = $CancelVerificationButton.Focus()

    $powerShellExecutable = Join-Path $PSHOME 'pwsh.exe'
    $started = Start-GraphOperation -Name 'MicrosoftVerification' -ScriptText $microsoftVerificationOperationScript -Arguments @(
        $settings.TenantId,
        $settings.TenantObjectId,
        $settings.ExpectedAccount,
        [string[]]$settings.RequiredScopes,
        $coreModulePath,
        $settings.GraphModuleMinimumVersion,
        $powerShellExecutable,
        $nonce,
        $microsoftVerificationChildScript,
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
    $verificationSnapshot = Get-SecretVerificationSnapshot
    if ($expectedGeneration -ne [int]$verificationSnapshot.Generation) {
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

    $decision = Get-SecretVerificationDecision `
        -Mode $secretVerificationMode `
        -LocalResult $localResult `
        -VerifiedUntil $verificationSnapshot.VerifiedUntil

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

    $verificationSnapshot = Get-SecretVerificationSnapshot
    $script:RecoveryRequestCanceled = $false
    $script:PendingSecretRequest = [pscustomobject]@{
        Kind          = $Kind
        Action        = $Action
        DeviceId      = [string]$selected.EntraDeviceId
        RecoveryKeyId = if ($null -eq $selectedKey) { $null } else { [string]$selectedKey.Id }
        VerificationGeneration = [int]$verificationSnapshot.Generation
    }
    Set-SecretActionBusy -Kind $Kind

    $decision = Get-SecretVerificationDecision `
        -Mode $secretVerificationMode `
        -VerifiedUntil $verificationSnapshot.VerifiedUntil
    if ($decision -in @('Grant', 'Bypass')) {
        Resume-PendingSecretRequest
        return
    }

    Start-LocalSecretVerification
}

function Start-Authentication {
    if ($null -ne $script:CurrentOperation -or $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask) {
        return
    }

    $authenticationSnapshot = Get-SecretVerificationSnapshot
    $script:AuthenticationVerificationGeneration = [int]$authenticationSnapshot.Generation

    $AuthOverlayTitle.Text = 'Microsoft sign-in'
    $AuthOverlaySubtitle.Text = 'Connect to load devices'
    $AuthOverlayInstruction.Text = "Use the configured administrator account and follow your organization's sign-in requirements."
    $AuthOverlayFooter.Text = 'Intune Device Workbench continues automatically after sign-in.'
    $AuthOverlay.Visibility = 'Visible'
    $DeviceCodeText.Text = 'Waiting for Microsoft...'
    $AuthOverlayStatus.Text = 'Checking for a reusable secure sign-in...'
    $CopyCodeButton.IsEnabled = $false
    $OpenSignInButton.IsEnabled = $false
    $CancelVerificationButton.Visibility = 'Collapsed'
    $script:LastDeviceCode = $null
    $script:SignInPageOpenedForCode = $null
    $script:AuthenticationDeviceCodeObserved = $false
    $null = $AuthOverlay.Focus()
    Set-AppStatus -Message 'Connecting securely to Microsoft Graph...' -Busy
    Set-AuthenticationDisplay -SignedIn $false -Text 'Connecting...'

    $authenticationStarted = Start-GraphOperation -Name 'Authenticate' -ScriptText $authOperationScript -Arguments @(
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
    if (-not $script:IsSignedIn -or $null -ne $script:CurrentOperation -or $null -ne $script:PendingSecretRequest -or $null -ne $script:LocalVerificationTask) {
        return
    }

    Set-InventoryLoadingState
    $null = Start-GraphOperation -Name 'Inventory' -ScriptText $inventoryOperationScript -Arguments @($coreModulePath)
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

function Refresh-DeviceFilter {
    if ($null -eq $script:DeviceView) {
        return
    }

    # Normalize before refreshing/counting. Unchecking fires a synchronous nested
    # refresh; doing it inside Update-FilteredCount lets the outer call overwrite
    # the correct count and empty-state visibility with its stale snapshot.
    if ($script:InventoryCounts.EntraOnly -eq 0 -and $EntraOnlyCheckBox.IsChecked -eq $true) {
        $EntraOnlyCheckBox.IsChecked = $false
    }
    # Snapshot controls once per refresh, not once for every inventory row.
    $script:FilterQuery = $SearchBox.Text.Trim().ToLowerInvariant()
    $script:FilterReadyOnly = $OnlyReadyCheckBox.IsChecked -eq $true
    $script:FilterEntraOnly = $EntraOnlyCheckBox.IsChecked -eq $true
    if ($null -eq $script:DeviceView.Filter) {
        $script:DeviceView.Filter = [Predicate[object]]{
            param($item)
            if ($null -eq $item) { return $false }
            return (-not $script:FilterReadyOnly -or [bool]$item.RecoveryAvailable) -and
                (-not $script:FilterEntraOnly -or [bool]$item.IsEntraOnly) -and
                ($script:FilterQuery.Length -eq 0 -or ([string]$item.SearchText).Contains($script:FilterQuery))
        }
    }
    else {
        $script:DeviceView.Refresh()
    }
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
            return "$field`:$($id.ToString('D'))"
        }
    }
    return $null
}

function Set-DeviceInventory {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Devices)

    $previousSelection = Get-SelectedDevice
    $previousDeviceId = Get-InventorySelectionId -Device $previousSelection
    $previousKeyId = if ($null -eq $BitLockerKeySelector.SelectedItem) { $null } else { [string]$BitLockerKeySelector.SelectedItem.Id }
    $sorts = @(if ($null -ne $script:DeviceView) { $script:DeviceView.SortDescriptions })
    $script:AllDevices = @($Devices)
    $script:InventoryCounts = @{ Laps=0; BitLocker=0; EntraOnly=0 }
    $collection = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($device in $script:AllDevices) {
        $collection.Add($device)
        if ($device.LapsAvailable) { $script:InventoryCounts.Laps++ }
        if ($device.BitLockerAvailable) { $script:InventoryCounts.BitLocker++ }
        if ($device.IsEntraOnly) { $script:InventoryCounts.EntraOnly++ }
    }

    $DeviceGrid.ItemsSource = $collection
    $script:DeviceView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($collection)
    if ($sorts.Count -gt 0) {
        $defer = $script:DeviceView.DeferRefresh()
        try { foreach ($sort in $sorts) { $script:DeviceView.SortDescriptions.Add($sort) } }
        finally { $defer.Dispose() }
        foreach ($column in $DeviceGrid.Columns) {
            $sort = $sorts | Where-Object PropertyName -eq $column.SortMemberPath | Select-Object -First 1
            $column.SortDirection = if ($null -eq $sort) { $null } else { $sort.Direction }
        }
    }
    Refresh-DeviceFilter
    if (-not $script:DeviceView.IsEmpty) {
        $selection = $null
        $sameDevice = $false
        if (-not [string]::IsNullOrWhiteSpace($previousDeviceId)) {
            $selectionField, $selectionValue = $previousDeviceId -split ':', 2
            foreach ($candidate in $script:DeviceView) {
                $property = $candidate.PSObject.Properties[$selectionField]
                if ($null -eq $property) { continue }
                $candidateId = [string]$property.Value
                if ($candidateId.Length -ne 36) {
                    $parsed = [Guid]::Empty
                    if ([Guid]::TryParse($candidateId, [ref]$parsed)) { $candidateId = $parsed.ToString('D') }
                }
                if ([string]::Equals($candidateId, $selectionValue, [StringComparison]::OrdinalIgnoreCase)) {
                    $selection = $candidate
                    $sameDevice = $true
                    break
                }
            }
        }
        if ($null -eq $selection) {
            $selection = $script:DeviceView.GetItemAt(0)
        }
        $DeviceGrid.SelectedItem = $selection
        if ($sameDevice -and -not [string]::IsNullOrWhiteSpace($previousKeyId)) {
            foreach ($key in $BitLockerKeySelector.Items) {
                if ([string]::Equals([string]$key.Id, $previousKeyId, [StringComparison]::OrdinalIgnoreCase)) {
                    $BitLockerKeySelector.SelectedItem = $key
                    break
                }
            }
        }
        $DeviceGrid.ScrollIntoView($DeviceGrid.SelectedItem)
    }
    else {
        $DeviceGrid.SelectedItem = $null
        Update-DetailPanel
    }
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
    $script:CurrentCredentialDeviceId = [string]$Credential.DeviceId
    $script:CredentialExpiresAt = (Get-SensitiveClockNow).AddSeconds([int]$settings.RevealSeconds)
    $AccountNameText.Text = [string]$Credential.AccountName
    $CopyAccountButton.IsEnabled = $true
    $CopyPasswordButtonText.Text = 'Copy password'

    if ($Action -eq 'Copy') {
        try {
            [M365Workbench.Security.SecureClipboard]::SetSensitiveText([string]$Credential.Password, ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle)
            $script:ClipboardClearAt = (Get-SensitiveClockNow).AddSeconds([int]$settings.ClipboardClearSeconds)
            $script:ClipboardDeviceId = [string]$selected.EntraDeviceId
            $script:ClipboardKind = 'LAPS'
            $script:ClipboardRecoveryKeyId = $null
            Set-PasswordStatus -Message "Copied securely • clipboard clears in $($settings.ClipboardClearSeconds) seconds" -DotColor '#15803D' -TextColor '#166534'
            Show-Toast -Message "Password copied for $($selected.DeviceName)." -Kind Success
        }
        catch {
            Show-Toast -Message 'The clipboard is busy. Nothing was copied; try again.' -Kind Error
        }
    }
    else {
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

    if ($Action -eq 'Reveal' -and $PasswordText.Text -ne '••••••••••••••••') {
        Clear-SecretDisplay
        return
    }

    if ($DemoMode) {
        $demoCredential = [pscustomobject]@{
            Kind = 'CredentialResult'
            DeviceId = [string]$selected.EntraDeviceId
            DeviceName = [string]$selected.DeviceName
            AccountName = 'DemoLapsAdmin'
            AccountSid = 'S-1-5-21-DEMO-500'
            BackupDateTime = [DateTimeOffset]::Now
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
        [string]::Equals($script:CurrentCredentialDeviceId, [string]$selected.EntraDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
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
    $null = Start-GraphOperation -Name 'Credential' -ScriptText $credentialOperationScript -Arguments @([string]$selected.EntraDeviceId, $coreModulePath)
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
    $script:CurrentBitLockerDeviceId = [string]$KeyResult.DeviceId
    $script:CurrentBitLockerKeyId = [string]$KeyResult.RecoveryKeyId
    $script:BitLockerExpiresAt = (Get-SensitiveClockNow).AddSeconds([int]$settings.RevealSeconds)
    $CopyRecoveryKeyButtonText.Text = 'Copy recovery key'

    if ($Action -eq 'Copy') {
        try {
            [M365Workbench.Security.SecureClipboard]::SetSensitiveText([string]$KeyResult.RecoveryKey, ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle)
            $script:ClipboardClearAt = (Get-SensitiveClockNow).AddSeconds([int]$settings.ClipboardClearSeconds)
            $script:ClipboardDeviceId = [string]$selected.EntraDeviceId
            $script:ClipboardKind = 'BitLocker'
            $script:ClipboardRecoveryKeyId = [string]$selectedKey.Id
            Set-BitLockerStatus -Message "Copied securely • clipboard clears in $($settings.ClipboardClearSeconds) seconds" -DotColor '#15803D' -TextColor '#166534'
            Show-Toast -Message "BitLocker recovery key copied for $($selected.DeviceName)." -Kind Success
        }
        catch {
            Show-Toast -Message 'The clipboard is busy. Nothing was copied; try again.' -Kind Error
        }
    }
    else {
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

    if ($Action -eq 'Reveal' -and $BitLockerKeyText.Text -notlike '••••••-*') {
        Clear-SecretDisplay
        Update-BitLockerSelection
        return
    }

    if ($DemoMode) {
        $demoKey = [pscustomobject]@{
            Kind = 'BitLockerKeyResult'
            DeviceId = [string]$selected.EntraDeviceId
            RecoveryKeyId = [string]$selectedKey.Id
            CreatedDateTime = [DateTimeOffset]$selectedKey.CreatedDateTime
            VolumeType = [string]$selectedKey.VolumeType
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
        [string]::Equals($script:CurrentBitLockerDeviceId, [string]$selected.EntraDeviceId, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($script:CurrentBitLockerKeyId, [string]$selectedKey.Id, [StringComparison]::OrdinalIgnoreCase) -and
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
    $null = Start-GraphOperation -Name 'BitLockerKey' -ScriptText $bitLockerKeyOperationScript -Arguments @(
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

    try {
        if ($null -ne $Operation.StopAsyncResult) { $script:GraphPowerShell.EndStop($Operation.StopAsyncResult) }
        if ($null -ne $Operation.AsyncResult) { $null = $script:GraphPowerShell.EndInvoke($Operation.AsyncResult) }
    }
    catch {
        # A sanitized error is produced below from the PowerShell error stream.
    }

    $result = Get-OperationResultObject -Operation $Operation
    if ($null -eq $result) {
        $errorText = if ($script:GraphPowerShell.Streams.Error.Count -gt 0) { [string]$script:GraphPowerShell.Streams.Error[0].Exception.Message } else { 'The background operation did not return a result.' }
        $result = [pscustomobject]@{ Kind = 'Error'; ErrorCode = 'OperationFailed'; Message = $errorText; StatusCode = $null }
    }

    $operationName = [string]$Operation.Name
    $expectedKind = switch ($operationName) {
        'Authenticate' { 'AuthResult' }
        'Inventory' { 'InventoryResult' }
        'Credential' { 'CredentialResult' }
        'BitLockerKey' { 'BitLockerKeyResult' }
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

    if ($operationName -eq 'Inventory' -and $Operation.CancellationRequested) {
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
        $script:LastDeviceCode = $null
        $script:SignInPageOpenedForCode = $null
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
        $friendly = Get-FriendlyLapsErrorMessage -ErrorCode ([string]$result.ErrorCode) -Message ([string]$result.Message) -StatusCode $statusCode
        $stageProperty = $result.PSObject.Properties['Stage']
        if ($operationName -eq 'Inventory' -and $null -ne $stageProperty -and -not [string]::IsNullOrWhiteSpace([string]$stageProperty.Value)) {
            $friendly = "$friendly Failed while loading $([string]$stageProperty.Value)."
        }
        if ($operationName -eq 'Authenticate') {
            $script:LastDeviceCode = $null
            $script:SignInPageOpenedForCode = $null
            $AuthOverlay.Visibility = 'Collapsed'
            $script:AuthenticationVerificationGeneration = $null
        }
        if ($operationName -eq 'Authenticate' -or $statusCode -eq 401) {
            Clear-AuthenticationClipboard
            Clear-SecretVerificationState
            Clear-SecretDisplay
            Set-AuthenticationDisplay -SignedIn $false -Text 'Sign-in required'
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
            $script:LastDeviceCode = $null
            $script:SignInPageOpenedForCode = $null
            $AuthOverlay.Visibility = 'Collapsed'
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
            if (-not $script:RecoveryRequestCanceled -and (Test-SecretVerificationGeneration -Generation $verificationGeneration)) {
                Complete-CredentialAction -Action $action -Credential $result
            }
            else {
                if ($null -ne $result.PSObject.Properties['Password']) {
                    $result.Password = $null
                }
                Restore-SecretActionControls
                Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
                Show-Toast -Message $(if ($script:RecoveryRequestCanceled) { 'Recovery action canceled. No password was exposed.' } else { 'Verification expired or the Windows session changed. No password was exposed.' }) -Kind Info
                Set-RecoveryActionFocus -Kind LAPS -Action $action
            }
        }
        'BitLockerKey' {
            $action = $script:PendingBitLockerAction
            $verificationGeneration = $script:PendingBitLockerVerificationGeneration
            $script:PendingBitLockerAction = $null
            $script:PendingBitLockerVerificationGeneration = $null
            if (-not $script:RecoveryRequestCanceled -and (Test-SecretVerificationGeneration -Generation $verificationGeneration)) {
                Complete-BitLockerAction -Action $action -KeyResult $result
            }
            else {
                if ($null -ne $result.PSObject.Properties['RecoveryKey']) {
                    $result.RecoveryKey = $null
                }
                Restore-SecretActionControls
                Set-AppStatus -Message "Ready — signed in as $($settings.ExpectedAccount)"
                Show-Toast -Message $(if ($script:RecoveryRequestCanceled) { 'Recovery action canceled. No recovery key was exposed.' } else { 'Verification expired or the Windows session changed. No recovery key was exposed.' }) -Kind Info
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
    $width = [Math]::Max(1, [int][Math]::Ceiling($window.ActualWidth))
    $height = [Math]::Max(1, [int][Math]::Ceiling($window.ActualHeight))
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
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
    if (-not [string]::IsNullOrWhiteSpace($AccountNameText.Text) -and $AccountNameText.Text -ne 'Retrieved with password') {
        try {
            [M365Workbench.Security.SecureClipboard]::SetSensitiveText($AccountNameText.Text, ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle)
            $script:ClipboardClearAt = (Get-SensitiveClockNow).AddSeconds(20)
            $script:ClipboardDeviceId = $null
            $script:ClipboardKind = 'Account'
            $script:ClipboardRecoveryKeyId = $null
            if ($PasswordText.Text -eq '••••••••••••••••') {
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
            [M365Workbench.Security.SecureClipboard]::SetSensitiveText($script:LastDeviceCode, ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle)
            $AuthOverlayStatus.Text = 'Code copied. Complete sign-in in the browser.'
        }
        catch { $AuthOverlayStatus.Text = 'Copy the code manually, then continue in the browser.' }
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
        if ($PasswordText.Text -ne '••••••••••••••••' -or $BitLockerKeyText.Text -notlike '••••••-*') {
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
                if ($clipboardKind -eq 'LAPS' -and $PasswordText.Text -eq '••••••••••••••••') {
                    Set-PasswordStatus -Message $message -DotColor '#64748B'
                }
                elseif ($clipboardKind -eq 'BitLocker' -and $BitLockerKeyText.Text -like '••••••-*' -and
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
    elseif ($PasswordText.Text -ne '••••••••••••••••' -and $script:CredentialExpiresAt -ne [DateTimeOffset]::MinValue) {
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
    elseif ($BitLockerKeyText.Text -notlike '••••••-*' -and $script:BitLockerExpiresAt -ne [DateTimeOffset]::MinValue) {
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
            $AuthOverlayStatus.Text = "Code copied. Sign in as $($settings.ExpectedAccount)."
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
