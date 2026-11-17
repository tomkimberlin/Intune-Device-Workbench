# Exercise lookup with an empty fixture file. Only the installed PowerShell host
# is run by the separate compatibility-entry-point check.
& {
    $resolve = [Reflection.Assembly]::Load($launcherBytes).GetType('M365Workbench.Launcher').GetMethod('FindPowerShell', [Reflection.BindingFlags]'NonPublic, Static')
    $testExecutable = Join-Path $testRoot 'pwsh.exe'
    $previousDirectory = [Environment]::CurrentDirectory
    try {
        [IO.File]::WriteAllBytes($testExecutable, [byte[]]@())
        [Environment]::CurrentDirectory = $testRoot
        $entries = @('.', 'invalid|directory')
        if ($testRoot -match '^[A-Za-z]:\\') {
            $entries += $testRoot.Substring(0,2) + '.'
            $entries += $testRoot.Substring(2)
        }
        $entries += '"' + $testRoot + '"'
        $arguments = [object[]]::new(1)
        $arguments[0] = [string[]]$entries
        Assert-Equal -Actual ($resolve.Invoke($null, $arguments)) -Expected $testExecutable -Name 'Launcher skips working-directory-dependent paths and accepts a quoted absolute directory'
    }
    finally {
        [Environment]::CurrentDirectory = $previousDirectory
        if ([IO.File]::Exists($testExecutable)) { [IO.File]::Delete($testExecutable) }
    }

    $fixture = Join-Path $testRoot 'Launcher compatibility'
    $assets = Join-Path $fixture 'assets'
    $marker = Join-Path $fixture 'started.pid'
    $pendingMarker = Join-Path $fixture 'starting.pid'
    $scriptPath = Join-Path $fixture 'IntuneDeviceWorkbench.ps1'
    $launchFiles = @('Launch-IntuneDeviceWorkbench.cmd', 'Launch-M365Workbench.cmd', 'assets\M365Workbench.Launcher.cs')
    $process = $null
    try {
        $null = [IO.Directory]::CreateDirectory($assets)
        foreach ($file in $launchFiles) { [IO.File]::Copy((Join-Path $appRoot $file), (Join-Path $fixture $file)) }
        [IO.File]::WriteAllText($scriptPath, @'
if ($PSVersionTable.PSVersion -ge [version]'7.4' -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
    $pending = Join-Path $PSScriptRoot 'starting.pid'
    [IO.File]::WriteAllText($pending, [string]$PID)
    [IO.File]::Move($pending, (Join-Path $PSScriptRoot 'started.pid'))
    # Keep the child alive briefly so the test also covers a slow shutdown.
    Start-Sleep -Milliseconds 250
}
'@)
        $start = [Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), '/d /c Launch-M365Workbench.cmd')
        $start.WorkingDirectory = $fixture
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.Environment['ProgramFiles'] = Join-Path $fixture 'NoMachineInstall'
        $start.Environment['LOCALAPPDATA'] = Join-Path $fixture 'NoStoreInstall'
        $start.Environment['PATH'] = $PSHOME
        $process = [Diagnostics.Process]::Start($start)
        $exited = $process.WaitForExit(20000)
        if (-not $exited) { $process.Kill($true); throw 'The compatibility launcher timed out.' }
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while ($process.ExitCode -eq 0 -and -not [IO.File]::Exists($marker) -and $deadline.Elapsed.TotalSeconds -lt 10) {
            Start-Sleep -Milliseconds 50
        }
        Assert-True -Condition ($process.ExitCode -eq 0 -and [IO.File]::Exists($marker)) -Name 'Both batch entry points launch the script from a path with spaces when the standard install paths are absent'
        if ([IO.File]::Exists($marker)) {
            # The batch process has exited. Its PowerShell child can still own the
            # fixture as its working directory until Windows finishes closing it.
            $childId = [int][IO.File]::ReadAllText($marker)
            $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
            if ($null -ne $child) {
                try {
                    if (-not $child.WaitForExit(10000)) { throw 'The launcher test child did not exit.' }
                }
                finally { $child.Dispose() }
            }
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        foreach ($file in $launchFiles) { [IO.File]::Delete((Join-Path $fixture $file)) }
        [IO.File]::Delete($scriptPath)
        [IO.File]::Delete($pendingMarker)
        [IO.File]::Delete($marker)
        if ([IO.Directory]::Exists($assets)) { [IO.Directory]::Delete($assets) }
        if ([IO.Directory]::Exists($fixture)) { [IO.Directory]::Delete($fixture) }
    }
}
