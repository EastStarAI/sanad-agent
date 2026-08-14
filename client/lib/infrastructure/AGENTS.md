# Infrastructure Domain Contract

## Scope
This contract applies strictly to the `sanad-client/lib/infrastructure/` directory.

## Infrastructure Ownership
* Use `infrastructure/` for low-level integration layers:
  - Socket.IO and WebSocket connections.
  - Event routing and device client registries.
  - MCP configurations and automation connectors.
* **DO NOT** place feature state management (Cubits/Blocs), UI components, or feature business workflows in this directory.

## Core Boundaries
* **`UniversalDeviceClient`:** Act as the low-level unified protocol adapter. Do not move conversation UI or presentation logic into this client.

## Dual Connection Model
- **Parallel Sockets:** Coexist `cloudSocketService` (cloud gateway) and `localSocketService` (local daemon at `AppConfig.localGatewayUrl`, defaulting to `127.0.0.1:58085`). `sanad-dev` enables both by default; explicit local-only mode may leave the cloud socket disconnected.
- **Authenticated Local Transport:** Desktop Local Gateway HTTP and WebSocket consumers read the owner-only credential from the active Sanad Home and send it only as `x-sanad-local-token`. Never place it in a URL, query, process argument, compile-time define, preference, response, or log. Web and mobile never read it.
- **Resilient Reconnections:**
  - Cloud transport relies on Socket.IO's native automatic reconnection logic.
  - Local transport must use a custom automatic reconnection mechanism with exponential backoff (from 2s to 10s) and explicit disconnect/dispose guards built into `SanadSocketService` to ensure local capability restores dynamically.
- **Central Connection Ownership:** Delegate all routing and transport failovers to `DeviceConnectionCoordinator`. It must expose the effective `ConnectionScope` (`cloud` | `local`) based on `deviceId` and socket readiness, while keeping stream identity stable for each `device_id`. The coordinator delegates local daemon process management and status checking to the abstracted `LocalDaemonController` (defined in `sanad-agent/client/lib/features/devices/data/daemon/local_daemon_controller.dart`).
- **Local Reachability Rule:** A device is a local candidate only when its `hardwareId` matches the current app hardware ID. Do not gate local routing on device or agent type.
- **Online Semantics:** A same-hardware local daemon connection is sufficient to mark a device as online in the UI (since online means the daemon is reachable).
- **Shared Hardware Identity:** On desktop, `auth.json` under the active Sanad Home is the single source of truth. Packaged/primary runs default to `~/.sanad`; linked `sanad-dev` runs receive a worktree-scoped home and a deterministic preference prefix derived from it. The `hardware_id` is the only accepted identity key. Mirror it only into the active home's preference namespace, never a cross-home namespace.
- **Deferred Hydration During Local Takeover:** When a same-device Sanad Agent moves from cloud to local, session hydration must wait until the local transport reaches `ready`. Do not fire speculative cloud `get_threads` requests during `connecting` or `authenticating` to prevent the UI from dropping the late cloud reply.
- **Single Logical Identity:** Devices are uniquely identified by `device_id`. Do NOT create fake local device types.
- **Device Event Routing:** Route cloud `device_event` payloads to conversation/runtime streams by `device_id` alone. Do not require `agent_type` for device-scoped event delivery.
- **EventRouter Contract:** `EventRouter` must own device-scoped streams only. Do not reintroduce type-scoped streams or route by device/agent type.
- **Socket Event Names:** The client must send `device_command` and consume canonical `device_event` responses. `device_command_echo` is deprecated and must not drive client state or cross-interface synchronization. Do not add compatibility listeners for legacy `agent_event`, `agent_command`, or `agent_command_echo`.
- **Credential-Safe Diagnostics:** Socket diagnostics must recursively redact credential-shaped fields, including tokens, authorization headers, cookies, passwords, API keys, and secrets, before serialization. Truncation is not redaction and must never be used as a credential boundary.
- **Client Instance Handshake:** Cloud authentication and the post-upgrade Local `client.hello` carry the same Client-owned UUID and bounded display metadata from the isolated preference namespace. Local upgrade authentication remains the authority; hello is correlation-only, and old peers continue without a presence-suppression claim.
- **Desktop Authentication Exchange:** The local transport may carry only the exact credential-free `authentication_exchange` notification. It cannot carry or request auth state; receivers reload owner-only `auth.json`. Native auth mutations are serialized through the stable owner-only `auth.refresh.lock`; Mobile and Web never start this exchange or open the lock. Explicit Agent logout is a separate authenticated local HTTP request with no payload; it is best-effort and bounded from the Client perspective because persisted logout intent owns offline convergence.
- **Tool Runtime Routing:** Local tool and MCP callbacks must forward `device_id` only. Do not pass `agentType` or emit `agent_type` in register-tools or tool-result paths.
- **Capabilities Scoping:** `DeviceCapabilitiesStore` must key capabilities by `device_id` (not `device_type`) to prevent clobbering across scopes.
- **UI Blending:** Merge replicated entries under their unique `device_id` with a passive `local` badge UI hint.
- **Conversation Continuity Across Scope Switches:** When the same `device_id` flips between `local` and `cloud`, preserve the in-memory conversation streams and store identity until the replacement transport hydrates history. A transport swap must never blank the currently open chat immediately.
- **Local Restart Grace:** A conversation client already bound to a same-hardware local daemon must remain pinned to its retained local snapshot during the bounded restart grace period instead of immediately accepting a cloud snapshot. If local reconnects, reconcile the session list additively and hydrate the active session history before treating the replacement transport as authoritative; explicit delete events and manual refreshes remain destructive authorities.
- **Reconnect-Owned Rehydration:** Automatic re-fetch after reconnect belongs to the connection/data layer (`DeviceConnectionCoordinator` + conversation registries), not to presentation controllers or `SessionCubit`.
- **Mobile Resume Recovery:** A real background-to-foreground transition debounces one single-flight cloud reauthentication. Initial startup is not a resume. Transient refresh failure keeps the socket/cache stale and retryable; only terminal credential rejection clears the cloud session.
- **Stream-First Presentation:** Presentation elements must observe `watchThreads(...)` streams instead of firing their own `getThreads(...)` fetches.
- **Hydration Entry Point:** `watchThreads(...)` is the canonical bootstrap path for session lists. It should yield the latest hydrated snapshot first when transport is ready, then continue with live stream updates. Manual refreshes must go through explicit repository refresh APIs.

## Platform Execution Modes
- **Desktop Mode (macOS, Windows, Linux):** Full capabilities (local tools, local files, local MCP, daemon connection).
- **Remote Mode (Mobile, Web):** Remote-only interface. Bypasses `localSocketService`, disables local files, local tools, and MCP. Interacts with cloud agents only.

## Client Update Ownership
- Packaged client self-update is distinct from `sanad update`, which updates only the standalone agent.
- macOS and Windows consume the signed Appcast; Linux and Android use user-approved system flows; iOS uses Internal TestFlight for v1; Web uses the deployed version marker.
- Source/FVM execution must disable packaged self-update and must never mutate the developer checkout.

## Local Filesystem Authority (Plan 25)
- **Local tools/ directory hosts client-side infrastructure only for capabilities the local daemon does not own.** The local daemon (`sanad-agent`) is the **sole source of truth** for any state that the user expects to persist across devices and platforms.
- **Workspace permissions (`WorkspacePolicy`)** are owned by the local daemon. The client **must not** read or write `settings.json` directly — all access must go through `ConversationRepository` → `ConversationClient` → `ConversationCommandGateway` (WebSocket). See `sanad-agent/docs/plans/25-relocate-workspace-permission-storage-to-agent.md` for the full contract.
- **MCP server configs, OAuth material, and auth tokens** are daemon-owned state. The client projects typed snapshots and mutations through `DeviceCommandClient`; it must not read or write MCP configuration files or persist MCP credentials locally.

## Phase 27 — Cross-Transport Event Deduplication
- **Canonical `event_id`:** every `device_event` envelope carries an `event_id` minted once by the agent runtime and preserved across all local/cloud copies. The client must not dedupe by content, timestamp, or `run_id` alone.
- **Shared `EventDeduplicator`:** `DeviceConnectionCoordinator` owns ONE `EventDeduplicator` instance and injects it into both `cloudSocketService` and `localSocketService`. Both transports consult it inside their `device_event` handlers BEFORE routing or broadcasting, so a same-device client never applies the same event twice during a transport switch or cloud fan-out.
- **Transition safety key:** dedupe by canonical `event_id` across both transports. The first arriving copy is applied; later Local/Cloud copies are dropped. This is a race safety net, not the steady-state routing policy.
- **Bounded cache:** the dedupe cache is bounded by size (LRU eviction) and time, is in-memory only, is independent of the durable conversation log, and is cleared on full logout — NOT on a transport switch for the same device.
- **Backward compat:** events without an `event_id` are still processed (producers are expected to stamp it); the deduplicator never silently drops an event that lacks the canonical id.
- **Presence-aware route transition:** a desktop Client keeps its Cloud Socket connected, publishes one complete replace-set snapshot of all account-device interests, obtains a Gateway assertion before claiming Local presence, and renews that binding while the route is active. Adding or selecting one device must not remove another inventory device from Cloud interest; missing assertions preserve Cloud delivery.
