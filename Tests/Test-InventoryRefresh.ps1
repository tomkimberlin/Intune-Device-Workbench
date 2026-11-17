# Exercise production inventory/filter functions with real WPF event dispatch and
# fictional metadata only. No window, authentication, or tenant connection is used.
& {
    Add-Type -AssemblyName PresentationFramework
    foreach ($functionName in @('Update-FilteredCount', 'Get-DeviceFilter', 'Refresh-DeviceFilter', 'Set-DeviceInventory','Get-InventorySelectionId')) {
        $functionAst = $mainAst.Find({ param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    function Get-SelectedDevice { return $DeviceGrid.SelectedItem }
    function Update-DetailPanel { }
    $DeviceGrid = [System.Windows.Controls.DataGrid]::new()
    $DeviceGrid.CanUserAddRows = $false
    $BitLockerKeySelector = [System.Windows.Controls.ComboBox]::new()
    $SearchBox = [System.Windows.Controls.TextBox]::new()
    $OnlyReadyCheckBox = [System.Windows.Controls.CheckBox]::new()
    $EntraOnlyCheckBox = [System.Windows.Controls.CheckBox]::new()
    $DeviceCountText = [System.Windows.Controls.TextBlock]::new()
    $EntraOnlyFilterCount = [System.Windows.Controls.TextBlock]::new()
    $EntraOnlyFilterContainer = [System.Windows.Controls.Border]::new()
    $EmptyStateTitle = [System.Windows.Controls.TextBlock]::new()
    $EmptyStateDescription = [System.Windows.Controls.TextBlock]::new()
    $EmptyState = [System.Windows.Controls.Border]::new()
    $LoadingOverlay = [System.Windows.Controls.Border]::new()
    $RefreshButtonText = [System.Windows.Controls.TextBlock]::new()
    $script:DeviceView = $null
    $OnlyReadyCheckBox.IsChecked = $true
    $EntraOnlyCheckBox.Add_Checked({ Refresh-DeviceFilter })
    $EntraOnlyCheckBox.Add_Unchecked({ Refresh-DeviceFilter })
    $managed = [pscustomobject]@{
        EntraDeviceId='11111111-1111-4111-8111-111111111111'; SearchText='demo-device-alpha'
        IsEntraOnly=$false; RecoveryAvailable=$true; LapsAvailable=$true; BitLockerAvailable=$true
    }
    $entra = [pscustomobject]@{
        EntraDeviceId='22222222-2222-4222-8222-222222222222'; SearchText='demo-device-bravo'
        IsEntraOnly=$true; RecoveryAvailable=$true; LapsAvailable=$true; BitLockerAvailable=$false
    }
    Set-DeviceInventory @($managed, $entra)
    $EntraOnlyCheckBox.IsChecked = $true
    Assert-True -Condition ($script:DeviceView.Count -eq 1 -and $DeviceGrid.SelectedItem -eq $entra) -Name 'Entra-only filter starts with the matching synthetic device selected'
    Set-DeviceInventory @($managed)
    Assert-True -Condition ($EntraOnlyCheckBox.IsChecked -eq $false -and $EntraOnlyFilterContainer.Visibility -eq 'Collapsed') -Name 'Refresh with no Entra-only devices clears and hides the unavailable filter'
    Assert-True -Condition ($script:DeviceView.Count -eq 1 -and $DeviceCountText.Text -like '1 shown*' -and $EmptyState.Visibility -eq 'Collapsed' -and $DeviceGrid.SelectedItem -eq $managed) -Name 'Refresh keeps rows, displayed count, empty overlay, and selection consistent after clearing Entra-only'

    Set-DeviceInventory @($managed, $entra)
    $EntraOnlyCheckBox.IsChecked = $true
    $SearchBox.Text = 'does-not-match'
    Set-DeviceInventory @($managed)
    Assert-True -Condition ($script:DeviceView.Count -eq 0 -and $DeviceCountText.Text -like '0 shown*' -and $EmptyState.Visibility -eq 'Visible' -and $null -eq $DeviceGrid.SelectedItem) -Name 'Clearing Entra-only preserves an independent search and its genuine empty state'

    Set-DeviceInventory -Devices @()
    Assert-True -Condition ($script:DeviceView.IsEmpty -and $script:AllDevices.Count -eq 0 -and $null -eq $DeviceGrid.SelectedItem -and $EmptyState.Visibility -eq 'Visible' -and $EmptyStateTitle.Text -eq 'No Windows computers found' -and $DeviceCountText.Text -like '0 shown*') -Name 'A successful empty inventory replaces old rows with a consistent empty state without throwing'
    $SearchBox.Clear()
    Set-DeviceInventory -Devices @($managed)
    Assert-True -Condition ($script:DeviceView.Count -eq 1 -and $DeviceGrid.SelectedItem -eq $managed -and $EmptyState.Visibility -eq 'Collapsed') -Name 'A later successful inventory recovers from the empty state'

    $column = [System.Windows.Controls.DataGridTextColumn]::new()
    $column.SortMemberPath = 'SearchText'
    $DeviceGrid.Columns.Add($column)
    Set-DeviceInventory @($managed, $entra)
    $script:DeviceView.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('SearchText','Descending'))
    $column.SortDirection = 'Descending'
    Set-DeviceInventory @($managed, $entra)
    Assert-True -Condition ($script:DeviceView.SortDescriptions.Count -eq 1 -and $script:DeviceView.GetItemAt(0) -eq $entra -and $column.SortDirection -eq 'Descending') -Name 'Refresh preserves the chosen sort order and its column arrow'
    Set-DeviceInventory @()
    Set-DeviceInventory @($managed, $entra)
    Assert-True -Condition ($script:DeviceView.GetItemAt(0) -eq $entra -and $script:DeviceView.SortDescriptions.Count -eq 1) -Name 'Sorting survives an empty inventory followed by a successful refresh'
    $script:DeviceView.SortDescriptions.Clear()

    Set-DeviceInventory @($managed,$entra)
    $DeviceGrid.SelectedItem=$managed
    $keysFixture=@([pscustomobject]@{Id='aaaaaaaa-1111-4111-8111-111111111111'},[pscustomobject]@{Id='bbbbbbbb-2222-4222-8222-222222222222'})
    $BitLockerKeySelector.ItemsSource=$keysFixture
    $BitLockerKeySelector.SelectedIndex=1
    $selectionHandler=[System.Windows.Controls.SelectionChangedEventHandler]{
        $BitLockerKeySelector.ItemsSource=@($keysFixture | ForEach-Object { [pscustomobject]@{Id=$_.Id} })
        $BitLockerKeySelector.SelectedIndex=0
    }
    $DeviceGrid.Add_SelectionChanged($selectionHandler)
    Set-DeviceInventory @($managed,$entra)
    Assert-True -Condition ($BitLockerKeySelector.SelectedItem.Id -eq $keysFixture[1].Id) -Name 'Refresh preserves the selected recovery-key record when it remains available for the same device'
    $DeviceGrid.Remove_SelectionChanged($selectionHandler)
    $BitLockerKeySelector.ItemsSource=$null

    $pendingA=[pscustomobject]@{EntraDeviceId='00000000-0000-0000-0000-000000000000';IntuneDeviceId='aaaaaaaa-1111-4111-8111-111111111111';SearchText='demo-device-pending-a';IsEntraOnly=$false;RecoveryAvailable=$false;LapsAvailable=$false;BitLockerAvailable=$false}
    $pendingB=[pscustomobject]@{EntraDeviceId='00000000-0000-0000-0000-000000000000';IntuneDeviceId='bbbbbbbb-2222-4222-8222-222222222222';SearchText='demo-device-pending-b';IsEntraOnly=$false;RecoveryAvailable=$false;LapsAvailable=$false;BitLockerAvailable=$false}
    $OnlyReadyCheckBox.IsChecked=$false
    Set-DeviceInventory @($pendingA,$pendingB)
    $DeviceGrid.SelectedItem=$pendingB
    $selectedDuringRefresh = [Collections.Generic.List[object]]::new()
    $observeSelection = [Windows.Controls.SelectionChangedEventHandler]{
        param($sender, $e)
        foreach ($row in $e.AddedItems) { $selectedDuringRefresh.Add($row) }
    }
    $DeviceGrid.Add_SelectionChanged($observeSelection)
    Set-DeviceInventory @($pendingA,$pendingB)
    $DeviceGrid.Remove_SelectionChanged($observeSelection)
    Assert-True -Condition ($DeviceGrid.SelectedItem -eq $pendingB) -Name 'Selection uses the Intune ID when multiple devices have no valid Entra ID'
    Assert-True -Condition (-not $selectedDuringRefresh.Contains($pendingA)) -Name 'Restoring a selection never briefly selects a different computer'
    Assert-True -Condition ($null -eq $script:DeviceView.Filter) -Name 'An unfiltered inventory skips the per-row search predicate'
    $OnlyReadyCheckBox.IsChecked=$true

    # Measure representative inventory work without a machine-dependent time assertion.
    $SearchBox.Clear()
    $inventoryFixture = @(for ($index=0; $index -lt 5000; $index++) {
        [pscustomobject]@{ EntraDeviceId=('00000000-0000-4000-8000-{0:d12}' -f $index); SearchText=('demo-device-{0:d5}' -f $index); IsEntraOnly=($index % 10 -eq 0); RecoveryAvailable=$true; LapsAvailable=$true; BitLockerAvailable=$true }
    })
    $loadWatch = [Diagnostics.Stopwatch]::StartNew()
    Set-DeviceInventory $inventoryFixture
    $loadWatch.Stop()
    $searchWatch = [Diagnostics.Stopwatch]::StartNew()
    $SearchBox.Text = '  DEMO-DEVICE-04999  '
    Refresh-DeviceFilter
    $searchWatch.Stop()
    Assert-True -Condition ($script:DeviceView.Count -eq 1 -and $DeviceGrid.SelectedItem.SearchText -eq 'demo-device-04999') -Name '5,000-row search normalizes text and selects the correct match'
    Assert-True -Condition ($script:InventoryCounts.Laps -eq 5000 -and $script:InventoryCounts.EntraOnly -eq 500) -Name '5,000-row inventory totals remain correct'
    $previous = $DeviceGrid.SelectedItem.EntraDeviceId
    Set-DeviceInventory $inventoryFixture
    Assert-True -Condition ($DeviceGrid.SelectedItem.EntraDeviceId -eq $previous) -Name 'Inventory refresh preserves a still-visible selected device'
    Write-Host ('PERF  5,000 rows: load {0}ms; search {1}ms' -f $loadWatch.ElapsedMilliseconds,$searchWatch.ElapsedMilliseconds)
}
