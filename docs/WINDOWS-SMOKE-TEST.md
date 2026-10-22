# Windows smoke test

Use a new checkout of the reviewed commit from https://github.com/tomkimberlin/Intune-Device-Workbench. Keep any existing checkout and ignored settings file in place. Use synthetic demo data throughout this checklist.

```powershell
pwsh.exe -NoLogo -NoProfile -File .\Tests\Test-IntuneDeviceWorkbench.ps1
pwsh.exe -NoLogo -NoProfile -STA -File .\IntuneDeviceWorkbench.ps1 -DemoMode
```

## Interactive checks

- Confirm the new window/header name. LAPS and its large Copy password action should remain the main workflow. Check the minimum/default window sizes and normal/enlarged Windows display scaling; long names must not overlap the readable compliance badge. Use Tab, Shift+Tab and a screen reader if available.
- Select several fictional devices. Check that the badge matches the existing compliance detail, including the noncompliant example. Unknown or missing data must stay unknown. Last Intune sync remains visible and is reported inventory data, not proof the device is online.
- Copy details and paste into an unsaved ticket or text window. Expect only device name, actual primary user/UPN, serial and OS. Check the unassigned example and switch selection before copying again. No LAPS password, BitLocker key or device code belongs in these details.
- Copy a synthetic demo password/key, then copy details. Paste only into the unsaved local test window to verify replacement. The old secret countdown must clear, and details expire after the configured interval (45 seconds by default). Test details followed by another synthetic recovery copy as well.
- Copy details, then replace the clipboard with harmless text from another app. Waiting for the old deadline, closing or locking the app must not erase the newer text. With details still owned by the app, normal closing should clean them up. Check Windows clipboard history excludes the app's copied values; third-party clipboard managers remain outside that protection.
- Repeat selection changes and copying in demo mode. The offline suite exercises blocked copying during refresh/recovery, contention and late-result cases using synthetic responses and native-call shims; demo mode alone cannot reproduce every asynchronous verification path.
- In an existing checkout updated in place, confirm the old launcher/settings paths remain usable. Rerun `Install-DesktopShortcut.ps1` only if you want a shortcut with the new name. It creates/updates that named shortcut without deleting an old one. The Windows app identity intentionally stays stable.

## Limits and optional authentication check

Windows CI runs the offline suite, real off-screen WPF layout/rendering and launcher checks. Clipboard ownership/races and recovery operations are tested with native-call shims or synthetic Graph responses; they do not establish real clipboard contention, Windows Hello/PIN/biometrics, session transitions or live tenant behavior on your laptop.

Windows Hello and Microsoft device-code fallback need Tom's interactive participation and separate explicit approval for any live privileged recovery read. Do not automate a real recovery test, change consent/roles/scopes, perform tenant writes, or collect production secrets/screenshots/logs. Do not assume a device-code sign-in proves MFA; Conditional Access controls that requirement.

Record only the reviewed commit, Windows/PowerShell versions, synthetic test steps and pass/fail observations. Close the unsaved text window and discard its contents afterward. Keep this early-release status and remaining native validation limits visible before a public launch.
