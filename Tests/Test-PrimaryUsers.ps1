# Synthetic assignment data only. Never use enrollment identity as primary user.
& {
    $device=[pscustomobject]@{id='11111111-1111-4111-8111-111111111111';azureADDeviceId='22222222-2222-4222-8222-222222222222';deviceName='DEMO-DEVICE-SHARED';operatingSystem='Windows';userDisplayName='Enrollment User';userPrincipalName='enrollment@contoso.com'}
    $map=@{}; $map[$device.id]=@()
    $row=Merge-IntuneLapsDeviceData -ManagedDevices @($device) -PrimaryUsersByManagedDeviceId $map
    Assert-True -Condition ($row.PrimaryUser -eq 'Unassigned' -and $row.UserPrincipalName -eq '' -and -not $row.SearchText.Contains('enrollment')) -Name 'Explicitly empty primary-user assignment never falls back to enrollment name, email, or search text'
    $map[$device.id]=@([pscustomobject]@{displayName='Assigned User';userPrincipalName='assigned@contoso.com'})
    $row=Merge-IntuneLapsDeviceData -ManagedDevices @($device) -PrimaryUsersByManagedDeviceId $map
    Assert-True -Condition ($row.PrimaryUser -eq 'Assigned User' -and $row.UserPrincipalName -eq 'assigned@contoso.com' -and $row.SearchText.Contains('assigned@contoso.com') -and -not $row.SearchText.Contains('enrollment')) -Name 'Actual assignment supplies table, detail email, and search even when enrollment identity differs'
    $map[$device.id]=@([pscustomobject]@{displayName='';userPrincipalName='assigned@contoso.com'},[pscustomobject]@{id='33333333-3333-4333-8333-333333333333'})
    $row=Merge-IntuneLapsDeviceData -ManagedDevices @($device) -PrimaryUsersByManagedDeviceId $map
    Assert-Equal -Actual $row.PrimaryUser -Expected 'assigned@contoso.com; Assigned user (details unavailable)' -Name 'Multiple and partially disclosed assignments are not mislabeled Unassigned'
    $row=Merge-IntuneLapsDeviceData -ManagedDevices @($device)
    Assert-True -Condition ($row.PrimaryUser -eq 'Unavailable' -and $row.UserPrincipalName -eq '') -Name 'An unknown assignment is distinct from an explicitly empty assignment'
}

# Import the actual helper into this isolated test scope so Graph can be mocked
# without modifying the module, authenticating, or making network requests.
& {
    $coreAst=[Management.Automation.Language.Parser]::ParseFile($modulePath,[ref]$null,[ref]$null)
    foreach($name in @('Get-PropertyValue','ConvertTo-DeviceId','Get-IntunePrimaryUserMap')) {
        . ([scriptblock]::Create($coreAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true).Extent.Text))
    }
    $devices=@(1..21 | ForEach-Object {[pscustomobject]@{id=('11111111-1111-4111-8111-{0:000000000000}' -f $_);operatingSystem='Windows'}})
    $script:PrimaryFixtureMode='Normal'; $script:PrimaryFixtureCalls=0; $script:PrimaryFixtureReadOnly=$true; $script:PrimaryFixtureMaxBatch=0
    function Invoke-MgGraphRequest {
        param($Method,$Uri,$Body,$ContentType,$OutputType,$ErrorAction)
        $script:PrimaryFixtureCalls++
        $requests=@(($Body | ConvertFrom-Json).requests)
        $script:PrimaryFixtureMaxBatch=[Math]::Max($script:PrimaryFixtureMaxBatch,$requests.Count)
        $script:PrimaryFixtureReadOnly=$script:PrimaryFixtureReadOnly -and $Method -eq 'POST' -and $Uri -eq 'https://graph.microsoft.com/v1.0/$batch' -and @($requests | Where-Object {$_.method -ne 'GET' -or $_.url -notmatch '^/deviceManagement/managedDevices/[a-f0-9-]+/users\?'}).Count -eq 0
        $responses=@(foreach($request in $requests) {
            $deviceId=$request.url.Split('/')[3]
            $page=[pscustomobject]@{value=@([pscustomobject]@{id=$deviceId;displayName=$deviceId;userPrincipalName='assigned@contoso.com'})}
            $status=200
            switch($script:PrimaryFixtureMode) {
                Empty {$page.value=@()}
                MissingValue {$page=[pscustomobject]@{}}
                NullValue {$page.value=$null}
                BlankContinuation {$page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue ' '}
                ArrayContinuation {$page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue @()}
                BadUser {$page.value=@([pscustomobject]@{displayName='Not identifiable'})}
                Pagination {
                    if($request.url -notmatch 'skiptoken') { $page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue ('https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/'+$deviceId+'/users?$skiptoken=page2') }
                }
                UnsafePage {$page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue $script:PrimaryFixtureNextLink}
                Cycle {$page | Add-Member -NotePropertyName '@odata.nextLink' -NotePropertyValue ('https://graph.microsoft.com/v1.0'+$request.url)}
                Status {$status=$script:PrimaryFixtureStatus}
            }
            [pscustomobject]@{id=$request.id;status=$status;body=$page}
        })
        if($script:PrimaryFixtureMode -eq 'MissingResponse') {$responses=@()}
        if($script:PrimaryFixtureMode -eq 'DuplicateResponse') {$responses[1].id=$responses[0].id}
        if($script:PrimaryFixtureMode -eq 'UnknownResponse') {$responses[0].id='unknown'}
        [array]::Reverse($responses)
        return [pscustomobject]@{responses=$responses}
    }
    $map=Get-IntunePrimaryUserMap -ManagedDevices ($devices + $devices[0] + [pscustomobject]@{id='ignored';operatingSystem='macOS'})
    Assert-True -Condition ($map.Count -eq 21 -and $script:PrimaryFixtureCalls -eq 2 -and $script:PrimaryFixtureMaxBatch -eq 20 -and $script:PrimaryFixtureReadOnly) -Name 'Primary-user reads use GET-only batches of at most 20, deduplicate IDs, and skip non-Windows devices'
    Assert-True -Condition (@($devices | Where-Object {$map[$_.id][0].displayName -ne $_.id}).Count -eq 0) -Name 'Out-of-order batch responses stay associated with the correct device'
    $script:PrimaryFixtureMode='Empty'
    $map=Get-IntunePrimaryUserMap -ManagedDevices @($devices[0])
    Assert-True -Condition ($map.ContainsKey($devices[0].id) -and $map[$devices[0].id].Count -eq 0) -Name 'Successful empty user collection is preserved as a known empty assignment'
    $script:PrimaryFixtureMode='Pagination';$script:PrimaryFixtureCalls=0
    $map=Get-IntunePrimaryUserMap -ManagedDevices @($devices[0])
    Assert-True -Condition ($map[$devices[0].id].Count -eq 2 -and $script:PrimaryFixtureCalls -eq 2) -Name 'Primary-user pagination is completed before publishing assignments'
    $alternate = [pscustomobject]@{ id=([guid]$devices[0].id).ToString('B'); operatingSystem='Windows' }
    $map = Get-IntunePrimaryUserMap -ManagedDevices @($alternate)
    Assert-True -Condition ($map[$alternate.id].Count -eq 2 -and $script:PrimaryFixtureReadOnly) -Name 'Primary-user requests use canonical GUIDs while results retain the input record ID'
    foreach($mode in @('MissingValue','NullValue','BlankContinuation','ArrayContinuation','BadUser','MissingResponse','DuplicateResponse','UnknownResponse','Cycle')) {
        $script:PrimaryFixtureMode=$mode; $rejected=$false
        try {$null=Get-IntunePrimaryUserMap -ManagedDevices @($devices[0],$devices[1])} catch {$rejected=$true}
        Assert-True -Condition $rejected -Name "Invalid primary-user response is rejected instead of becoming Unassigned: $mode"
    }
    foreach($status in @(401,403,404,429,503)) {
        $script:PrimaryFixtureMode='Status';$script:PrimaryFixtureStatus=$status;$caughtStatus=0
        try {$null=Get-IntunePrimaryUserMap -ManagedDevices @($devices[0])} catch {$caughtStatus=$_.Exception.ResponseStatusCode}
        Assert-Equal -Actual $caughtStatus -Expected $status -Name "Batch subrequest failure retains its HTTP status for normal inventory recovery: $status"
    }
    $script:PrimaryFixtureMode='UnsafePage'
    foreach($url in @('https://example.com/v1.0/users','http://graph.microsoft.com/v1.0/users','https://graph.microsoft.com:444/v1.0/users','https://graph.microsoft.com/v1.0/users','/v1.0/users')) {
        $script:PrimaryFixtureNextLink=$url;$script:PrimaryFixtureCalls=0;$rejected=$false
        try {$null=Get-IntunePrimaryUserMap -ManagedDevices @($devices[0])} catch {$rejected=$true}
        Assert-True -Condition ($rejected -and $script:PrimaryFixtureCalls -eq 1) -Name "Primary-user pagination cannot leave the original relationship: $url"
    }
    $script:PrimaryFixtureCalls=0;$rejected=$false
    try {$null=Get-IntunePrimaryUserMap -ManagedDevices @([pscustomobject]@{id='invalid/path';operatingSystem='Windows'})} catch {$rejected=$true}
    Assert-True -Condition ($rejected -and $script:PrimaryFixtureCalls -eq 0) -Name 'Invalid managed-device IDs cannot enter primary-user requests'
    $empty=Get-IntunePrimaryUserMap -ManagedDevices @()
    Assert-True -Condition ($empty.Count -eq 0 -and $script:PrimaryFixtureCalls -eq 0) -Name 'Empty inventory makes no primary-user requests'
}
