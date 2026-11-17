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
    [Console]::Out.WriteLine("M365WB_VERIFY_RESULT::$Nonce::$payload")
    [Console]::Out.Flush()
}

try {
    $config = $env:M365WB_VERIFY_CONFIG | ConvertFrom-Json
    Import-Module ([string]$config.CoreModulePath)
    Import-Module Microsoft.Graph.Authentication -MinimumVersion ([version]$config.MinimumGraphVersion) -ErrorAction Stop

    Connect-MgGraph `
        -TenantId ([string]$config.TenantId) `
        -UseDeviceCode `
        -Scopes ([string[]]$config.RequiredScopes) `
        -ContextScope Process `
        -NoWelcome `
        -ErrorAction Stop 6>&1 |
        ForEach-Object {
            $prompt = Get-DeviceCodeFromMessage -Message $_
            if ($null -ne $prompt) {
                [Console]::Out.WriteLine("Enter the code $($prompt.UserCode) to authenticate.")
                [Console]::Out.Flush()
            }
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
    try {
        if ($null -ne $config -and -not [string]::IsNullOrWhiteSpace([string]$config.Nonce)) {
            Write-VerificationResult -Status 'Failed' -Nonce ([string]$config.Nonce) -ErrorCode 'ConnectionFailed'
        }
    }
    catch { }
    exit 2
}
