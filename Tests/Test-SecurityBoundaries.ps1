# Runs inside Test-IntuneDeviceWorkbench.ps1. All Graph data and secrets below are synthetic.
function Get-OperationFixture {
    param([string]$Name)
    $assignment = $mainAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq ('$' + $Name)
    }, $true)
    return [scriptblock]::Create($assignment.Right.Expression.Value)
}

foreach ($outcome in @('Canceled', 'TimedOut', 'Error', 'RetriesExhausted')) {
    $decision = Get-SecretVerificationDecision -Mode Preferred -VerifiedUntil $verificationNow.AddMinutes(1) -LocalResult $outcome -Now $verificationNow
    Assert-True -Condition ($decision -ne 'Grant') -Name "Explicit $outcome cannot be overridden by an existing verification grant"
}
Assert-True -Condition (-not (Test-BitLockerRecoveryKey ('١٢٣٤٥٦-' * 7 + '١٢٣٤٥٦'))) -Name 'Recovery-key validation rejects non-ASCII digits'
Assert-True -Condition (-not (Test-BitLockerRecoveryKey (('123456-' * 7 + '123456') + "`n"))) -Name 'Recovery-key validation rejects a trailing newline'

$lapsOperation = Get-OperationFixture 'credentialOperationScript'
$keyOperation = Get-OperationFixture 'bitLockerKeyOperationScript'
$inventoryOperation = Get-OperationFixture 'inventoryOperationScript'
$deviceIdFixture = '11111111-1111-4111-8111-111111111111'
$keyIdFixture = '22222222-2222-4222-8222-222222222222'
$differentIdFixture = '33333333-3333-4333-8333-333333333333'

function New-LapsResponseFixture {
    param([string]$Id = $deviceIdFixture, [string]$Payload = $encodedPassword)
    [pscustomobject]@{
        id = $Id; deviceName = 'DEMO-DEVICE-ALPHA'
        credentials = @(
            [pscustomobject]@{ accountName='DemoAdmin'; accountSid='S-1-5-21-111-222-333-500'; backupDateTime='2026-09-01T12:00:00Z'; passwordBase64=$Payload }
            [pscustomobject]@{ accountName='OlderDemoAdmin'; accountSid='S-1-5-21-111-222-333-501'; backupDateTime='2026-08-01T12:00:00Z'; passwordBase64=$encodedPassword }
        )
    }
}
function New-KeyResponseFixture {
    param([string]$Id = $keyIdFixture, [string]$DeviceId = $deviceIdFixture, [string]$Key = ('123456-' * 7 + '123456'))
    [pscustomobject]@{ id=$Id; deviceId=$DeviceId; key=$Key; createdDateTime='2026-09-01T12:00:00Z'; volumeType='operatingSystemVolume' }
}

# Invoke the production operation bodies with a scoped Graph replacement, never a token.
& {
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $ErrorAction)
        $script:FixtureRequestCount++
        return $script:GraphResponseFixture
    }
    $script:FixtureRequestCount = 0
    $script:GraphResponseFixture = New-LapsResponseFixture
    $result = @(& $lapsOperation $deviceIdFixture $modulePath)
    Assert-True -Condition ($result.Count -eq 1 -and $result[0].Kind -eq 'CredentialResult' -and $result[0].Password -eq $plainPassword) -Name 'Actual LAPS operation decodes only the selected device response'
    Assert-True -Condition (@($script:GraphResponseFixture.credentials | Where-Object passwordBase64).Count -eq 0) -Name 'LAPS success releases encoded values from every returned credential'
    foreach ($badId in @($differentIdFixture, '', 'not-a-guid')) {
        $script:GraphResponseFixture = New-LapsResponseFixture -Id $badId
        $result = @(& $lapsOperation $deviceIdFixture $modulePath)
        Assert-True -Condition ($result.Count -eq 1 -and $result[0].Kind -eq 'Error') -Name 'Actual LAPS operation rejects mismatched or invalid response identity'
        Assert-True -Condition (@($script:GraphResponseFixture.credentials | Where-Object passwordBase64).Count -eq 0) -Name 'Rejected LAPS identity releases all encoded credential fields'
    }
    $script:GraphResponseFixture = New-LapsResponseFixture -Payload '!!!'
    $result = @(& $lapsOperation $deviceIdFixture $modulePath)
    Assert-True -Condition ($result[0].Kind -eq 'Error' -and @($script:GraphResponseFixture.credentials | Where-Object passwordBase64).Count -eq 0) -Name 'Malformed LAPS payload fails closed and releases all encoded fields'
    $before = $script:FixtureRequestCount
    $result = @(& $lapsOperation 'not-a-guid' $modulePath)
    Assert-True -Condition ($result[0].Kind -eq 'Error' -and $script:FixtureRequestCount -eq $before) -Name 'Invalid LAPS request makes no Graph call'

    $script:GraphResponseFixture = New-KeyResponseFixture
    $result = @(& $keyOperation $deviceIdFixture $keyIdFixture $modulePath)
    Assert-True -Condition ($result.Count -eq 1 -and $result[0].Kind -eq 'BitLockerKeyResult') -Name 'Actual BitLocker operation accepts a matching device and key ID'
    Assert-True -Condition ($null -eq $script:GraphResponseFixture.key) -Name 'BitLocker success releases the response secret field'
    foreach ($badResponse in @(
        (New-KeyResponseFixture -Id $differentIdFixture)
        (New-KeyResponseFixture -DeviceId $differentIdFixture)
        (New-KeyResponseFixture -Id '')
        (New-KeyResponseFixture -Key 'malformed')
    )) {
        $script:GraphResponseFixture = $badResponse
        $result = @(& $keyOperation $deviceIdFixture $keyIdFixture $modulePath)
        Assert-True -Condition ($result.Count -eq 1 -and $result[0].Kind -eq 'Error' -and $null -eq $badResponse.key) -Name 'Actual BitLocker operation rejects bad identity/payload and releases the response secret'
    }
    $before = $script:FixtureRequestCount
    $result = @(& $keyOperation $deviceIdFixture 'not-a-guid' $modulePath)
    Assert-True -Condition ($result[0].Kind -eq 'Error' -and $script:FixtureRequestCount -eq $before) -Name 'Invalid recovery-key request makes no Graph call'
}

& {
    function Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $ErrorAction)
        $script:FixtureRequestCount++
        $next = if ($script:PaginationFixture -eq 'Cycle') { $Uri } else { $script:PaginationFixture }
        return [pscustomobject]@{ value=@(); '@odata.nextLink'=$next }
    }
    foreach ($nextLink in @('https://example.com/v1.0/devices', 'http://graph.microsoft.com/v1.0/devices', 'https://graph.microsoft.com:444/v1.0/devices', '/v1.0/devices', 'Cycle')) {
        $script:PaginationFixture = $nextLink
        $script:FixtureRequestCount = 0
        $result = @(& $inventoryOperation $modulePath)
        Assert-True -Condition ($result.Count -eq 1 -and $result[0].Kind -eq 'Error' -and $script:FixtureRequestCount -eq 1) -Name "Inventory rejects unsafe pagination before following it: $nextLink"
    }
    $script:PaginationFixture = $null
    $script:FixtureRequestCount = 0
    $result = @(& $inventoryOperation $modulePath)
    Assert-True -Condition ($result.Count -eq 1 -and $result[0].Kind -eq 'InventoryResult' -and $script:FixtureRequestCount -eq 4) -Name 'Empty inventory terminates all four metadata collections normally'
}

$previewGuard = $mainAst.Find({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains("throw 'Preview rendering requires") }, $true)
& {
    $DemoMode = $false
    $RenderPreviewPath = 'unused.png'
    $blocked = $false
    try { & ([scriptblock]::Create($previewGuard.Extent.Text)) } catch { $blocked = $true }
    Assert-True -Condition ($blocked -and $previewGuard.Extent.StartLineNumber -lt 40) -Name 'Live preview is rejected before tenant configuration or authentication is loaded'
}
$ownerRejected = $false
try { [M365Workbench.Security.SecureClipboard]::SetSensitiveText('synthetic', [IntPtr]::Zero) } catch { $ownerRejected = $true }
Assert-True -Condition $ownerRejected -Name 'Clipboard rejects missing owner before touching Windows clipboard contents'

# Exercise the UI-thread session callback with no real lock or clipboard operation.
& {
    $script:RevocationsFixture = 0
    function Clear-SecretVerificationState { $script:RevocationsFixture++ }
    function Clear-SecretDisplay { }
    $hookAst = $mainAst.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$sessionMessageHook' }, $true)
    $hookBody = $hookAst.Right.Expression.Child.ScriptBlock.Extent.Text
    $hook = [scriptblock]::Create($hookBody.Substring(1, $hookBody.Length - 2))
    $handled = $false
    foreach ($eventCode in @(2, 4, 6, 7, 8, 1)) { $null = & $hook ([IntPtr]::Zero) 0x02B1 ([IntPtr]$eventCode) ([IntPtr]::Zero) ([ref]$handled) }
    Assert-Equal -Actual $script:RevocationsFixture -Expected 4 -Name 'Lock, logoff, and both disconnects revoke; connect/unlock never grant access'
}

# Compile the real clipboard algorithm against deterministic native-call shims.
# This tests races/OS contention without reading or overwriting the user's clipboard.
$nativeShims = @{
    OpenClipboard = 'private static bool OpenClipboard(IntPtr hWndNewOwner) { OpenAttempts++; return !Busy; }'
    CloseClipboard = 'private static bool CloseClipboard() { if (ReplaceOnClose) { Sequence++; ReplaceOnClose = false; } return true; }'
    EmptyClipboard = 'private static bool EmptyClipboard() { Sequence++; EmptyCount++; return true; }'
    SetClipboardData = 'private static IntPtr SetClipboardData(uint uFormat, IntPtr hMem) { Formats.Add(uFormat); if (uFormat == CfUnicodeText) { LastText = Marshal.PtrToStringUni(hMem); } Sequence++; Marshal.FreeHGlobal(hMem); return new IntPtr(1); }'
    RegisterClipboardFormat = 'private static uint RegisterClipboardFormat(string lpszFormat) { return lpszFormat == ExcludeFormatName ? 100u : lpszFormat == HistoryFormatName ? 101u : 102u; }'
    GetClipboardSequenceNumber = 'private static uint GetClipboardSequenceNumber() { return Sequence; }'
    IsWindow = 'private static bool IsWindow(IntPtr hWnd) { return hWnd != IntPtr.Zero; }'
    GlobalAlloc = 'private static IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes) { return Marshal.AllocHGlobal((int)dwBytes.ToUInt64()); }'
    GlobalLock = 'private static IntPtr GlobalLock(IntPtr hMem) { return hMem; }'
    GlobalUnlock = 'private static bool GlobalUnlock(IntPtr hMem) { return true; }'
    GlobalFree = 'private static IntPtr GlobalFree(IntPtr hMem) { Marshal.FreeHGlobal(hMem); return IntPtr.Zero; }'
}
$clipboardAlgorithm = [IO.File]::ReadAllText($clipboardPath).Replace('namespace M365Workbench.Security', 'namespace M365Workbench.TestDoubles')
$clipboardAlgorithm = [regex]::Replace($clipboardAlgorithm, '(?s)\[DllImport\([^\]]*\)\]\s*private static extern [^;]+;', {
    param($match)
    foreach ($method in $nativeShims.Keys) {
        if ($match.Value -match ('\b' + $method + '\(')) { return $nativeShims[$method] }
    }
    throw 'Unmapped native call in clipboard test adapter.'
})
$clipboardAlgorithm = $clipboardAlgorithm.Replace('private const uint CfUnicodeText', @'
public static string LastText;
        public static bool Busy;
        public static int OpenAttempts;
        public static bool ReplaceOnClose;
        public static uint Sequence = 1;
        public static int EmptyCount;
        public static System.Collections.Generic.List<uint> Formats = new System.Collections.Generic.List<uint>();
        private const uint CfUnicodeText
'@).Replace('Thread.Sleep(20 + (attempt * 15));', '/* deterministic contention: no real delay */')
Add-Type -TypeDefinition $clipboardAlgorithm
[M365Workbench.TestDoubles.SecureClipboard]::ReplaceOnClose = $true
[M365Workbench.TestDoubles.SecureClipboard]::SetSensitiveText('synthetic', [IntPtr]1)
$emptyCount = [M365Workbench.TestDoubles.SecureClipboard]::EmptyCount
Assert-True -Condition (-not [M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged() -and [M365Workbench.TestDoubles.SecureClipboard]::EmptyCount -eq $emptyCount) -Name 'Clipboard algorithm never claims/deletes a replacement arriving immediately after CloseClipboard'
Assert-Equal -Actual ([M365Workbench.TestDoubles.SecureClipboard]::Formats -join ',') -Expected '100,101,102,13' -Name 'History/cloud exclusions are attached before plaintext clipboard data'
[M365Workbench.TestDoubles.SecureClipboard]::SetSensitiveText('synthetic', [IntPtr]1)
[M365Workbench.TestDoubles.SecureClipboard]::Busy = $true
$busyRejected = $false
try { $null = [M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged() } catch { $busyRejected = $true }
[M365Workbench.TestDoubles.SecureClipboard]::Busy = $false
Assert-True -Condition ($busyRejected -and [M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged()) -Name 'Clipboard contention preserves ownership so a later retry can clear the secret'

[M365Workbench.TestDoubles.SecureClipboard]::SetSensitiveText('synthetic', [IntPtr]1)
[M365Workbench.TestDoubles.SecureClipboard]::Busy = $true
$attemptsBefore=[M365Workbench.TestDoubles.SecureClipboard]::OpenAttempts
$busyRejected=$false
try { $null=[M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged($false) } catch { $busyRejected=$true }
Assert-True -Condition ($busyRejected -and [M365Workbench.TestDoubles.SecureClipboard]::OpenAttempts -eq $attemptsBefore + 1) -Name 'Timer-driven clipboard cleanup makes one attempt without a blocking retry loop'
[M365Workbench.TestDoubles.SecureClipboard]::Busy = $false
Assert-True -Condition ([M365Workbench.TestDoubles.SecureClipboard]::ClearIfUnchanged($false)) -Name 'Nonblocking clipboard cleanup retains ownership until its successful retry'

& {
    function Process-OperationOutput { }
    function Get-SelectedDevice { return $null }
    function Set-AppStatus { param($Message) }
    function Get-SensitiveClockNow { return $script:TickTimeFixture }
    function Clear-SecretDisplay {
        param([switch]$PreservePasswordStatus, [switch]$PreserveBitLockerStatus)
        $script:DisplayClearedFixture++
        $script:CredentialExpiresAt = [DateTimeOffset]::MinValue
        $script:BitLockerExpiresAt = [DateTimeOffset]::MinValue
    }
    $tickAst = $mainAst.Find({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Expression.Extent.Text -eq '$pollTimer' -and $node.Member.Extent.Text -eq 'Add_Tick' }, $true)
    $tickBody = $tickAst.Arguments[0].ScriptBlock.Extent.Text
    $tick = [scriptblock]::Create($tickBody.Substring(1, $tickBody.Length - 2).Replace('[M365Workbench.Security.SecureClipboard]', '[M365Workbench.TestDoubles.SecureClipboard]'))
    $script:TickTimeFixture = $verificationNow
    $script:LocalVerificationTask = $null
    $script:ToastExpiresAt = [DateTimeOffset]::MinValue
    $script:ClipboardClearAt = $verificationNow.AddSeconds(-1)
    $script:ClipboardDeviceId = $deviceIdFixture
    $script:ClipboardKind = 'LAPS'
    $script:ClipboardRecoveryKeyId = $null
    $script:CredentialExpiresAt = $verificationNow.AddSeconds(-1)
    $script:BitLockerExpiresAt = [DateTimeOffset]::MinValue
    $script:DisplayClearedFixture = 0
    $PasswordText = [pscustomobject]@{ Text='••••••••••••••••' }
    $BitLockerKeyText = [pscustomobject]@{ Text='••••••-••••••' }
    [M365Workbench.TestDoubles.SecureClipboard]::SetSensitiveText('synthetic', [IntPtr]1)
    [M365Workbench.TestDoubles.SecureClipboard]::Busy = $true
    & $tick
    Assert-True -Condition ($script:ClipboardDeviceId -eq $deviceIdFixture -and $script:ClipboardClearAt -gt $script:TickTimeFixture) -Name 'Actual UI timer retains clipboard metadata and schedules retry when cleanup is busy'
    Assert-Equal -Actual $script:DisplayClearedFixture -Expected 1 -Name 'Busy clipboard cleanup does not prevent expired secrets from being hidden'
    [M365Workbench.TestDoubles.SecureClipboard]::Busy = $false
    $script:TickTimeFixture = $verificationNow.AddSeconds(2)
    & $tick
    Assert-True -Condition ($script:ClipboardClearAt -eq [DateTimeOffset]::MinValue -and $null -eq $script:ClipboardDeviceId) -Name 'Actual UI timer completes pending cleanup on its next successful attempt'
}
