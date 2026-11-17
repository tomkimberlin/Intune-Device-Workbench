param($CoreModulePath)

$ErrorActionPreference = 'Stop'
Import-Module $CoreModulePath
$stage = 'managed device inventory'

function Invoke-PagedGraphGet {
    param([Parameter(Mandatory)][string]$Uri)

    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $collectionPath = ([uri]$Uri).AbsolutePath
    $next = $Uri
    while ($next) {
        if (-not $visited.Add($next) -or $visited.Count -gt 10000) {
            throw 'Microsoft Graph inventory pagination did not complete safely.'
        }
        $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
        $page = Read-GraphCollectionPage -Response $response -CollectionPath $collectionPath
        $page.Items
        $next = $page.NextLink
    }
}

try {
    $managedUri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,deviceName,azureADDeviceId,serialNumber,operatingSystem,osVersion,model,manufacturer,lastSyncDateTime,complianceState,managedDeviceOwnerType,deviceEnrollmentType,isEncrypted,managementAgent,enrolledDateTime'
    $lapsUri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials?`$select=id,deviceName,lastBackupDateTime,refreshDateTime"
    $bitLockerUri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys"
    $entraUri = 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,displayName,accountEnabled,operatingSystem,operatingSystemVersion,trustType,approximateLastSignInDateTime,manufacturer,model'

    $currentManagedDevices = Get-CurrentManagedDeviceMap -ManagedDevices @(Invoke-PagedGraphGet -Uri $managedUri)
    $stage = 'Intune primary users'
    $primaryUsers = Get-IntunePrimaryUserMap -ManagedDevices @($currentManagedDevices.Values)
    $stage = 'LAPS metadata'
    $lapsMetadata = @(Invoke-PagedGraphGet -Uri $lapsUri)
    $stage = 'BitLocker metadata'
    $bitLockerMetadata = @(Invoke-PagedGraphGet -Uri $bitLockerUri)
    $stage = 'Entra device inventory'
    $entraDevices = @(Invoke-PagedGraphGet -Uri $entraUri)
    $rows = @(Merge-IntuneLapsDeviceData -CurrentManagedDevices $currentManagedDevices -LapsMetadata $lapsMetadata -BitLockerMetadata $bitLockerMetadata -EntraDevices $entraDevices -PrimaryUsersByManagedDeviceId $primaryUsers)

    [pscustomobject]@{
        Kind = 'InventoryResult'
        Devices = $rows
        LoadedAt = [DateTimeOffset]::Now
    }
}
catch {
    ConvertTo-GraphOperationError -ErrorRecord $_ -Stage $stage
}
