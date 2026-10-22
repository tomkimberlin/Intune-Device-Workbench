# Security policy

## Supported versions

Security fixes are applied to the latest version on the `main` branch. There is not yet a separate long-term-support release line.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, discussion, screenshot, or log attachment.

Use GitHub's [private vulnerability report](https://github.com/tomkimberlin/Intune-Device-Workbench/security/advisories/new). If private reporting is temporarily unavailable, do not open a public issue containing security details.

Include the minimum information needed to reproduce the problem. Never submit a real LAPS password, BitLocker recovery key, device code, access token, refresh token, tenant export, production settings file, or screenshot from a production tenant.

## Sensitive-data rules

Contributions must not contain:

- Real tenant IDs, tenant domains, administrator UPNs, device names or naming patterns, serial numbers, user data, or internal URLs
- Access tokens, refresh tokens, device codes, client secrets, certificates, private keys, or exported Graph contexts
- Real LAPS passwords, BitLocker recovery keys, or screenshots from a production tenant
- Logs or captures containing Graph authorization headers or credential response bodies

Use `contoso.com`, `contoso.onmicrosoft.com`, reserved example identifiers, and explicit `DEMO-DEVICE-*` names in tests and documentation.

## Design requirements

- Retrieve recovery secrets only after an explicit per-device operator action.
- Require a current user-verification grant before either retrieving or reusing recovery material; fail closed for cancellation, timeout, errors, and identity mismatch.
- Keep verification grants fixed-duration and process-memory-only, and revoke them on Windows session lock or disconnect.
- Treat Windows user verification as local user presence, not proof of the Microsoft Graph identity or Entra MFA.
- Treat Microsoft device-code verification as an interactive fallback whose MFA requirements are determined by Conditional Access.
- Keep inventory metadata-only; never request LAPS passwords or BitLocker key values during refresh.
- Never implement bulk secret export.
- Keep read-only inventory permissions separate from future write or device-action permissions.
- Require clear confirmation for destructive or disruptive device actions.
- Do not log credential payloads or authorization headers.
- Keep secrets out of disk-backed caches and clear in-memory and displayed values promptly.
- Preserve tenant, expected-account, delegated-context, and scope validation.
- Treat every recovery-key request as a sensitive, auditable read.

## Local security boundary

The app is a local administrative convenience, not a hardened credential vault. Clearing references cannot guarantee immediate erasure of immutable .NET strings, copies held by the Graph SDK, operating-system paging, or crash dumps. Windows clipboard exclusion formats request that Windows omit an item from history and cloud synchronization; they do not prevent another local process or a third-party clipboard manager from reading it. Forced termination or a machine crash can prevent clipboard cleanup. Keep the workstation trusted and use device-management and endpoint-security controls appropriate for privileged recovery access.
