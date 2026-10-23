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

## Privacy and Security Secrets
- `SecretsClient` (`data/secrets_client.dart`) is the only Client transport for the user-secret protocol (`secrets.list`, `secret.set`, `secret.delete`, `secrets.changed`) and it uses `DeviceCommandClient`, so local and cloud routes are identical and no page selects a transport. List rows and dialogs never receive a stored value: the protocol has no reveal and no `secret.get`.
- A submitted value is a method argument on `SecretsCubit.set`, handed to `SecretsClient.set`, and dropped. It must never become a cubit or state field, a cache entry, a `SharedPreferences` value, a dialog-retained value after submit/cancel, a log line, or exception text; `SecretsState` deliberately has no field that could hold one.
- Failures are typed once, in `SecretsErrorCode.fromWireCode`, and reach the UI only as `SecretsFailure`. Agent error `message` text is operator copy and never becomes UI copy, so an unmapped protocol code degrades to `unknown` with its wire token kept for diagnosis.
- `SecretsCubit` states are `loading`, `empty`, `loaded`, `error`, and `deviceUnavailable`. `SecretsState.secrets` is non-empty only for `loaded`, so an offline or failed state cannot present a stale row as current; `DeviceConfig.isOnline == false` short-circuits before any request. The page drops a loaded list with `markDeviceUnavailable()` when its inspected device goes offline.
- Nothing loads on construction or from `build`: the page calls `load()` from its own lifecycle and from Retry.
- A `set`/`delete` while another mutation is in flight returns `SecretsActionOutcome.busy` and sends nothing; a `load` during a read joins it and queues at most one follow-up read, so a burst of broadcasts cannot stack requests.
- `secrets.changed` announces that the authoritative list moved. The cubit re-reads the list and never projects the event payload.
- A successful mutation re-reads the list instead of patching rows locally. `delete` always sends `confirm: true`; the user confirmation is the page's responsibility and the protocol flag is the client's.
- The Client mirrors the name grammar only (`SecretsClient.isValidNameFormat`). The reserved-name list stays Agent-owned, so a reserved name is surfaced from the Agent as `reserved_secret_name`.
- The destination is Settings → Privacy & Security → Secrets (`SettingsDestination.privacySecurity`, route `/settings?section=privacySecurity`) in the selected-device section. `settings_pages/secrets_page.dart` owns one `SecretsCubit` per page, created from DI in `initState`; `load()` runs there and from Retry only, never from `build`.
- The page renders metadata only and shows exactly one of loading, empty, error with Retry, device unavailable, or loaded. When the inspected device is offline the list is dropped rather than presented as current, the actions are disabled, and the unavailable banner replaces the rows.
- A dialog owns the only value in the feature: a `TextEditingController` cleared on submit and on cancel and disposed with the dialog, handed straight to `SecretsCubit.set`. Replace opens with an empty value field, the name read-only, and no reveal; no surface pre-fills, previews, or reads a stored value.
- The page states only what is stored and that values are write-only. It does not restate the Full Access prompt rule.
- Every interactive element carries a stable `ValueKey` so driver-driven UI tests can act on it, and every user-facing string is authored in both ARB files. Agent error `message` text is never rendered: a `SecretsFailure` becomes localized copy through `settings_pages/secrets_failure_text.dart`.

## Device Scope
- Selecting a device inside Settings changes inspection context only.- Update the active conversation device only through an explicit Set as active action delegated to `DeviceCubit`.
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
