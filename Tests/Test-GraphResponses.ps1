# Runs inside Test-IntuneDeviceWorkbench.ps1. Fresh runspaces match the production
# worker's scope (including its default strict mode); every Graph call is a stub.
& {
    function Invoke-GraphResponseFixture {
        param([string]$OperationName, [string]$Scenario, [int]$StatusCode = 0)
        $operation = Get-OperationFixture $OperationName
        $worker = [PowerShell]::Create()
        try {
            $null = $worker.AddScript({
                param($OperationText, $ModulePath, $Scenario, $StatusCode)
                $script:Calls = [Collections.Generic.List[string]]::new()
                function Invoke-MgGraphRequest {
                    param($Method, $Uri, $OutputType, $ErrorAction, $Body, $ContentType)
                    $script:Calls.Add([string]$Uri)
                    if ($Scenario -eq 'HttpError') {
                        # Invoke-MgGraphRequest exposes Response.StatusCode, not
                        # the ResponseStatusCode property used by generated cmdlets.
                        $failure = [Net.Http.HttpRequestException]::new('Synthetic HTTP failure')
                        $failure | Add-Member -NotePropertyName Response -NotePropertyValue ([Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$StatusCode))
                        throw $failure
                    }
                    if ($Scenario -eq 'ValidInventory') {
                        switch -Wildcard ($Uri) {
                            '*/managedDevices?*' { return ('{"value":[{"id":"11111111-1111-4111-8111-111111111111","azureADDeviceId":"33333333-3333-4333-8333-333333333333","deviceName":"DEMO-DEVICE-VALID","operatingSystem":"Windows"}]}' | ConvertFrom-Json) }
                            '*/$batch' { return ('{"responses":[{"id":"1","status":200,"body":{"value":[{"id":"44444444-4444-4444-8444-444444444444","displayName":"Demo User","userPrincipalName":"demo@contoso.com"}]}}]}' | ConvertFrom-Json) }
                            '*/deviceLocalCredentials?*' { return ('{"value":[{"id":"33333333-3333-4333-8333-333333333333","deviceName":"DEMO-DEVICE-VALID"}]}' | ConvertFrom-Json) }
                            '*/recoveryKeys' { return ('{"value":[{"id":"22222222-2222-4222-8222-222222222222","deviceId":"33333333-3333-4333-8333-333333333333"}]}' | ConvertFrom-Json) }
                            '*/devices?*' { return ('{"value":[{"id":"55555555-5555-4555-8555-555555555555","deviceId":"33333333-3333-4333-8333-333333333333","operatingSystem":"Windows"}]}' | ConvertFrom-Json) }
                            default { throw 'Unexpected fixture request' }
                        }
                    }
                    if ($Scenario -eq 'MalformedLastCollection' -and $script:Calls.Count -eq 4) {
                        return [pscustomobject]@{ unexpected='not a collection' }
                    }
                    if ($script:Calls.Count -eq 1) {
                        switch ($Scenario) {
                            'MissingValue' { return [pscustomobject]@{ '@odata.context'='synthetic' } }
                            'NullValue' { return [pscustomobject]@{ value=$null } }
                            'StringValue' { return [pscustomobject]@{ value='not a collection' } }
                            'ObjectValue' { return [pscustomobject]@{ value=[pscustomobject]@{ id='synthetic' } } }
                            'NullRecord' { return [pscustomobject]@{ value=@($null) } }
                            'StringRecord' { return [pscustomobject]@{ value=@('not a record') } }
                            'MissingRecordId' { return [pscustomobject]@{ value=@([pscustomobject]@{ deviceName='DEMO-DEVICE-INVALID' }) } }
                            'InvalidRecordId' { return [pscustomobject]@{ value=@([pscustomobject]@{ id='invalid'; deviceName='DEMO-DEVICE-INVALID' }) } }
                            'BlankNextLink' { return [pscustomobject]@{ value=@(); '@odata.nextLink'=' ' } }
                            'ArrayNextLink' { return [pscustomobject]@{ value=@(); '@odata.nextLink'=@('https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=synthetic') } }
                            'OtherCollection' { return [pscustomobject]@{ value=@(); '@odata.nextLink'='https://graph.microsoft.com/v1.0/devices?$skiptoken=synthetic' } }
                            'RecoveryRecord' { return [pscustomobject]@{ value=@(); '@odata.nextLink'='https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/22222222-2222-4222-8222-222222222222?$select=key' } }
                            'EmptyPageWithNext' { return [pscustomobject]@{ value=@(); '@odata.nextLink'='https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=A%2BB%3D%3D' } }
                        }
                    }
                    if ($Scenario -eq 'EmptyPageWithNext' -and $script:Calls.Count -eq 2) {
                        return [pscustomobject]@{ value=@([pscustomobject]@{
                            id='11111111-1111-4111-8111-111111111111'; deviceName='DEMO-DEVICE-PAGED'; operatingSystem='macOS'
                        }) }
                    }
                    return [pscustomobject]@{ value=@() }
                }
                [object[]]$arguments = switch ($OperationText) {
                    { $_ -match '^param\(\$DeviceId, \$RecoveryKeyId' } { @('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', $ModulePath); break }
                    { $_ -match '^param\(\$DeviceId,' } { @('11111111-1111-4111-8111-111111111111', $ModulePath); break }
                    default { @($ModulePath) }
                }
                $results = @(& ([scriptblock]::Create($OperationText)) @arguments)
                [pscustomobject]@{ Results=$results; Calls=$script:Calls.ToArray() }
            }).AddArgument($operation.ToString()).AddArgument($modulePath).AddArgument($Scenario).AddArgument($StatusCode)
            $output = @($worker.Invoke())
            if ($worker.HadErrors) { throw 'Graph-response fixture failed outside the operation result path.' }
            return $output[0]
        }
        finally { $worker.Dispose() }
    }

    foreach ($scenario in @('MissingValue', 'NullValue', 'StringValue', 'ObjectValue', 'NullRecord', 'StringRecord', 'MissingRecordId', 'InvalidRecordId', 'BlankNextLink', 'ArrayNextLink', 'OtherCollection', 'RecoveryRecord')) {
        $fixture = Invoke-GraphResponseFixture 'inventoryOperationScript' $scenario
        Assert-True -Condition ($fixture.Results.Count -eq 1 -and $fixture.Results[0].Kind -eq 'Error' -and $fixture.Calls.Count -eq 1) -Name "Inventory rejects $scenario without following another request or publishing incomplete data"
    }
    $fixture = Invoke-GraphResponseFixture 'inventoryOperationScript' 'EmptyPageWithNext'
    Assert-True -Condition ($fixture.Results.Count -eq 1 -and $fixture.Results[0].Kind -eq 'InventoryResult' -and $fixture.Calls.Count -eq 5 -and $fixture.Calls[1] -ceq 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=A%2BB%3D%3D') -Name 'An empty inventory page still follows the complete opaque nextLink unchanged'
    $fixture = Invoke-GraphResponseFixture 'inventoryOperationScript' 'MalformedLastCollection'
    Assert-True -Condition ($fixture.Results.Count -eq 1 -and $fixture.Results[0].Kind -eq 'Error' -and $fixture.Results[0].Stage -eq 'Entra device inventory' -and $fixture.Calls.Count -eq 4) -Name 'A malformed final collection cannot publish the earlier inventory collections'
    $fixture = Invoke-GraphResponseFixture 'inventoryOperationScript' 'ValidInventory'
    $rows = @($fixture.Results[0].Devices)
    Assert-True -Condition ($fixture.Results.Count -eq 1 -and $fixture.Results[0].Kind -eq 'InventoryResult' -and $fixture.Calls.Count -eq 5 -and $rows.Count -eq 1 -and $rows[0].PrimaryUser -eq 'Demo User' -and $rows[0].LapsAvailable -and $rows[0].BitLockerKeyCount -eq 1) -Name 'Valid JSON collections still merge one device with its actual primary user and recovery metadata'

    foreach ($operationName in @('inventoryOperationScript', 'credentialOperationScript', 'bitLockerKeyOperationScript')) {
        foreach ($status in @(401, 403, 404, 429, 503)) {
            $fixture = Invoke-GraphResponseFixture $operationName 'HttpError' $status
            Assert-True -Condition ($fixture.Results.Count -eq 1 -and $fixture.Results[0].Kind -eq 'Error' -and $fixture.Results[0].StatusCode -eq $status -and $fixture.Calls.Count -eq 1) -Name "$operationName preserves the SDK HTTP $status status for UI recovery"
        }
    }

    $batchFailure = [InvalidOperationException]::new('Synthetic batch failure')
    $batchFailure | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue 429
    Assert-True -Condition ((Get-GraphErrorStatusCode $batchFailure) -eq 429) -Name 'Batch subrequest status remains supported'
    $httpFailure = [Net.Http.HttpRequestException]::new('Synthetic transport failure', $null, [Net.HttpStatusCode]::ServiceUnavailable)
    Assert-True -Condition ((Get-GraphErrorStatusCode $httpFailure) -eq 503) -Name 'Standard HTTP exception status remains supported'
    foreach ($invalidStatus in @($null, 0, 99, 600, 'invalid')) {
        $failure = [Exception]::new('Synthetic failure')
        $failure | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue $invalidStatus
        Assert-True -Condition ($null -eq (Get-GraphErrorStatusCode $failure)) -Name 'Missing or invalid HTTP status does not invent a status or hide the original failure'
    }
}
