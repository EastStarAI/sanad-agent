# MCP Feature Contract

## Scope
This contract applies to `client/lib/features/mcp/`.

## Runtime Ownership
- The daemon owns MCP catalogs, effective configuration, mutations, and scope precedence.
- Query and mutate MCP state through `DeviceCommandClient` with an explicit target `DeviceConfig`.
- Let `DeviceConnectionCoordinator` choose local or cloud transport; MCP must not force a socket or send an empty device id.
- Presentation must not call `SanadSocketService`, inspect agent-owned files, or synthesize MCP entries from local client state.

## Scope Presentation
- Device MCP views show device scope only.
- Workspace detail views may show effective device and workspace entries but must label origins and communicate same-name workspace precedence.
- Pending suspension and recovery state must come from daemon-owned conversation/history metadata, not MCP-local dialogs or caches.

## Presentation Layout
- `AddMcpServerScreen` and `McpServerManagementScreen` remain the screen hosts: they own draft, connection, expansion, and mutation state, and they are the only owners that call `McpRuntimeClient` for those flows.
- The typed form fields, the inspection review, the server card, and the one-server Advanced JSON dialog are one library each under `client/lib/features/mcp/presentation/widgets/`. The hosts compose them and pass typed callbacks; the extracted widgets own no draft or connection state.
- The Advanced JSON dialog keeps the daemon preview mandatory: Save stays disabled until the same document previews, and the host reloads the snapshot only after the dialog reports a save.
- Keys and semantics are protocol. The `mcp_form_*` keys, `mcp_scope_segment_btn`, `add-mcp-server`, `mcp_server_toggle_<name>`, and `mcp_server_remove_<name>` stay byte-identical across any further decomposition.
- A form cubit that owns the draft and the OAuth poll interval is a separate behavior change; until it lands, the draft and the poll loop stay in `AddMcpServerScreen`.

## Form and Secret Projection
- MCP management is card-first; raw JSON is limited to explicit one-server Advanced actions with daemon preview and stale-edit protection.
- Add and Edit reuse one typed draft flow. Import only seeds that draft after daemon preview.
- Widgets may temporarily hold newly entered credentials only until the daemon request completes; edit state receives configured markers, never stored values.
- OAuth UI may launch a daemon-provided authorization URL and poll an opaque flow ID, but discovery, callbacks, PKCE, registration, token exchange, refresh, and token persistence remain daemon-owned.
- Cloud and local MCP management share `DeviceCommandClient`. Destructive cloud
  mutations auto-consume daemon preview tickets after the user already confirmed
  in the form. Nested `secrets` payloads are redacted from socket diagnostics.
- Offline devices show an in-page reconnect message and disable add, test, edit,
  and remove. Destructive actions are single-flight; a failed mutation reloads
  the daemon snapshot instead of retrying automatically.
