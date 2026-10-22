# Contributing

Thanks for helping improve Intune Device Workbench.

## Before opening an issue

- Search existing issues first.
- Use the security process in [SECURITY.md](SECURITY.md) for vulnerabilities.
- Remove all production tenant data from descriptions, logs, and screenshots.
- Reproduce UI problems in `-DemoMode` whenever possible.

## Development setup

The project targets Windows PowerShell 7 and WPF. Demo mode and the test suite are offline and do not require a tenant:

```powershell
pwsh.exe -NoLogo -NoProfile -STA -File .\IntuneDeviceWorkbench.ps1 -DemoMode
pwsh.exe -NoLogo -NoProfile -File .\Tests\Test-IntuneDeviceWorkbench.ps1
```

Use a dedicated checkout and keep development dependencies and generated files separate from other applications. The offline suite needs PowerShell and Windows/WPF; it does not install modules or need a Graph connection. It creates a unique system temporary directory and removes its generated files on exit. CI runs in a disposable Windows runner and retains its synthetic preview artifact for three days.

The demo is a desktop process: close its window to stop it. There is no development server or background service to stop. Cleanup should remove only your disposable checkout and its generated files; preserve any existing ignored settings securely and leave other applications' environments alone.

The current entry points are `IntuneDeviceWorkbench.ps1`, `Launch-IntuneDeviceWorkbench.cmd`, and `Tests/Test-IntuneDeviceWorkbench.ps1`. The older entry points forward to these. Existing settings, internal module/asset filenames, launcher storage and Windows app identity are retained for upgrade compatibility; they are not separate applications.

Use the [Windows smoke-test checklist](docs/WINDOWS-SMOKE-TEST.md) for interactive validation and remaining native limits.

## Pull requests

- Keep changes focused and explain the operator workflow they improve.
- Add or update offline tests for behavior changes.
- Use only `contoso` identities, reserved example IDs, and explicit `DEMO-DEVICE-*` fixture names.
- Do not commit local settings, tokens, logs, tenant exports, production screenshots, real device details, or recovery material.
- Do not add Graph write permissions or device actions without documenting permission scope, confirmation behavior, failure handling, and a safe test strategy.
- Run the complete offline suite before submission.

By contributing, you agree that your contribution is licensed under the project's MIT License.
