Set-StrictMode -Version Latest

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-LapsDateTimeOffset {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }

    try {
        return [DateTimeOffset]$Value
    }
    catch {
        return $null
    }
}

function Test-UsableEntraDeviceId {
    param(
        [AllowNull()]
        [object]$Value
    )

    $parsed = [Guid]::Empty
    return [Guid]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ne [Guid]::Empty
}

function Get-DeviceAdminPortalUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Intune', 'Entra')]
        [string]$Portal,

        [AllowNull()]
        [object]$Device
    )

    if ($null -eq $Device) {
        return $null
    }

    $propertyName = if ($Portal -eq 'Intune') { 'IntuneDeviceId' } else { 'EntraObjectId' }
    $rawId = [string](Get-PropertyValue -InputObject $Device -Name $propertyName)
    $parsedId = [Guid]::Empty
    if (-not [Guid]::TryParse($rawId, [ref]$parsedId) -or $parsedId -eq [Guid]::Empty) {
        return $null
    }

    $canonicalId = $parsedId.ToString('D')
    $url = if ($Portal -eq 'Intune') {
        "https://intune.microsoft.com/#view/Microsoft_Intune_Devices/DeviceSettingsMenuBlade/~/overview/mdmDeviceId/$canonicalId"
    }
    else {
        "https://entra.microsoft.com/#view/Microsoft_AAD_Devices/DeviceDetailsMenuBlade/~/Properties/objectId/$canonicalId"
    }

    return [Uri]::new($url, [UriKind]::Absolute)
}

function ConvertTo-DisplayDate {
    param(
        [AllowNull()]
        [object]$Value,

        [string]$EmptyText = [string][char]0x2014
    )

    $date = ConvertTo-LapsDateTimeOffset -Value $Value
    if ($null -eq $date) {
        return $EmptyText
    }

    return $date.ToLocalTime().ToString('MMM d, yyyy h:mm tt')
}

function Get-DeviceCompliancePresentation {
    param([AllowNull()][object]$Value)

    $text = 'Unknown'
    $foreground = '#475569'
    $background = '#F1F5F9'
    switch (([string]$Value).Trim().ToLowerInvariant()) {
        'compliant' { $text = 'Compliant'; $foreground = '#15803D'; $background = '#ECFDF3' }
        'noncompliant' { $text = 'Not compliant'; $foreground = '#B42318'; $background = '#FEF3F2' }
        'conflict' { $text = 'Conflict'; $foreground = '#B45309'; $background = '#FFFBEB' }
        'error' { $text = 'Error'; $foreground = '#B42318'; $background = '#FEF3F2' }
        'ingraceperiod' { $text = 'Grace period'; $foreground = '#B45309'; $background = '#FFFBEB' }
    }
    [pscustomobject]@{ Text = $text; Foreground = $foreground; Background = $background }
}

function ConvertTo-FriendlyComplianceState {
    param([AllowNull()][object]$Value)
    return (Get-DeviceCompliancePresentation -Value $Value).Text
}

function Format-DeviceDetails {
    param([AllowNull()][object]$Device)

    if ($null -eq $Device) { return $null }
    # An explicit allowlist keeps recovery material out even if the row grows.
    $fields = [ordered]@{
        'Device' = [string](Get-PropertyValue $Device 'DeviceName')
        'Primary user' = [string](Get-PropertyValue $Device 'PrimaryUser')
        'UPN' = [string](Get-PropertyValue $Device 'UserPrincipalName')
        'Serial' = [string](Get-PropertyValue $Device 'SerialNumber')
        'OS' = (([string](Get-PropertyValue $Device 'OperatingSystem') + ' ' + [string](Get-PropertyValue $Device 'OSVersion')).Trim())
    }
    $lines = foreach ($field in $fields.GetEnumerator()) {
        # Keep untrusted metadata on one line; remove invisible formatting controls.
        $value = [regex]::Replace([string]$field.Value, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq [string][char]0x2014) { $value = 'Unavailable' }
        '{0}: {1}' -f $field.Key, $value
    }
    return $lines -join [Environment]::NewLine
}

function ConvertTo-BitLockerVolumeDisplay {
    param(
        [AllowNull()]
        [object]$Value
    )

    switch (([string]$Value).ToLowerInvariant()) {
        '1' { return 'Operating system volume' }
        'operatingsystemvolume' { return 'Operating system volume' }
        '2' { return 'Fixed data volume' }
        'fixeddatavolume' { return 'Fixed data volume' }
        '3' { return 'Removable data volume' }
        'removabledatavolume' { return 'Removable data volume' }
        default { return 'Unknown volume' }
    }
}

function ConvertTo-TrustTypeDisplay {
    param(
        [AllowNull()]
        [object]$Value
    )

    switch (([string]$Value).ToLowerInvariant()) {
        'azuread' { return 'Microsoft Entra joined' }
        'serverad' { return 'Hybrid Microsoft Entra joined' }
        'workplace' { return 'Microsoft Entra registered' }
        default { return [string][char]0x2014 }
    }
}

function ConvertTo-OwnerTypeDisplay {
    param(
        [AllowNull()]
        [object]$Value
    )

    switch (([string]$Value).ToLowerInvariant()) {
        'company' { return 'Corporate' }
        'personal' { return 'Personal' }
        default { return [string][char]0x2014 }
    }
}

function Test-BitLockerRecoveryKey {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    return [regex]::IsMatch([string]$Value, '\A[0-9]{6}(?:-[0-9]{6}){7}\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function New-LapsDeviceRow {
    param(
        [AllowNull()]
        [object]$ManagedDevice,

        [AllowNull()]
        [object]$LapsMetadata,

        [AllowNull()]
        [object[]]$BitLockerMetadata,

        [AllowNull()]
        [object]$EntraDevice,

        [AllowNull()]
        [System.Collections.IDictionary]$PrimaryUsersByManagedDeviceId
    )

    $deviceName = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'deviceName')
    if ([string]::IsNullOrWhiteSpace($deviceName)) {
        $deviceName = [string](Get-PropertyValue -InputObject $LapsMetadata -Name 'deviceName')
    }
    if ([string]::IsNullOrWhiteSpace($deviceName)) {
        $deviceName = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'displayName')
    }
    if ([string]::IsNullOrWhiteSpace($deviceName)) {
        $deviceName = 'Unnamed device'
    }

    $entraDeviceId = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'azureADDeviceId')
    if (-not (Test-UsableEntraDeviceId -Value $entraDeviceId)) {
        $entraDeviceId = [string](Get-PropertyValue -InputObject $LapsMetadata -Name 'id')
    }
    if (-not (Test-UsableEntraDeviceId -Value $entraDeviceId)) {
        $entraDeviceId = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'deviceId')
    }
    if (-not (Test-UsableEntraDeviceId -Value $entraDeviceId)) {
        $firstBitLockerItem = @($BitLockerMetadata | Where-Object { $null -ne $_ } | Select-Object -First 1)
        if ($firstBitLockerItem.Count -gt 0) {
            $entraDeviceId = [string](Get-PropertyValue -InputObject $firstBitLockerItem[0] -Name 'deviceId')
        }
    }

    # Device-level user fields describe enrollment, not current primary-user
    # assignment. Only a successful /managedDevices/{id}/users read is authority.
    $managedId = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'id')
    $primaryUser = if ($null -eq $ManagedDevice) { 'Unassigned' } else { 'Unavailable' }
    $userPrincipalName = ''
    if ($null -ne $PrimaryUsersByManagedDeviceId -and $PrimaryUsersByManagedDeviceId.Contains($managedId)) {
        $assignedUsers = @($PrimaryUsersByManagedDeviceId[$managedId])
        $names = @($assignedUsers | ForEach-Object {
            $name = [string](Get-PropertyValue -InputObject $_ -Name 'displayName')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-PropertyValue -InputObject $_ -Name 'userPrincipalName') }
            if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Assigned user (details unavailable)' }
            $name
        })
        $primaryUser = if ($names.Count -eq 0) { 'Unassigned' } else { $names -join '; ' }
        $userPrincipalName = (@($assignedUsers | ForEach-Object {
            [string](Get-PropertyValue -InputObject $_ -Name 'userPrincipalName')
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '; ')
    }

    $lastSync = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $ManagedDevice -Name 'lastSyncDateTime')
    $lastBackup = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $LapsMetadata -Name 'lastBackupDateTime')
    $refreshDate = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $LapsMetadata -Name 'refreshDateTime')
    $lapsAvailable = $null -ne $LapsMetadata -and (Test-UsableEntraDeviceId -Value $entraDeviceId)
    $model = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'model')
    if ([string]::IsNullOrWhiteSpace($model)) {
        $model = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'model')
    }
    $serialNumber = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'serialNumber')
    $osVersion = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'osVersion')
    if ([string]::IsNullOrWhiteSpace($osVersion)) {
        $osVersion = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'operatingSystemVersion')
    }
    $manufacturer = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'manufacturer')
    if ([string]::IsNullOrWhiteSpace($manufacturer)) {
        $manufacturer = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'manufacturer')
    }
    $complianceState = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'complianceState')

    $bitLockerKeys = [System.Collections.Generic.List[object]]::new()
    foreach ($metadata in @($BitLockerMetadata)) {
        if ($null -eq $metadata) {
            continue
        }

        $keyId = [string](Get-PropertyValue -InputObject $metadata -Name 'id')
        $keyDeviceId = [string](Get-PropertyValue -InputObject $metadata -Name 'deviceId')
        if (-not (Test-UsableEntraDeviceId -Value $keyId) -or
            -not (Test-UsableEntraDeviceId -Value $keyDeviceId) -or
            -not [string]::Equals($keyDeviceId, $entraDeviceId, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $created = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $metadata -Name 'createdDateTime')
        $volumeType = Get-PropertyValue -InputObject $metadata -Name 'volumeType'
        $volumeDisplay = ConvertTo-BitLockerVolumeDisplay -Value $volumeType
        $createdDisplay = ConvertTo-DisplayDate -Value $created
        $bitLockerKeys.Add([pscustomobject]@{
            Id              = $keyId
            DeviceId        = $keyDeviceId
            CreatedDateTime = $created
            CreatedDisplay  = $createdDisplay
            VolumeType      = [string]$volumeType
            VolumeDisplay   = $volumeDisplay
            SelectorDisplay = "$volumeDisplay  •  $createdDisplay"
        })
    }
    $orderedBitLockerKeys = @($bitLockerKeys | Sort-Object -Property @{ Expression = {
        if ($null -eq $_.CreatedDateTime) { [DateTimeOffset]::MinValue } else { $_.CreatedDateTime }
    }; Descending = $true })
    $bitLockerAvailable = $orderedBitLockerKeys.Count -gt 0
    $newestBitLockerDate = if ($bitLockerAvailable) { $orderedBitLockerKeys[0].CreatedDateTime } else { $null }

    $operatingSystem = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'operatingSystem')
    if ([string]::IsNullOrWhiteSpace($operatingSystem)) {
        $operatingSystem = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'operatingSystem')
    }
    if ([string]::IsNullOrWhiteSpace($operatingSystem) -and $null -ne $LapsMetadata) {
        $operatingSystem = 'Windows'
    }

    $entraLastSignIn = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $EntraDevice -Name 'approximateLastSignInDateTime')
    $enrolledDate = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $ManagedDevice -Name 'enrolledDateTime')
    $isEncryptedValue = Get-PropertyValue -InputObject $ManagedDevice -Name 'isEncrypted'
    $isEncryptedDisplay = if ($null -eq $isEncryptedValue) { [string][char]0x2014 } elseif ([bool]$isEncryptedValue) { 'Yes' } else { 'No' }
    $managementAgent = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'managementAgent')
    if ([string]::IsNullOrWhiteSpace($managementAgent)) { $managementAgent = [string][char]0x2014 }
    $enrollmentType = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'deviceEnrollmentType')
    if ([string]::IsNullOrWhiteSpace($enrollmentType)) { $enrollmentType = [string][char]0x2014 }

    $isIntuneManaged = $null -ne $ManagedDevice
    $source = if ($isIntuneManaged) { 'Microsoft Intune' } else { 'Microsoft Entra' }
    $managementStateDisplay = if ($isIntuneManaged) { 'Intune managed' } else { 'Entra only' }
    $managementStateDescription = if ($isIntuneManaged) {
        'A matching Microsoft Intune managed-device record was found.'
    }
    else {
        'This device exists in Microsoft Entra with no matching Intune managed-device record. It may be intentionally unmanaged, unenrolled, or stale.'
    }
    $lastSyncDisplay = if ($isIntuneManaged) {
        ConvertTo-DisplayDate -Value $lastSync -EmptyText 'Never'
    }
    else {
        'Not in Intune'
    }
    $searchText = @(
        $deviceName
        $primaryUser
        $userPrincipalName
        $serialNumber
        $model
        $manufacturer
        $osVersion
        $entraDeviceId
        [string](Get-PropertyValue -InputObject $EntraDevice -Name 'id')
        $source
        $managementStateDisplay
        $lastSyncDisplay
        @($orderedBitLockerKeys | ForEach-Object { $_.Id })
    ) -join ' '

    [pscustomobject]@{
        IntuneDeviceId       = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'id')
        EntraDeviceId        = $entraDeviceId
        EntraObjectId        = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'id')
        DeviceName           = $deviceName
        PrimaryUser          = $primaryUser
        UserPrincipalName    = $userPrincipalName
        SerialNumber         = if ([string]::IsNullOrWhiteSpace($serialNumber)) { [string][char]0x2014 } else { $serialNumber }
        Manufacturer         = $manufacturer
        Model                = if ([string]::IsNullOrWhiteSpace($model)) { [string][char]0x2014 } else { $model }
        OperatingSystem      = $operatingSystem
        OSVersion            = $osVersion
        LastSyncDateTime     = $lastSync
        LastSyncDisplay      = $lastSyncDisplay
        ComplianceState      = $complianceState
        ComplianceDisplay    = ConvertTo-FriendlyComplianceState -Value $complianceState
        LapsAvailable        = [bool]$lapsAvailable
        LapsStatus           = if ($lapsAvailable) { 'Ready' } else { 'Not backed up' }
        LastBackupDateTime   = $lastBackup
        LastBackupDisplay    = ConvertTo-DisplayDate -Value $lastBackup
        RefreshDateTime      = $refreshDate
        RefreshDateDisplay   = ConvertTo-DisplayDate -Value $refreshDate
        BitLockerKeys        = $orderedBitLockerKeys
        BitLockerAvailable   = [bool]$bitLockerAvailable
        BitLockerKeyCount    = $orderedBitLockerKeys.Count
        BitLockerStatus      = if ($orderedBitLockerKeys.Count -eq 1) { '1 key' } elseif ($orderedBitLockerKeys.Count -gt 1) { "$($orderedBitLockerKeys.Count) keys" } else { 'No key' }
        BitLockerNewestDateTime = $newestBitLockerDate
        BitLockerNewestDisplay  = ConvertTo-DisplayDate -Value $newestBitLockerDate
        RecoveryAvailable    = [bool]($lapsAvailable -or $bitLockerAvailable)
        TrustType            = [string](Get-PropertyValue -InputObject $EntraDevice -Name 'trustType')
        TrustTypeDisplay     = ConvertTo-TrustTypeDisplay -Value (Get-PropertyValue -InputObject $EntraDevice -Name 'trustType')
        EntraAccountEnabled  = Get-PropertyValue -InputObject $EntraDevice -Name 'accountEnabled'
        EntraLastSignInDateTime = $entraLastSignIn
        EntraLastSignInDisplay  = ConvertTo-DisplayDate -Value $entraLastSignIn
        DeviceOwnerType      = [string](Get-PropertyValue -InputObject $ManagedDevice -Name 'managedDeviceOwnerType')
        DeviceOwnerDisplay   = ConvertTo-OwnerTypeDisplay -Value (Get-PropertyValue -InputObject $ManagedDevice -Name 'managedDeviceOwnerType')
        DeviceEnrollmentType = $enrollmentType
        ManagementAgent     = $managementAgent
        IsEncrypted         = $isEncryptedValue
        IsEncryptedDisplay  = $isEncryptedDisplay
        EnrolledDateTime    = $enrolledDate
        EnrolledDateDisplay = ConvertTo-DisplayDate -Value $enrolledDate
        InventorySource      = $source
        IsIntuneManaged      = $isIntuneManaged
        IsEntraOnly          = -not $isIntuneManaged
        ManagementStateDisplay = $managementStateDisplay
        ManagementStateDescription = $managementStateDescription
        IsStale              = $isIntuneManaged -and $null -ne $lastSync -and $lastSync -lt [DateTimeOffset]::Now.AddDays(-30)
        SearchText           = $searchText.ToLowerInvariant()
    }
}

function Merge-IntuneLapsDeviceData {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$ManagedDevices,

        [AllowNull()]
        [object[]]$LapsMetadata,

        [AllowNull()]
        [object[]]$BitLockerMetadata,

        [AllowNull()]
        [object[]]$EntraDevices,

        [AllowNull()]
        [System.Collections.IDictionary]$PrimaryUsersByManagedDeviceId
    )

    $lapsById = @{}
    foreach ($metadata in @($LapsMetadata)) {
        if ($null -eq $metadata) {
            continue
        }

        $id = [string](Get-PropertyValue -InputObject $metadata -Name 'id')
        if (Test-UsableEntraDeviceId -Value $id) {
            $lapsById[$id.ToLowerInvariant()] = $metadata
        }
    }

    $entraByDeviceId = @{}
    foreach ($device in @($EntraDevices)) {
        if ($null -eq $device) {
            continue
        }

        $deviceId = [string](Get-PropertyValue -InputObject $device -Name 'deviceId')
        if (Test-UsableEntraDeviceId -Value $deviceId) {
            $entraByDeviceId[$deviceId.ToLowerInvariant()] = $device
        }
    }

    $bitLockerByDeviceId = @{}
    foreach ($metadata in @($BitLockerMetadata)) {
        if ($null -eq $metadata) {
            continue
        }

        $deviceId = [string](Get-PropertyValue -InputObject $metadata -Name 'deviceId')
        if (-not (Test-UsableEntraDeviceId -Value $deviceId)) {
            continue
        }

        $key = $deviceId.ToLowerInvariant()
        if (-not $bitLockerByDeviceId.ContainsKey($key)) {
            $bitLockerByDeviceId[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $bitLockerByDeviceId[$key].Add($metadata)
    }

    # Intune sometimes retains multiple managedDevice records for one Entra device.
    # Keep only the record with the newest check-in so the operator sees one computer.
    $managedByKey = @{}
    foreach ($device in @($ManagedDevices)) {
        if ($null -eq $device) {
            continue
        }

        $operatingSystem = [string](Get-PropertyValue -InputObject $device -Name 'operatingSystem')
        if (-not [string]::Equals($operatingSystem, 'Windows', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $entraId = [string](Get-PropertyValue -InputObject $device -Name 'azureADDeviceId')
        $intuneId = [string](Get-PropertyValue -InputObject $device -Name 'id')
        $key = if (Test-UsableEntraDeviceId -Value $entraId) {
            'entra:' + $entraId.ToLowerInvariant()
        }
        else {
            'intune:' + $intuneId.ToLowerInvariant()
        }

        $candidateDate = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $device -Name 'lastSyncDateTime')
        if (-not $managedByKey.ContainsKey($key)) {
            $managedByKey[$key] = $device
            continue
        }

        $existingDate = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $managedByKey[$key] -Name 'lastSyncDateTime')
        if ($null -ne $candidateDate -and ($null -eq $existingDate -or $candidateDate -gt $existingDate)) {
            $managedByKey[$key] = $device
        }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $usedDeviceIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($device in $managedByKey.Values) {
        $entraId = [string](Get-PropertyValue -InputObject $device -Name 'azureADDeviceId')
        $metadata = $null
        $bitLocker = @()
        $entraDevice = $null
        if (Test-UsableEntraDeviceId -Value $entraId) {
            $metadata = $lapsById[$entraId.ToLowerInvariant()]
            $bitLocker = @($bitLockerByDeviceId[$entraId.ToLowerInvariant()])
            $entraDevice = $entraByDeviceId[$entraId.ToLowerInvariant()]
            $null = $usedDeviceIds.Add($entraId)
        }

        $rows.Add((New-LapsDeviceRow -ManagedDevice $device -LapsMetadata $metadata -BitLockerMetadata $bitLocker -EntraDevice $entraDevice -PrimaryUsersByManagedDeviceId $PrimaryUsersByManagedDeviceId))
    }

    # Include Windows devices present only in Entra, plus recovery records whose
    # corresponding directory object is not returned by the device inventory call.
    $remainingIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in $entraByDeviceId.Keys) {
        $entraOs = [string](Get-PropertyValue -InputObject $entraByDeviceId[$id] -Name 'operatingSystem')
        if ([string]::Equals($entraOs, 'Windows', [StringComparison]::OrdinalIgnoreCase) -or $lapsById.ContainsKey($id) -or $bitLockerByDeviceId.ContainsKey($id)) {
            $null = $remainingIds.Add($id)
        }
    }
    foreach ($id in $lapsById.Keys) { $null = $remainingIds.Add($id) }
    foreach ($id in $bitLockerByDeviceId.Keys) { $null = $remainingIds.Add($id) }

    foreach ($id in $remainingIds) {
        if (-not $usedDeviceIds.Contains($id)) {
            $rows.Add((New-LapsDeviceRow `
                -ManagedDevice $null `
                -LapsMetadata $lapsById[$id] `
                -BitLockerMetadata @($bitLockerByDeviceId[$id]) `
                -EntraDevice $entraByDeviceId[$id]))
        }
    }

    return @($rows | Sort-Object DeviceName, UserPrincipalName)
}

function Get-IntunePrimaryUserMap {
    [CmdletBinding()]
    param([AllowNull()][object[]]$ManagedDevices)

    $usersById = @{}
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($device in @($ManagedDevices)) {
        if ((Get-PropertyValue $device 'operatingSystem') -ne 'Windows') { continue }
        $id = [string](Get-PropertyValue $device 'id')
        if (-not (Test-UsableEntraDeviceId $id)) { throw 'Intune returned an invalid managed-device ID.' }
        if ($usersById.ContainsKey($id)) { continue }
        $usersById[$id] = [System.Collections.Generic.List[object]]::new()
        $url = '/deviceManagement/managedDevices/' + [uri]::EscapeDataString($id) + '/users?$select=id,displayName,userPrincipalName'
        $null = $visited.Add($url)
        $pending.Enqueue([pscustomobject]@{ DeviceId=$id; Url=$url; Page=1 })
    }

    while ($pending.Count -gt 0) {
        $requests = [System.Collections.Generic.List[object]]::new()
        $byRequestId = @{}
        while ($pending.Count -gt 0 -and $requests.Count -lt 20) {
            $item = $pending.Dequeue()
            $requestId = [string]($requests.Count + 1)
            $byRequestId[$requestId] = $item
            $requests.Add(@{ id=$requestId; method='GET'; url=$item.Url })
        }
        # POST is only the Graph batch envelope. Every enclosed request is a read.
        $body = @{ requests=@($requests.ToArray()) } | ConvertTo-Json -Depth 6 -Compress
        $batch = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/$batch' -Body $body -ContentType 'application/json' -OutputType PSObject -ErrorAction Stop
        $responses = @(Get-PropertyValue $batch 'responses')
        if ($responses.Count -ne $requests.Count) { throw 'Incomplete Intune primary-user batch response.' }
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($response in $responses) {
            $responseId = [string](Get-PropertyValue $response 'id')
            if (-not $byRequestId.ContainsKey($responseId) -or -not $seen.Add($responseId)) {
                throw 'Invalid Intune primary-user response correlation.'
            }
            $item = $byRequestId[$responseId]
            $status = [int](Get-PropertyValue $response 'status')
            if ($status -ne 200) {
                # A batch HTTP 200 does not imply its individual requests succeeded.
                # Keep the previous inventory; never turn a failed read into Unassigned.
                $failure = [InvalidOperationException]::new('Intune primary-user lookup failed. Retry the inventory refresh.')
                $failure | Add-Member -NotePropertyName ResponseStatusCode -NotePropertyValue $status
                $failure | Add-Member -NotePropertyName ErrorCode -NotePropertyValue 'PrimaryUserLookupFailed'
                throw $failure
            }
            $page = Get-PropertyValue $response 'body'
            if ($null -eq $page -or $null -eq $page.PSObject.Properties['value'] -or $null -eq $page.value -or
                $page.value -isnot [System.Collections.IEnumerable] -or $page.value -is [string]) {
                throw 'Malformed Intune primary-user collection.'
            }
            foreach ($user in @($page.value)) {
                if (-not (Test-UsableEntraDeviceId ([string](Get-PropertyValue $user 'id')))) {
                    throw 'Malformed Intune primary-user record.'
                }
                $usersById[$item.DeviceId].Add($user)
            }
            $nextLink = [string](Get-PropertyValue $page '@odata.nextLink')
            if (-not [string]::IsNullOrWhiteSpace($nextLink)) {
                $nextUri = [uri]$nextLink
                $expectedPath = '/v1.0/deviceManagement/managedDevices/' + [uri]::EscapeDataString($item.DeviceId) + '/users'
                if (-not $nextUri.IsAbsoluteUri -or $nextUri.Scheme -ne 'https' -or $nextUri.Host -ne 'graph.microsoft.com' -or
                    -not $nextUri.IsDefaultPort -or $nextUri.UserInfo -or $nextUri.Fragment -or $nextUri.AbsolutePath -ne $expectedPath) {
                    throw 'Untrusted Intune primary-user page link.'
                }
                $nextUrl = $nextUri.PathAndQuery.Substring('/v1.0'.Length)
                if ($item.Page -ge 100 -or -not $visited.Add($nextUrl)) { throw 'Intune primary-user pagination did not complete safely.' }
                $pending.Enqueue([pscustomobject]@{ DeviceId=$item.DeviceId; Url=$nextUrl; Page=$item.Page+1 })
            }
        }
    }
    $result = @{}
    foreach ($id in $usersById.Keys) { $result[$id] = $usersById[$id].ToArray() }
    return $result
}

function Select-CurrentLapsCredential {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Credentials
    )

    $usable = @(
        $Credentials | Where-Object {
            $null -ne $_ -and
            -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -InputObject $_ -Name 'passwordBase64'))
        }
    )

    if ($usable.Count -eq 0) {
        return $null
    }

    return $usable |
        Sort-Object -Property @{ Expression = {
            $date = ConvertTo-LapsDateTimeOffset -Value (Get-PropertyValue -InputObject $_ -Name 'backupDateTime')
            if ($null -eq $date) { [DateTimeOffset]::MinValue } else { $date }
        }; Descending = $true } |
        Select-Object -First 1
}

function ConvertFrom-LapsPasswordBase64 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PasswordBase64
    )

    $bytes = $null
    $decoded = $null
    try {
        $bytes = [Convert]::FromBase64String($PasswordBase64)

        if ($bytes.Length -eq 0) {
            throw 'The LAPS password payload is empty.'
        }

        $utf8 = [Text.UTF8Encoding]::new($false, $true)
        $utf16Le = [Text.UnicodeEncoding]::new($false, $false, $true)
        $utf16Be = [Text.UnicodeEncoding]::new($true, $false, $true)

        $isSafePasswordText = {
            param([AllowNull()][string]$Value)

            if ([string]::IsNullOrEmpty($Value)) {
                return $false
            }

            foreach ($character in $Value.ToCharArray()) {
                if ([char]::IsControl($character)) {
                    return $false
                }
            }

            return $true
        }

        try {
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $decoded = $utf8.GetString($bytes, 3, $bytes.Length - 3).TrimEnd([char]0)
            }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
                $decoded = $utf16Le.GetString($bytes, 2, $bytes.Length - 2).TrimEnd([char]0)
            }
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
                $decoded = $utf16Be.GetString($bytes, 2, $bytes.Length - 2).TrimEnd([char]0)
            }
            else {
                # Current Graph responses can contain UTF-8, while older examples and
                # tenants use UTF-16LE. Prefer valid, control-free UTF-8; UTF-16LE
                # ASCII data naturally contains NUL controls and therefore falls
                # through to the legacy decoder without guessing from byte length.
                try {
                    $decoded = $utf8.GetString($bytes).TrimEnd([char]0)
                }
                catch {
                    $decoded = $null
                }

                if (-not (& $isSafePasswordText $decoded) -and ($bytes.Length % 2) -eq 0) {
                    try {
                        $decoded = $utf16Le.GetString($bytes).TrimEnd([char]0)
                    }
                    catch {
                        $decoded = $null
                    }
                }
            }
        }
        catch {
            $decoded = $null
        }

        if (-not (& $isSafePasswordText $decoded)) {
            throw 'The LAPS password payload could not be decoded safely.'
        }

        return $decoded
    }
    finally {
        $decoded = $null
        if ($null -ne $bytes) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function Test-LapsGraphContext {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Context,

        [Parameter(Mandatory)]
        [string]$ExpectedAccount,

        [Parameter(Mandatory)]
        [Guid]$ExpectedTenantId,

        [Parameter(Mandatory)]
        [string[]]$RequiredScopes
    )

    if ($null -eq $Context) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'NoContext'; MissingScopes = @($RequiredScopes) }
    }

    if (-not [string]::Equals([string](Get-PropertyValue -InputObject $Context -Name 'AuthType'), 'Delegated', [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'NotDelegated'; MissingScopes = @($RequiredScopes) }
    }

    $account = [string](Get-PropertyValue -InputObject $Context -Name 'Account')
    if (-not [string]::Equals($account, $ExpectedAccount, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'WrongAccount'; MissingScopes = @() }
    }

    $contextTenantId = [Guid]::Empty
    if (-not [Guid]::TryParse([string](Get-PropertyValue -InputObject $Context -Name 'TenantId'), [ref]$contextTenantId) -or $contextTenantId -ne $ExpectedTenantId) {
        return [pscustomobject]@{ IsValid = $false; Reason = 'WrongTenant'; MissingScopes = @() }
    }

    $granted = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($scope in @((Get-PropertyValue -InputObject $Context -Name 'Scopes'))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$scope)) {
            $null = $granted.Add([string]$scope)
        }
    }

    $missing = @($RequiredScopes | Where-Object { -not $granted.Contains($_) })
    return [pscustomobject]@{
        IsValid      = $missing.Count -eq 0
        Reason       = if ($missing.Count -eq 0) { 'Valid' } else { 'MissingScopes' }
        MissingScopes = $missing
    }
}

function Get-DeviceCodeFromMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Message
    )

    $text = [string]$Message
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $match = [regex]::Match($text, '(?i)enter\s+the\s+code\s+([A-Z0-9]{8,12})\s+to\s+authenticate')
    if (-not $match.Success) {
        return $null
    }

    $urlMatch = [regex]::Match($text, 'https://[^\s]+')
    return [pscustomobject]@{
        UserCode        = $match.Groups[1].Value.ToUpperInvariant()
        VerificationUrl = if ($urlMatch.Success) { $urlMatch.Value.TrimEnd('.', ',') } else { 'https://login.microsoft.com/device' }
    }
}

function Get-SecretVerificationDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Preferred', 'Required', 'Disabled')]
        [string]$Mode,

        [AllowNull()]
        [ValidateSet('Verified', 'DeviceNotPresent', 'NotConfiguredForUser', 'DisabledByPolicy', 'DeviceBusy', 'RetriesExhausted', 'Canceled', 'TimedOut', 'NotSupported', 'Unavailable', 'Error')]
        [string]$LocalResult,

        [DateTimeOffset]$VerifiedUntil = [DateTimeOffset]::MinValue,

        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if ($Mode -eq 'Disabled') {
        return 'Bypass'
    }

    if ([string]::IsNullOrWhiteSpace($LocalResult) -and $VerifiedUntil -gt $Now) {
        return 'Grant'
    }

    if ([string]::IsNullOrWhiteSpace($LocalResult)) {
        return 'Local'
    }

    switch ($LocalResult) {
        'Verified' { return 'Grant' }
        { $_ -in @('DeviceNotPresent', 'NotConfiguredForUser', 'DisabledByPolicy', 'NotSupported', 'Unavailable') } {
            if ($Mode -eq 'Preferred') {
                return 'Microsoft'
            }
            return 'Blocked'
        }
        'DeviceBusy' { return 'Retry' }
        'Canceled' { return 'Canceled' }
        'TimedOut' { return 'TimedOut' }
        default { return 'Denied' }
    }
}

function Get-FriendlyLapsErrorMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ErrorCode,

        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [Nullable[int]]$StatusCode
    )

    $combined = "$ErrorCode $Message"
    if ($ErrorCode -eq 'WorkerStartFailed') {
        return 'The local background worker could not start. Retry the action; if it happens again, close and reopen Workbench.'
    }
    switch ($ErrorCode) {
        'WrongAccount' { return 'Microsoft sign-in used a different account. Reconnect using the configured administrator account.' }
        'WrongTenant' { return 'Microsoft sign-in used a different tenant. Reconnect to the configured tenant.' }
        'MissingScopes' { return 'Microsoft sign-in is missing required Graph permissions. Check administrator consent, then reconnect.' }
        'NotDelegated' { return 'This workspace requires a delegated administrator sign-in. Reconnect using the configured account.' }
    }
    # Status is authoritative; incidental words such as "token" must not turn a
    # service outage or access denial into misleading expired-sign-in guidance.
    if ($StatusCode -ge 500 -and $StatusCode -le 599) {
        return 'Microsoft Graph is temporarily unavailable. Wait a moment and retry.'
    }
    if ($StatusCode -eq 408) {
        return 'The Microsoft Graph request timed out. Check the network connection and retry.'
    }
    if ($StatusCode -ge 100 -and $StatusCode -le 599) { $combined = '' }
    if ($StatusCode -eq 401 -or $combined -match '(?i)authentication|token|sign.?in') {
        return 'Your Microsoft Graph sign-in has expired. Sign in again and retry.'
    }
    if ($StatusCode -eq 403 -or $combined -match '(?i)access.?denied|authorization_requestdenied|insufficient.?privilege') {
        return 'Access was denied. Check the configured Graph recovery permissions and use an eligible Entra role such as Cloud Device Administrator or Intune Administrator.'
    }
    if ($StatusCode -eq 404 -or $combined -match '(?i)not.?found|resource.?not.?found') {
        return 'No current recovery secret was found for the selected record. Refresh the device inventory and retry.'
    }
    if ($StatusCode -eq 429 -or $combined -match '(?i)too.?many.?requests|throttl') {
        return 'Microsoft Graph is temporarily throttling requests. Wait a moment and retry.'
    }
    if ($combined -match '(?i)consent') {
        return "Administrator consent is required for this tool's Microsoft Graph permissions."
    }
    if ($combined -match '(?i)timed?\s*out|timeout|taskcanceled|operationcanceled') {
        return 'The Microsoft Graph request timed out. Check the network connection and retry.'
    }
    if ($combined -match '(?i)password.?payload|decoded.?safely|passworddecodefailed') {
        return 'Microsoft Graph returned a LAPS password payload that this utility could not decode safely. Close and reopen the updated utility, then retry.'
    }
    if ($combined -match '(?i)48-digit BitLocker|recoverykeyvalidationfailed|different device') {
        return 'Microsoft Graph returned an invalid or mismatched BitLocker recovery-key payload. Refresh the device inventory and retry.'
    }

    return 'Microsoft Graph could not complete the request. Retry, then check the tenant connection and permissions if the problem continues.'
}

Export-ModuleMember -Function @(
    'ConvertFrom-LapsPasswordBase64'
    'Format-DeviceDetails'
    'Get-DeviceCompliancePresentation'
    'Get-DeviceAdminPortalUri'
    'Get-DeviceCodeFromMessage'
    'Get-FriendlyLapsErrorMessage'
    'Get-IntunePrimaryUserMap'
    'Get-SecretVerificationDecision'
    'Merge-IntuneLapsDeviceData'
    'Select-CurrentLapsCredential'
    'Test-BitLockerRecoveryKey'
    'Test-LapsGraphContext'
)
