param($DeviceId, $CoreModulePath)

$ErrorActionPreference = 'Stop'
Import-Module $CoreModulePath
$response = $null
$records = @()
$credential = $null
$password = $null

try {
    $parsedId = [Guid]::Empty
    if (-not [Guid]::TryParse($DeviceId, [ref]$parsedId) -or $parsedId -eq [Guid]::Empty) {
        throw 'The selected computer does not have a usable Microsoft Entra device ID.'
    }

    $escapedId = [Uri]::EscapeDataString($parsedId.ToString())
    $uri = "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/$escapedId`?`$select=id,credentials"
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -ErrorAction Stop
    $records = @($response)
    if ($null -ne $response -and $null -ne $response.PSObject.Properties['value']) {
        $records = @($response.value)
    }
    $returnedId = [guid]::Empty
    if ($records.Count -ne 1 -or $null -eq $records[0] -or $null -eq $records[0].PSObject.Properties['id'] -or
        -not [guid]::TryParse([string]$records[0].id, [ref]$returnedId) -or $returnedId -ne $parsedId) {
        throw 'Microsoft Graph returned a LAPS credential for a different device.'
    }

    $credential = Select-CurrentLapsCredential -Credentials @($records[0].credentials)
    if ($null -eq $credential) {
        [pscustomobject]@{ Kind = 'Error'; ErrorCode = 'NoCredential'; Message = 'No current LAPS credential was returned.'; StatusCode = 404 }
        return
    }

    $password = ConvertFrom-LapsPasswordBase64 -PasswordBase64 ([string]$credential.passwordBase64)

    [pscustomobject]@{
        Kind = 'CredentialResult'
        DeviceId = $parsedId.ToString()
        AccountName = [string]$credential.accountName
        Password = $password
    }
}
catch {
    ConvertTo-GraphOperationError -ErrorRecord $_
}
finally {
    foreach ($record in $records) {
        if ($null -eq $record -or $null -eq $record.PSObject.Properties['credentials']) { continue }
        foreach ($item in @($record.credentials)) {
            if ($null -ne $item -and $null -ne $item.PSObject.Properties['passwordBase64']) { $item.passwordBase64 = $null }
        }
    }
    $password = $null
    $credential = $null
    $response = $null
}
