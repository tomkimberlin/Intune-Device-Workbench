# Run the actual authentication operation in an isolated runspace. Replace only
# the SDK boundary; no installed Graph module, cached credentials, or tenant is used.
& {
    $authNode = $mainAst.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$authOperationScript'
    }, $true)

    function Invoke-AuthenticationFixture {
        param([string]$Scenario)
        $worker = [PowerShell]::Create()
        try {
            $null = $worker.AddScript({
                param($OperationText, $ModulePath, $Scenario)
                $script:ConnectCalls = 0
                $script:ConnectArguments = $null
                $script:SessionUsable = $Scenario -eq 'Cached'
                $script:Context = [pscustomobject]@{
                    Account = 'admin@contoso.com'
                    TenantId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
                    AuthType = 'Delegated'
                    Scopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All')
                }
                if ($Scenario -eq 'FirstSignIn') { $script:Context = $null }
                function Import-Module {
                    param($Name, [switch]$Force, $MinimumVersion, $ErrorAction)
                    if ($Name -eq 'Microsoft.Graph.Authentication') { return }
                    Microsoft.PowerShell.Core\Import-Module -Name $Name -Force:$Force -ErrorAction Stop
                }
                function Get-MgContext { $script:Context }
                function Connect-MgGraph {
                    param($TenantId, [switch]$UseDeviceCode, $Scopes, $ContextScope, [switch]$NoWelcome, $ErrorAction)
                    $script:ConnectCalls++
                    $script:ConnectArguments = @{
                        TenantId = $TenantId; UseDeviceCode = [bool]$UseDeviceCode
                        Scopes = @($Scopes); ContextScope = $ContextScope
                    }
                    if ($Scenario -eq 'AuthenticationFails') {
                        throw [Net.Http.HttpRequestException]::new('Synthetic expired sign-in', $null, [Net.HttpStatusCode]::Unauthorized)
                    }
                    $script:Context = [pscustomobject]@{
                        Account = 'admin@contoso.com'
                        TenantId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
                        AuthType = 'Delegated'
                        Scopes = @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All')
                    }
                    if ($Scenario -ne 'Cached') {
                        # The SDK's DeviceCodeCallback writes code.Message to output.
                        'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code A1B2C3D4E to authenticate.'
                    }
                    switch ($Scenario) {
                        'WrongAccount' { $script:Context.Account = 'other@contoso.com' }
                        'WrongTenant' { $script:Context.TenantId = '11111111-1111-4111-8111-111111111111' }
                        'MissingScopes' { $script:Context.Scopes = @('Device.Read.All') }
                        'NotDelegated' { $script:Context.AuthType = 'AppOnly' }
                    }
                    $script:SessionUsable = $true
                }
                $output = @(& ([scriptblock]::Create($OperationText)) 'contoso.onmicrosoft.com' 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' 'admin@contoso.com' @('Device.Read.All', 'DeviceManagementManagedDevices.Read.All') $ModulePath '2.38.0')
                [pscustomobject]@{
                    Results = @($output | Where-Object { $_.PSObject.Properties['Kind'] })
                    Codes = @($output | ForEach-Object { Get-DeviceCodeFromMessage -Message $_ } | Where-Object { $null -ne $_ })
                    ConnectCalls = $script:ConnectCalls
                    ConnectArguments = $script:ConnectArguments
                    SessionUsable = $script:SessionUsable
                }
            }).AddArgument($authNode.Right.Expression.Value).AddArgument($modulePath).AddArgument($Scenario)
            $output = @($worker.Invoke())
            if ($worker.HadErrors) { throw 'Authentication fixture failed outside the operation result path.' }
            return $output[0]
        }
        finally { $worker.Dispose() }
    }

    $stale = Invoke-AuthenticationFixture 'Expired'
    Assert-True -Condition ($stale.ConnectCalls -eq 1 -and $stale.SessionUsable -and $stale.Results.Count -eq 1 -and $stale.Results[0].Kind -eq 'AuthResult') -Name 'Reconnect establishes authentication even when an expired session still has matching account, tenant, and scope metadata'
    Assert-True -Condition ($stale.Codes.Count -eq 1 -and $stale.Codes[0].UserCode -eq 'A1B2C3D4E') -Name 'A fresh reconnect device-code prompt reaches the existing UI output stream'

    $cached = Invoke-AuthenticationFixture 'Cached'
    Assert-True -Condition ($cached.ConnectCalls -eq 1 -and $cached.Results.Count -eq 1 -and $cached.Results[0].Kind -eq 'AuthResult' -and $cached.Codes.Count -eq 0) -Name 'Sign-in lets the SDK reuse a valid cache without inventing an interactive verification grant'
    $arguments = $cached.ConnectArguments
    Assert-True -Condition ($null -ne $arguments -and $arguments.ContextScope -eq 'CurrentUser' -and $arguments.UseDeviceCode -and $arguments.TenantId -eq 'contoso.onmicrosoft.com' -and ($arguments.Scopes -join ',') -eq 'Device.Read.All,DeviceManagementManagedDevices.Read.All') -Name 'Reconnect preserves the configured tenant, scopes, device-code flow, and secure CurrentUser cache'

    $failed = Invoke-AuthenticationFixture 'AuthenticationFails'
    Assert-True -Condition ($failed.ConnectCalls -eq 1 -and $failed.Results.Count -eq 1 -and $failed.Results[0].Kind -eq 'Error' -and $failed.Results[0].StatusCode -eq 401 -and -not $failed.SessionUsable) -Name 'Failed authentication cannot become sign-in success just because old context metadata still matches'

    foreach ($reason in @('WrongAccount', 'WrongTenant', 'MissingScopes', 'NotDelegated')) {
        $rejected = Invoke-AuthenticationFixture $reason
        Assert-True -Condition ($rejected.ConnectCalls -eq 1 -and $rejected.Results.Count -eq 1 -and $rejected.Results[0].Kind -eq 'Error' -and $rejected.Results[0].ErrorCode -eq $reason) -Name "The newly authenticated context must still pass $reason validation"
    }
    $first = Invoke-AuthenticationFixture 'FirstSignIn'
    Assert-True -Condition ($first.ConnectCalls -eq 1 -and $first.Results.Count -eq 1 -and $first.Results[0].Kind -eq 'AuthResult' -and $first.Codes.Count -eq 1) -Name 'First sign-in without a previous Graph context still completes normally'
}
