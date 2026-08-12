# Settings Feature Contract

## Scope
This contract applies to `client/lib/features/settings/`.

## Destination Ownership
- `/settings` is the only user-facing settings destination.
- Workspace deep links carry explicit `device_id` and stable `workspace_id`; Settings selects that inspection scope without changing the active conversation device.
- Workspace Settings owns display-name rename and Change Path; sidebar workspace
  rows only navigate to this destination. Change Path uses the shared picker
  boundary and is available only for a confirmed same-desktop local device.
- Settings mutation failures use the project `ToastUtils` surface with the actionable daemon-provided reason; do not use `SnackBar` or replace known reasons with generic copy.
- Keep `/agents` as a redirect to the selected device Overview; do not recreate a separate Manage Devices surface.
- Keep workspace destinations in primary Settings navigation. Show a bounded initial set with Show all / Show less rather than another navigation hierarchy.

## Device Scope
- Selecting a device inside Settings changes inspection context only.
- Update the active conversation device only through an explicit Set as active action delegated to `DeviceCubit`.
- Show Cloud Connection mutation only when the inspected target resolves to the local route.
- Device Overview rename UI must wait for the authoritative inventory mutation result and remain open with an actionable error when the mutation fails.

## Runtime Queries
- Providers, MCP, Skills, Workspace, and device settings queries must use `DeviceCommandClient` with explicit device identity.
- Presentation must not call `SanadSocketService` or read agent-owned configuration files.
- Device MCP and Skills pages show device scope; workspace detail pages must label effective origins and precedence.
- Provider setup embedded in Settings must reuse `ProviderSetupFlow` and its controller rather than implementing a second setup workflow.

## Account Sessions and Devices
- Sessions & Devices is account-scoped and consumes the Portal's authoritative account lifecycle projection through one repository/cubit owner.
- Client-session current status comes from the verified credential family, never instance metadata. Presence renders `Online`, `Offline`, or `Status unavailable`; registry failure must not become false Offline.
- Connected Agents reuse the existing `DeviceCubit` inventory and navigate to device Overview. Do not create another device store or `/agents` management surface.
- Revoke is confirmed and per-row single-flight. Unknown outcomes retain the last snapshot and refetch; a confirmed current-session revoke delegates to the normal logout flow.

## Client-Owned Preferences
- General application preferences such as theme remain client-owned and must not emit agent commands.
- Settings-local UI state must not become a source of truth for runtime readiness, device connection, or conversation recovery.
