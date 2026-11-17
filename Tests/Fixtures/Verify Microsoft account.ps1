# Isolated test process. Only the Graph SDK calls are replaced.
$ErrorActionPreference = 'Stop'
$fixture = $env:M365WB_VERIFY_CONFIG | ConvertFrom-Json
switch ($fixture.Nonce) {
    'block' { Start-Sleep -Seconds 30; exit 1 }
    'closed-output' { [Console]::Out.Close(); Start-Sleep -Seconds 30; exit 1 }
    'wrong-nonce' {
        [Console]::WriteLine('Enter the code Z9Y8X7W6V to authenticate.')
        [Console]::WriteLine('M365WB_VERIFY_RESULT::another-request::{"Status":"Verified"}')
        exit 0
    }
}

function Import-Module {
    param($Name, $MinimumVersion, $ErrorAction)
    if ($Name -eq 'Microsoft.Graph.Authentication') { return }
    Microsoft.PowerShell.Core\Import-Module -Name $Name -Scope Global -ErrorAction Stop
}
function Connect-MgGraph {
    [CmdletBinding()]
    param($TenantId, [switch]$UseDeviceCode, $Scopes, $ContextScope, [switch]$NoWelcome)
    if (-not $UseDeviceCode -or $ContextScope -ne 'Process') { throw 'Unexpected verification scope.' }
    if ($fixture.Nonce -ne 'silent') {
        Write-Information 'Enter the code Z9Y8X7W6V to authenticate. Synthetic SDK detail.'
    }
}
function Get-MgContext {
    [pscustomobject]@{
        Account = if ($fixture.Nonce -eq 'wrong-account') { 'other@contoso.com' } else { $fixture.ExpectedAccount }
        AuthType = 'Delegated'
        TenantId = $fixture.ExpectedTenantObjectId
        Scopes = $fixture.RequiredScopes
    }
}
function Disconnect-MgGraph { throw 'The verification process must preserve the cached sign-in.' }

& (Join-Path (Split-Path $fixture.CoreModulePath) 'Operations/VerifyMicrosoftAccount.ps1')
exit $LASTEXITCODE
