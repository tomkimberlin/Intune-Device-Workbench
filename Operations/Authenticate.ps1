param($TenantId, $ExpectedTenantObjectId, $ExpectedAccount, $RequiredScopes, $CoreModulePath, $MinimumGraphVersion)

$ErrorActionPreference = 'Stop'
Import-Module $CoreModulePath
try { Import-Module Microsoft.Graph.Authentication -MinimumVersion ([version]$MinimumGraphVersion) -ErrorAction Stop }
catch {
    [pscustomobject]@{ Kind='Error'; ErrorCode='GraphModuleUnavailable'; Message=''; StatusCode=$null }
    return
}

try {
    $null = Set-MgRequestContext -ClientTimeout 20 -MaxRetry 1
    # Preserve the SDK reconnect even when old context metadata still matches.
    # The SDK can reuse its secure cache; never clear it or loop over sign-ins.
    $connectParameters = @{
        TenantId=$TenantId; UseDeviceCode=$true; Scopes=$RequiredScopes
        ContextScope='CurrentUser'; ClientTimeout=20; NoWelcome=$true; ErrorAction='Stop'
    }
    Connect-MgGraph @connectParameters 6>&1
    $context = Get-MgContext
    $validation = Test-LapsGraphContext -Context $context -ExpectedAccount $ExpectedAccount -ExpectedTenantId $ExpectedTenantObjectId -RequiredScopes $RequiredScopes
    if (-not $validation.IsValid) {
        [pscustomobject]@{ Kind='Error'; ErrorCode=$validation.Reason; Message='The Graph context did not match the configured identity and permissions.'; StatusCode=$null }
        return
    }

    # Context metadata is not proof that the token or connection works.
    # A real request uses an existing scope and never retrieves recovery data.
    $probe = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/devices?$select=id&$top=1' -OutputType PSObject -ErrorAction Stop
    $null = Read-GraphCollectionPage -Response $probe -CollectionPath '/v1.0/devices'
    [pscustomobject]@{
        Kind='AuthResult'; Account=[string]$context.Account; TenantId=[string]$context.TenantId
        Scopes=@($context.Scopes); ConnectionVerified=$true
    }
}
catch {
    ConvertTo-GraphOperationError -ErrorRecord $_ -Stage 'connection verification'
}
