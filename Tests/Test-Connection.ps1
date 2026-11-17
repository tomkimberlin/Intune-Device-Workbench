# Production auth worker with synthetic SDK commands only. Never loads Graph,
# touches its secure cache, requests a sign-in, or contacts a tenant.
& {
    $worker = Join-Path $productionOperations 'Authenticate.ps1'
    function Import-Module { param($Name,$MinimumVersion,[switch]$Force,$ErrorAction) }
    function Set-MgRequestContext { param($ClientTimeout,$MaxRetry) }
    function Disconnect-MgGraph { throw 'Tests must never clear the reusable Graph sign-in.' }
    function Get-MgContext {
        if ($authFixture.Mode -eq 'Missing' -and $authFixture.Connects -eq 0) { return $null }
        [pscustomobject]@{
            AuthType='Delegated'; TenantId='11111111-1111-4111-8111-111111111111'; Scopes=@('Device.Read.All')
            Account=$(if($authFixture.Mode -eq 'WrongAccount'){'other@contoso.com'}else{'admin@contoso.com'})
        }
    }
    function Connect-MgGraph {
        param($TenantId,$Scopes,$ContextScope,$ClientTimeout,[switch]$UseDeviceCode,[switch]$NoWelcome,$ErrorAction)
        $authFixture.Connects++
        $authFixture.ConnectionArguments=@{Scopes=@($Scopes);ContextScope=$ContextScope;UseDeviceCode=[bool]$UseDeviceCode}
    }
    function Invoke-MgGraphRequest {
        param($Method,$Uri,$OutputType,$ErrorAction)
        $authFixture.Probes++
        $authFixture.Uri=$Uri
        switch ($authFixture.Mode) {
            'NoContent' { return }
            'EmptyTenant' { return [pscustomobject]@{ value=@() } }
            'Incomplete' { return [pscustomobject]@{ value=@([pscustomobject]@{ displayName='DEMO-DEVICE-PROBE' }) } }
            'ArrayId' { return [pscustomobject]@{ value=@([pscustomobject]@{ id=@('11111111-1111-4111-8111-111111111111') }) } }
            'NonGraph' { return 'Synthetic connection page' }
            'Dns' { throw [Exception]::new('Authentication token acquisition failed',[Net.Http.HttpRequestException]::new('No such host is known.')) }
            'Timeout' { throw [TimeoutException]::new('Authentication token request timed out.') }
            'Always401' { throw [Net.Http.HttpRequestException]::new('Token rejected',$null,[Net.HttpStatusCode]::Unauthorized) }
            'Auth400' { throw [Net.Http.HttpRequestException]::new('invalid_grant: AADSTS70043: The refresh token has expired',$null,[Net.HttpStatusCode]::BadRequest) }
        }
        [pscustomobject]@{value=@([pscustomobject]@{id='11111111-1111-4111-8111-111111111111'})}
    }
    foreach($case in @(
        @{Mode='Cached';Kind='AuthResult';Connects=1;Probes=1}
        @{Mode='Missing';Kind='AuthResult';Connects=1;Probes=1}
        @{Mode='EmptyTenant';Kind='AuthResult';Connects=1;Probes=1}
        @{Mode='NoContent';Kind='Error';Connects=1;Probes=1;Category='Unknown'}
        @{Mode='Incomplete';Kind='Error';Connects=1;Probes=1;Category='Unknown'}
        @{Mode='ArrayId';Kind='Error';Connects=1;Probes=1;Category='Unknown'}
        @{Mode='NonGraph';Kind='Error';Connects=1;Probes=1;Category='Unknown'}
        @{Mode='Dns';Kind='Error';Connects=1;Probes=1;Category='Connectivity'}
        @{Mode='Timeout';Kind='Error';Connects=1;Probes=1;Category='Timeout'}
        @{Mode='Always401';Kind='Error';Connects=1;Probes=1;Category='Authentication'}
        @{Mode='Auth400';Kind='Error';Connects=1;Probes=1;Category='Authentication'}
        @{Mode='WrongAccount';Kind='Error';Connects=1;Probes=0;Category='Authentication'}
    )) {
        $authFixture=@{Mode=$case.Mode;Connects=0;Probes=0;Uri=''}
        $result=@(& $worker 'contoso.com' '11111111-1111-4111-8111-111111111111' 'admin@contoso.com' @('Device.Read.All') 'unused fixture' '2.38.0')
        Assert-True -Condition ($result.Count -eq 1 -and $result[0].Kind -eq $case.Kind -and $authFixture.Connects -eq $case.Connects -and $authFixture.Probes -eq $case.Probes) -Name "Reconnect requires a live response and reconnects only once when needed: $($case.Mode)"
        if($case.Kind -eq 'AuthResult') {
            Assert-True -Condition ([bool]$result[0].ConnectionVerified -and $authFixture.Uri -eq 'https://graph.microsoft.com/v1.0/devices?$select=id&$top=1') -Name "Connection success is backed by a metadata-only probe: $($case.Mode)"
        }
        else {
            $failure=$result[0]
            Assert-Equal -Actual (Get-GraphFailureCategory -ErrorCode $failure.ErrorCode -Message $failure.Message -StatusCode $failure.StatusCode) -Expected $case.Category -Name "Nested SDK errors retain their real failure category: $($case.Mode)"
        }
        if($case.Connects -gt 0) {
            Assert-True -Condition ($authFixture.ConnectionArguments.ContextScope -eq 'CurrentUser' -and $authFixture.ConnectionArguments.UseDeviceCode -and ($authFixture.ConnectionArguments.Scopes -join ',') -eq 'Device.Read.All') -Name "Reconnect preserves the configured scopes and reusable cache: $($case.Mode)"
        }
    }
}

foreach($case in @(
    @{Code='AuthenticationFailed';Message='Token acquisition failed: No such host is known';Status=$null;Category='Connectivity'}
    @{Code='AuthenticationFailed';Message='Token request timed out';Status=$null;Category='Timeout'}
    @{Code='AuthenticationFailed';Message='Token acquisition failed';Status=$null;Category='Unknown'}
    @{Code='MsalUiRequiredException';Message='interaction_required';Status=$null;Category='Authentication'}
    @{Code='InvalidAuthenticationToken';Message='synthetic';Status=$null;Category='Authentication'}
    @{Code='InvalidAuthenticationToken';Message='No such host is known';Status=401;Category='Authentication'}
    @{Code='invalid_grant';Message='AADSTS70043: The refresh token has expired';Status=400;Category='Authentication'}
    @{Code='BadRequest';Message='token property is invalid';Status=400;Category='Unknown'}
    @{Code='consent_required';Message='AADSTS65001';Status=400;Category='Consent'}
    @{Code='invalid_grant';Message='AADSTS65001: consent_required';Status=400;Category='Consent'}
    @{Code='invalid_grant';Message='AADSTS65001';Status=$null;Category='Consent'}
    @{Code='InvalidAuthenticationToken';Message='token unavailable';Status=503;Category='Service'}
    @{Code='AuthenticationFailed';Message='token permission check';Status=403;Category='Permission'}
    @{Code='ProxyAuthenticationRequired';Message='token request';Status=407;Category='Connectivity'}
    @{Code='NetworkAuthenticationRequired';Message='token request';Status=511;Category='Connectivity'}
    @{Code='HttpRequestException';Message='The proxy tunnel request failed';Status=$null;Category='Connectivity'}
    @{Code='WebException';Message='The remote name could not be resolved';Status=$null;Category='Connectivity'}
)) {
    Assert-Equal -Actual (Get-GraphFailureCategory -ErrorCode $case.Code -Message $case.Message -StatusCode $case.Status) -Expected $case.Category -Name "Failure classification avoids guessed token expiry: $($case.Code)/$($case.Category)"
}

$failure = try { throw [InvalidOperationException]::new('Private synthetic response detail') } catch { ConvertTo-GraphOperationError $_ }
Assert-True -Condition ($failure.Kind -eq 'Error' -and $failure.ErrorCode -eq 'Unknown' -and
    ($failure | ConvertTo-Json) -notmatch 'Private synthetic') -Name 'Worker errors return safe classifications without retaining raw SDK text'

Assert-True -Condition ((Get-WorkbenchTimeoutSeconds @{} 'RevealSeconds' 20) -eq 20 -and
    (Get-WorkbenchTimeoutSeconds @{RevealSeconds='0'} 'RevealSeconds' 20) -eq 0) -Name 'Missing timeout settings use their defaults and explicit zero still expires immediately'
foreach ($value in @(-1,'later',[long]::MaxValue)) {
    $rejected = $false
    try { $null = Get-WorkbenchTimeoutSeconds @{ClipboardClearSeconds=$value} 'ClipboardClearSeconds' 45 } catch { $rejected = $true }
    Assert-True -Condition $rejected -Name 'Unusable clipboard timeout is rejected before a protected copy can start'
}
