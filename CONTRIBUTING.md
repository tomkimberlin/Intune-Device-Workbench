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
pwsh.exe -NoLogo -NoProfile -STA -File .\M365Workbench.ps1 -DemoMode
pwsh.exe -NoLogo -NoProfile -File .\Tests\Test-M365Workbench.ps1
```

## Pull requests

- Keep changes focused and explain the operator workflow they improve.
- Add or update offline tests for behavior changes.
- Use only `contoso` identities, reserved example IDs, and explicit `DEMO-DEVICE-*` fixture names.
- Do not commit local settings, tokens, logs, tenant exports, production screenshots, real device details, or recovery material.
- Do not add Graph write permissions or device actions without documenting permission scope, confirmation behavior, failure handling, and a safe test strategy.
- Run the complete offline suite before submission.

By contributing, you agree that your contribution is licensed under the project's MIT License.
