# F5 is a window-level command and can bypass a disabled Refresh button. Exercise
# the actual key handler and operation entry points; never load the Graph SDK.
& {
    Add-Type -AssemblyName PresentationFramework
    foreach ($name in @('Start-InventoryLoad','Start-Authentication','Set-LiveStatusText')) {
        $node=$mainAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if ($null -ne $node) { . ([scriptblock]::Create($node.Extent.Text)) }
    }
    $xamlNode=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$xaml'},$true)
    $reader=[Xml.XmlNodeReader]::new([xml]$xamlNode.Right.Expression.Value)
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    $namesNode=$mainAst.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$controlNames'},$true)
    . ([scriptblock]::Create($namesNode.Extent.Text))
    foreach ($name in $controlNames) { Set-Variable -Name $name -Value $window.FindName($name) }
    $keyNode=$mainAst.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -eq '$window' -and $n.Member.Value -eq 'Add_PreviewKeyDown'},$true)
    $keyText=$keyNode.Arguments[0].ScriptBlock.Extent.Text
    $keyHandler=[scriptblock]::Create($keyText.Substring(1,$keyText.Length-2))
    $settings=@{TenantId='contoso.onmicrosoft.com';TenantObjectId='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';ExpectedAccount='admin@contoso.com';RequiredScopes=@('Device.Read.All');GraphModuleMinimumVersion='2.38.0'}
    $coreModulePath=$modulePath
    $inventoryOperationScript='unused synthetic boundary'
    $authOperationScript='unused synthetic boundary'
    $script:CurrentOperation=$null
    $script:PendingSecretRequest=$null
    $script:LocalVerificationTask=$null
    function Start-GraphOperation { param($Name,$ScriptText,$Arguments) $script:DemoGraphStarts.Add([string]$Name); return $true }
    function Set-InventoryLoadingState { $script:DemoUiChanges++ }
    function Get-SecretVerificationSnapshot { [pscustomobject]@{Generation=1} }
    function Set-AppStatus { param($Message,[switch]$Busy) $script:DemoUiChanges++ }
    function Set-AuthenticationDisplay { param($SignedIn,$Text) $script:IsSignedIn=$SignedIn; $script:DemoUiChanges++ }
    try {
        foreach ($demo in @($true,$false)) {
            foreach ($signedIn in @($true,$false)) {
                $DemoMode=$demo
                $script:IsSignedIn=$signedIn
                $script:DemoGraphStarts=[Collections.Generic.List[string]]::new()
                $script:DemoUiChanges=0
                $AuthOverlay.Visibility='Collapsed'
                $RefreshButton.IsEnabled=-not $demo
                $event=[pscustomobject]@{Key=[Windows.Input.Key]::F5;KeyboardDevice=[pscustomobject]@{Modifiers=[Windows.Input.ModifierKeys]::None};Handled=$false}
                & $keyHandler $window $event
                if ($demo) {
                    Assert-True -Condition ($script:DemoGraphStarts.Count -eq 0) -Name "Demo F5 never starts Graph work (signed in=$signedIn)"
                    Assert-True -Condition ($script:DemoUiChanges -eq 0 -and $AuthOverlay.Visibility -eq 'Collapsed' -and -not $RefreshButton.IsEnabled) -Name "Demo F5 leaves the offline workspace unchanged (signed in=$signedIn)"
                }
                else {
                    $expected=if($signedIn){'Inventory'}else{'Authenticate'}
                    Assert-True -Condition ($script:DemoGraphStarts.Count -eq 1 -and $script:DemoGraphStarts[0] -eq $expected) -Name "Normal F5 still starts $expected"
                    Assert-True -Condition ($event.Handled -and $script:DemoUiChanges -gt 0) -Name "Normal $expected command retains its UI feedback"
                }
            }
        }
        $DemoMode=$true
        foreach ($entryPoint in @('Start-InventoryLoad','Start-Authentication')) {
            $script:IsSignedIn=$true
            $script:DemoGraphStarts.Clear()
            $script:DemoUiChanges=0
            $AuthOverlay.Visibility='Collapsed'
            & $entryPoint
            Assert-True -Condition ($script:DemoGraphStarts.Count -eq 0 -and $script:DemoUiChanges -eq 0 -and $AuthOverlay.Visibility -eq 'Collapsed') -Name "Demo mode blocks $entryPoint at the operation boundary"
        }
    }
    finally { $window.Close() }
}
