# Advance the same clock used by the UI without waiting on Windows or signing in.
& {
    foreach ($name in @('Set-SecretVerificationGranted','Set-RecentInteractiveAuthentication','Use-RecentInteractiveAuthentication','Test-SecretVerificationGeneration','Clear-SecretVerificationState')) {
        $definition = $mainAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $clock = @{ Now=[DateTimeOffset]::UnixEpoch }
    function Get-SensitiveClockNow { $clock.Now }
    $secretVerificationMode = 'Preferred'
    $secretVerificationSeconds = 600
    $script:SecretVerificationGeneration = 0
    $script:SecretVerifiedUntil = [DateTimeOffset]::MinValue
    $script:RecentInteractiveAuthenticationUntil = [DateTimeOffset]::MinValue
    $script:LocalVerificationCancellation = $null
    $script:MicrosoftVerificationCancelEvent = $null

    $null = Set-RecentInteractiveAuthentication -ExpectedGeneration 0
    Assert-True -Condition (-not (Test-SecretVerificationGeneration 0)) -Name 'A startup sign-in alone does not grant recovery access'
    $clock.Now = $clock.Now.AddSeconds(599)
    Assert-True -Condition ((Use-RecentInteractiveAuthentication 0) -and (Test-SecretVerificationGeneration 0)) -Name 'The fallback can use the remaining second of a recent interactive sign-in'
    $clock.Now = $clock.Now.AddSeconds(1)
    Assert-True -Condition (-not (Test-SecretVerificationGeneration 0) -and -not (Use-RecentInteractiveAuthentication 0)) -Name 'Both grants expire at the original deadline, including after reuse'
    $null = Set-SecretVerificationGranted -ExpectedGeneration 0
    Assert-True -Condition (Test-SecretVerificationGeneration 0) -Name 'A fresh successful local verification starts a new fixed window'
    Clear-SecretVerificationState
    Assert-True -Condition (-not (Set-RecentInteractiveAuthentication 0) -and -not (Set-SecretVerificationGranted 0) -and -not (Test-SecretVerificationGeneration 1)) -Name 'Session revocation rejects late completions and clears previously granted access'
    $secretVerificationMode = 'Disabled'
    Assert-True -Condition ((Test-SecretVerificationGeneration 1) -and -not (Test-SecretVerificationGeneration 0) -and -not (Test-SecretVerificationGeneration $null)) -Name 'Explicit opt-out still rejects actions from a previous session or without a generation'
}
