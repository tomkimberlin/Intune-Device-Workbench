param($DeviceId, $RecoveryKeyId, $CoreModulePath)

$ErrorActionPreference = 'Stop'
Import-Module $CoreModulePath
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
    $uri = "https://graph.microsoft.com/v1.0/informationProtection/bitlocker/recoveryKeys/$escapedKeyId`?`$select=id,key,deviceId"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
    if ([guid]$response.id -ne $parsedKeyId) {
        throw 'Microsoft Graph returned a different BitLocker recovery-key record.'
    }
    $responseDeviceId = [guid]::Empty
    if (-not [guid]::TryParse([string]$response.deviceId, [ref]$responseDeviceId) -or $responseDeviceId -ne $parsedDeviceId) {
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
        RecoveryKey = $recoveryKey
    }
}
catch {
    ConvertTo-GraphOperationError -ErrorRecord $_
}
finally {
    if ($null -ne $response -and $null -ne $response.PSObject.Properties['key']) { $response.key = $null }
    $recoveryKey = $null
    $response = $null
}
