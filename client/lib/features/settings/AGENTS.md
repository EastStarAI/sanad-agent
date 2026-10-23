# Settings Feature Contract

## Scope
This contract applies to `client/lib/features/settings/`.

## Destination Ownership
- `/settings` is the only user-facing settings destination.
- Workspace deep links carry explicit `device_id` and stable `workspace_id`; Settings selects that inspection scope without changing the active conversation device.
- Workspace Settings owns display-name rename and Change Path; sidebar workspace
  rows only navigate to this destination. Change Path uses the shared picker
  boundary and is available only for a confirmed same-desktop local device.
  Remote devices add workspaces through the confined in-app folder browser
  owned by the conversations presentation and never open a native
  host-directory picker. Remote Change Path is not offered here.
- Remove Workspace deletes only the daemon-owned workspace record after an
  explicit confirmation. It must not delete the host folder, its files, or
  conversation rows.
- Settings mutation failures use the project `ToastUtils` surface with the actionable daemon-provided reason; do not use `SnackBar` or replace known reasons with generic copy.
- Keep `/agents` as a redirect to the selected device Overview; do not recreate a separate Manage Devices surface.
- Keep workspace destinations in primary Settings navigation. Show a bounded initial set with Show all / Show less rather than another navigation hierarchy.

## Workspace Security
- Workspace execution mode and host discovery are Agent-owned. `WorkspaceSecurityCard` reads and changes them only through `WorkspaceSecurityClient` (`DeviceCommandClient`, explicit device), sends only the changed axis with the revision on screen, and reloads Agent truth after any rejection.
- Follow `workspace.policy_changed` (`WorkspaceSecurityClient.watch`) so a change made by another client or the CLI shows without a restart; keep the last read `canWiden`, which the broadcast does not carry.
- Security card segments keep the driver keys `workspace_security_mode_<direct|protected>` and `workspace_security_discovery_<owner_only|disabled>` on their labels, with `Semantics(selected:)` so driver snapshots report the selected value.
- A `stale_revision` rejection reloads Agent truth and shows the localized refresh message; the composer toggle retries once on the fresh revision before showing it. Never fail a policy change silently.
- Disable choices the Agent reports it would reject (`canWiden: false`); never cache policy as authority or retry a rejected mutation automatically.

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

## Account Sessions and Devices
- Sessions & Devices is account-scoped and consumes the authenticated Cloud Socket's authoritative account lifecycle projection through one repository/cubit owner; Portal HTTP owns authentication, not lifecycle routes.
- Profile account deletion requires explicit confirmation and one single-flight repository request. Confirmed database deletion delegates to normal logout; pending cleanup must not be presented as completed. Unknown outcomes must not report success or automatically retry. Agent-owned local data remains untouched.
- Client-session current status comes from the verified credential family, never instance metadata. Presence renders `Online`, `Offline`, or `Status unavailable`; registry failure must not become false Offline. Each Client row shows the canonical privacy-safe short reference derived instance-first, with account-session fallback, so users can correlate it with Agent lifecycle logs without exposing raw ids.
- Connected Agents reuse the existing `DeviceCubit` inventory and navigate to device Overview. Do not create another device store or `/agents` management surface.
- Revoke is confirmed and per-row single-flight. Unknown outcomes retain the last snapshot and refetch; a confirmed current-session revoke delegates to the normal logout flow.

## Presentation Layout
- Settings pages are one library each under `client/lib/features/settings/presentation/widgets/settings_pages/`; `settings_screen.dart` composes them and owns destination selection.
- Shared page chrome (`PageFrame`, `SettingsCard`) stays in `client/lib/features/settings/presentation/widgets/settings_widgets.dart`; a page keeps its own private helpers in its own file.
- Cross-page embedding that already existed stays explicit: `workspace_page.dart` renders the Skills page and the embedded MCP screen rather than duplicating them.
- The desktop update-check copy pinned by `client/test/tool/settings_update_contract_test.dart` lives in `settings_pages/general_page.dart`.

## Client-Owned Preferences
- General application preferences such as theme remain client-owned and must not emit agent commands.
- Settings-local UI state must not become a source of truth for runtime readiness, device connection, or conversation recovery.
