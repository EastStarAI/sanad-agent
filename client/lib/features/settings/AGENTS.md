# Settings Feature Contract

## Scope
This contract applies to `client/lib/features/settings/`.

## Destination Ownership
- `/settings` is the only user-facing settings destination.
- Workspace deep links carry explicit `device_id` and stable `workspace_id`; Settings selects that inspection scope without changing the active conversation device.
- Workspace Settings owns display-name rename and Change Path; sidebar workspace
  rows only navigate to this destination. Change Path uses the shared picker
  boundary and is available only for a confirmed same-desktop local device.
  Remote devices create workspaces by name and do not open a native
  host-directory picker. Workspace Overview does not expose the retained
  remote folder browser; that daemon-backed surface is reserved for a future
  file-tree experience.
- Remove Workspace deletes only the daemon-owned workspace record after an
  explicit confirmation. It must not delete the host folder, its files, or
  conversation rows.
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
- Device Overview update/restart actions are shown for every Online device and
  use `DeviceCommandClient` through `DeviceControlClient`. They must not call
  `LocalDaemonController` for those actions, including a same-desktop local
  device. Restart confirmation orders Cancel, destructive red Force restart,
  then the primary safe Restart action; only the destructive action sends the
  explicit protocol force flag.
- Presentation must not call `SanadSocketService` or read agent-owned configuration files.
- Device MCP and Skills pages show device scope; workspace detail pages must label effective origins and precedence. MCP pages disable mutations and show an English reconnect message when the inspected device is offline.
- Provider setup embedded in Settings must reuse `ProviderSetupFlow` and its controller rather than implementing a second setup workflow.

## Client-Owned Preferences
- General application preferences such as theme remain client-owned and must not emit agent commands.
- Settings-local UI state must not become a source of truth for runtime readiness, device connection, or conversation recovery.
