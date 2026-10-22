# Intune Device Workbench

<img src="assets/M365Workbench.svg" width="72" alt="Intune Device Workbench icon">

[![Tests](https://github.com/tomkimberlin/Intune-Device-Workbench/actions/workflows/tests.yml/badge.svg)](https://github.com/tomkimberlin/Intune-Device-Workbench/actions/workflows/tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Intune Device Workbench is a LAPS-first Windows desktop utility for Microsoft Entra ID and Microsoft Intune device support. The current release provides a searchable Windows device inventory with on-demand Windows LAPS and BitLocker recovery.

![Device recovery workspace populated with fictional demo data](docs/device-recovery.png)

> **Status:** Early release. Device inventory and recovery are functional and covered by offline tests. The app currently performs Microsoft Graph reads only; device actions and other modules remain roadmap items.

## Why I built this

I built Intune Device Workbench because I find Intune slow, and navigating from one device to another in the portal is painful. I wanted a focused Windows desktop workspace for device inventory, Windows LAPS, and BitLocker recovery, with less time spent moving between portal pages during support work.

## What it does

- Searches Windows devices by name, user, UPN, serial number, model, or Entra device ID.
- Combines Intune managed-device data with Entra device, Windows LAPS, and BitLocker metadata.
- Displays actual Intune primary-user assignments; an empty assignment shows Unassigned, never the enrollment user.
- Identifies Entra-only records without assuming they are stale or safe to delete.
- Shows device, management, compliance, encryption, sync, and approximate Entra activity details, with a compact compliance badge beside the selected device name.
- Copies the selected device name, actual primary user/UPN, serial number, and OS for a support ticket, without recovery secrets.
- Preserves sorting and the selected recovery-key record across refreshes; a running refresh can be canceled without losing the previous inventory.
- Shows a compact BitLocker key ID with the full identifier on hover, and supports typing an ID prefix in the key picker.
- Opens the selected device directly in the Intune or Entra admin center.
- Retrieves one selected LAPS password or BitLocker recovery key only after an explicit copy or reveal action.
- Verifies the current Windows user before recovery access and uses a fresh Microsoft device-code verification when local verification is unavailable.
- Excludes copied secrets from Windows Clipboard History and Cloud Clipboard and clears them after a configurable interval.

All screenshots, tests, and demo records use fictional `contoso` identities and explicit `DEMO-DEVICE-*` identifiers.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7.4 or later
- `Microsoft.Graph.Authentication` 2.38.0 or later
- A Microsoft Entra work or school account in the configured tenant

Both the standard PowerShell installer and Microsoft Store installation are supported. The launcher also checks absolute directories on `PATH`. The window title identifies the current build as `2026.10.22`.

## Quick start

Clone the repository and install the Graph authentication module:

```powershell
git clone https://github.com/tomkimberlin/Intune-Device-Workbench.git
Set-Location .\Intune-Device-Workbench
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
```

Create the ignored local settings file:

```powershell
Copy-Item .\M365Workbench.settings.example.psd1 .\M365Workbench.settings.psd1
```

Replace the fictional tenant domain, tenant object ID, and expected administrator UPN in `M365Workbench.settings.psd1`, then launch:

```powershell
.\Launch-IntuneDeviceWorkbench.cmd
```

To install a desktop shortcut with the application icon and no console flash:

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Install-DesktopShortcut.ps1
```

Older `M365Workbench.ps1`, `Launch-M365Workbench.cmd`, and `Tests/Test-M365Workbench.ps1` entry points forward to the renamed commands. Existing settings, internal module/asset filenames, launcher storage and Windows app identity stay compatible. Update an existing checkout in place to keep its shortcuts working; rerun the shortcut installer for the new display name.

The app reuses Microsoft Graph's secure `CurrentUser` token cache when a valid delegated context already exists. If sign-in is required, it displays a device code and opens Microsoft's sign-in page in the default browser.

By default, the first recovery action asks Windows to verify the current user with an available PIN, biometric, or Windows Hello method. That verification is remembered in process memory for ten minutes. If local Windows verification is unavailable, a fresh interactive Microsoft sign-in completed during app startup can satisfy the fallback for the remainder of the same fixed window. Otherwise, the app displays a new Microsoft device code without replacing or clearing the reusable Graph session. Conditional Access determines whether the Microsoft step also requires MFA; the app does not claim that a device-code completion is inherently MFA.

These settings control that behavior:

| Setting | Default | Meaning |
| --- | --- | --- |
| `SecretVerificationMode` | `Preferred` | Use Windows verification first, then Microsoft verification only when Windows reports that local verification is unavailable. |
| `SecretVerificationSeconds` | `600` | Fixed verification window, from 60 to 3600 seconds. It does not slide with continued use. |

`Required` disables the Microsoft fallback and permits recovery only after local Windows verification. `Disabled` is an explicit administrative opt-out. Windows 10 remains supported through feature detection and the Microsoft fallback when the desktop Windows verification interface is unavailable.

## Try it without a tenant

Demo mode is entirely local. It does not load a settings file, authenticate, or call Microsoft Graph.

```powershell
pwsh.exe -NoLogo -NoProfile -STA -File .\IntuneDeviceWorkbench.ps1 -DemoMode
```

Off-screen preview rendering requires `-DemoMode`; live tenant data cannot be exported through the preview switch.

## Microsoft Graph permissions

The current workspace requests these delegated scopes together:

| Scope | Purpose |
| --- | --- |
| `Device.Read.All` | Entra device information |
| `DeviceManagementManagedDevices.Read.All` | Intune managed-device inventory |
| `DeviceLocalCredential.Read.All` | Windows LAPS metadata and selected password retrieval |
| `BitlockerKey.ReadBasic.All` | BitLocker recovery-key metadata |
| `BitlockerKey.Read.All` | Selected BitLocker recovery-key retrieval |

Administrator consent may be required. The signed-in operator must also have directory roles or custom-role actions that authorize the requested recovery data. Review Microsoft's current documentation before deployment:

- [Get deviceLocalCredentialInfo](https://learn.microsoft.com/graph/api/devicelocalcredentialinfo-get?view=graph-rest-1.0)
- [Use Windows LAPS with Microsoft Entra ID](https://learn.microsoft.com/entra/identity/devices/howto-manage-local-admin-passwords)
- [List Intune managed devices](https://learn.microsoft.com/graph/api/intune-devices-manageddevice-list?view=graph-rest-1.0)
- [List BitLocker recovery keys](https://learn.microsoft.com/graph/api/bitlocker-list-recoverykeys?view=graph-rest-1.0)
- [Get a BitLocker recovery key](https://learn.microsoft.com/graph/api/bitlockerrecoverykey-get?view=graph-rest-1.0)

## Security design

Intune Device Workbench handles privileged recovery material, so its recovery flow is deliberately narrow:

- Authentication is delegated and interactive; the project includes no unattended privileged identity or credential.
- Tenant-specific settings are local and ignored by Git.
- Inventory refreshes request metadata only, never LAPS passwords or BitLocker key values.
- A secret is fetched only for the selected device and only after **Copy** or **Reveal briefly**.
- Both newly fetched and briefly cached recovery values pass through the same user-verification gate.
- Local verification is revoked when its fixed timer expires, when Windows locks or disconnects the session, and when the app closes.
- The Microsoft fallback runs in a separate process-scoped Graph session, validates the configured tenant and account, requires a newly observed device code, and returns no token to the app.
- Secrets are not intentionally written to files, logs, or PowerShell history.
- Revealed secrets hide automatically, and copied secrets are cleared only if the clipboard still contains the value written by this app.
- Reveal and clipboard deadlines use elapsed time, so changing the Windows clock cannot extend them. Busy clipboard cleanup retries; normal closing waits for pending cleanup rather than silently abandoning it.
- Intune and recovery records are joined by Entra device ID, not mutable device name.
- There is no bulk secret export path.

See [SECURITY.md](SECURITY.md) to report a vulnerability. Never put production tenant data, device names, screenshots, secrets, or logs in a public issue.

## Keyboard shortcuts

- `Ctrl + F` focuses device search.
- `Ctrl + Shift + C` copies the secret from the active LAPS or BitLocker tab.
- `F5` refreshes inventory.
- `Esc` immediately hides a revealed secret and dismisses a pending recovery action. Changing the device, recovery tab, or key selection also dismisses pending recovery intent; a late result is discarded.

## Tests

See the [Windows smoke-test checklist](docs/WINDOWS-SMOKE-TEST.md) for remaining interactive validation. Automated checks do not establish Windows Hello or production-tenant behavior.

The offline suite parses the PowerShell and WPF markup and validates data joining, authentication-context enforcement, secret decoding, portal-link validation, metadata-only inventory, clipboard protection, the no-console launcher, and key UI regressions. It also executes the production recovery operations with synthetic Graph responses and tests clipboard race/cleanup behavior with native-call shims. It does not connect to Microsoft Graph or overwrite your clipboard. Generated test files are placed in a unique system temporary directory and cleaned up on exit.

See the [September 2026 audit notes](docs/AUDIT-2026-09-05.md) for fixed issues, verification coverage, and remaining limits.

The [September 22 quality review](docs/QC-2026-09-22.md) covers recovery-card layout, large-inventory filtering, empty inventories, and expired sign-in handling.

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Tests\Test-IntuneDeviceWorkbench.ps1
```

## Project scope

Intune Device Workbench focuses on Windows device support: quick access to LAPS passwords, BitLocker recovery, and the device context needed for a support ticket. The Intune and Entra links provide access to less frequent portal tasks.

See [ROADMAP.md](ROADMAP.md) for planned work and [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change.

Intune Device Workbench is licensed under the [MIT License](LICENSE). It is not affiliated with or endorsed by Microsoft.
