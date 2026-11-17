param($TenantId, $ExpectedTenantObjectId, $ExpectedAccount, $RequiredScopes, $CoreModulePath, $MinimumGraphVersion, $PowerShellExecutable, $Nonce, $ChildScriptPath, $CancelEvent, $TimeoutSeconds)

$ErrorActionPreference = 'Stop'
Import-Module $CoreModulePath

$process = $null
$deviceCodeObserved = $false
$childStatus = $null
$childErrorCode = $null
try {
    $config = @{
        TenantId                = [string]$TenantId
        ExpectedTenantObjectId  = [string]$ExpectedTenantObjectId
        ExpectedAccount         = [string]$ExpectedAccount
        RequiredScopes          = [string[]]$RequiredScopes
        CoreModulePath          = [string]$CoreModulePath
        MinimumGraphVersion     = [string]$MinimumGraphVersion
        Nonce                   = [string]$Nonce
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$PowerShellExecutable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.ArgumentList.Add('-NoLogo')
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-NonInteractive')
    $startInfo.ArgumentList.Add('-File')
    $startInfo.ArgumentList.Add($ChildScriptPath)
    $startInfo.Environment['M365WB_VERIFY_CONFIG'] = $config | ConvertTo-Json -Compress

    $process = [Diagnostics.Process]::Start($startInfo)
    # Drain SDK diagnostics without retaining their contents.
    $null = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $sentinelPrefix = "M365WB_VERIFY_RESULT::$Nonce::"

    $lineTask = $process.StandardOutput.ReadLineAsync()
    while ($true) {
        if ($CancelEvent.WaitOne(0)) {
            [pscustomobject]@{ Kind = 'VerificationCanceled' }
            return
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge [double]$TimeoutSeconds) {
            [pscustomobject]@{ Kind = 'VerificationError'; ErrorCode = 'VerificationTimedOut' }
            return
        }
        if ($null -eq $lineTask) {
            # Closing stdout and exiting are separate events.
            if ($process.WaitForExit(100)) { break }
            continue
        }
        if (-not $lineTask.Wait(100)) { continue }
        $line = $lineTask.GetAwaiter().GetResult()
        if ($null -eq $line) {
            $lineTask = $null
            continue
        }
        $lineTask = $process.StandardOutput.ReadLineAsync()

        $deviceCode = Get-DeviceCodeFromMessage -Message $line
        if ($null -ne $deviceCode) {
            $deviceCodeObserved = $true
            Write-Output $line
            continue
        }

        if ($line.StartsWith($sentinelPrefix, [StringComparison]::Ordinal)) {
            try {
                $payload = $line.Substring($sentinelPrefix.Length) | ConvertFrom-Json
                $childStatus = [string]$payload.Status
                $childErrorCode = [string]$payload.ErrorCode
            }
            catch {
                $childStatus = 'InvalidResult'
            }
        }
    }

    if ($CancelEvent.WaitOne(0)) {
        [pscustomobject]@{ Kind = 'VerificationCanceled' }
        return
    }
    if ($process.ExitCode -eq 0 -and $childStatus -eq 'Verified' -and $deviceCodeObserved) {
        [pscustomobject]@{ Kind = 'MicrosoftVerificationResult' }
        return
    }
    if ($process.ExitCode -eq 0 -and $childStatus -eq 'Verified' -and -not $deviceCodeObserved) {
        [pscustomobject]@{ Kind = 'VerificationError'; ErrorCode = 'InteractiveVerificationNotObserved' }
        return
    }

    [pscustomobject]@{
        Kind = 'VerificationError'
        ErrorCode = if ([string]::IsNullOrWhiteSpace($childErrorCode)) { 'MicrosoftVerificationFailed' } else { $childErrorCode }
    }
}
catch {
    [pscustomobject]@{ Kind = 'VerificationError'; ErrorCode = 'MicrosoftVerificationFailed' }
}
finally {
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        }
        catch [InvalidOperationException] { } # The process exited before Kill.
        finally { $process.Dispose() }
    }
}
