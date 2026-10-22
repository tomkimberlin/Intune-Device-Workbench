# Roadmap

Intune Device Workbench is a focused desktop app for frequent Microsoft 365 administration workflows that are slow or fragmented across Microsoft's portals. It is not intended to reproduce every portal page.

## Principles

- One search surface for related Entra and Intune objects
- Capability-based modules with explicit Microsoft Graph permissions
- One interactive sign-in for the complete set of modules the operator enables
- Read-only by default
- Per-item retrieval for recovery secrets
- Clear confirmation and audit context for write or device actions
- No bulk export of passwords or recovery keys
- Synthetic data only in tests, screenshots, and documentation

## Available now

### Devices and recovery

- Unified Intune and Entra Windows device inventory
- Search, filtering, selection preservation, and stale-sync indicators
- Entra-only mismatch detection, counts, focused filtering, and management-state context
- LAPS availability and rotation metadata
- Per-device password copy and timed reveal
- BitLocker recovery-key metadata, volume selection, per-key copy, and timed reveal
- OS, model, serial, join type, ownership, encryption, compliance, Intune sync, and Entra activity context
- Validated deep links to each device's exact Intune and Entra admin-center records
- Tenant/account/scope enforcement, protected clipboard handling, and user verification before recovery access

## Next foundations

- Navigation shell and module registry
- Capability-to-permission mapping and consent preview
- Shared Microsoft Graph request, pagination, throttling, and error handling
- Unified search across devices, users, groups, applications, and policies
- Consistent audit and confirmation components for sensitive reads and writes

## Planned modules

### Devices

- Primary user and registered owners
- Configuration profile, compliance policy, application, and update status
- Autopilot context
- Common actions such as sync and restart, with separate write permissions and confirmation

### Identities

- User overview, authentication methods, licenses, groups, roles, assigned devices, and sign-in context
- Group membership and assignment tracing
- Enterprise applications, service principals, consent, owners, and credential-expiration views

### Policies and applications

- Intune application and assignment lookup
- Configuration, compliance, security, and update policy assignment tracing
- Conditional Access policy lookup and impact context
- Failure-focused deployment and configuration reports

## Server boundary

Microsoft Entra can contain server device identities, and Microsoft Defender for Endpoint integrations can surface limited server security-management data through Intune. Full server management normally belongs to Azure Arc, Defender, Configuration Manager, or other tooling. Server data may be shown when Entra or Intune exposes it, but this project will not pretend to replace those systems.
