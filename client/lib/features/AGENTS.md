# Client Features Contract

## Scope
This contract applies to `client/lib/features/`.

## Feature Ownership
- Organize client behavior as self-contained vertical features with explicit data, domain, and presentation ownership.
- Do not create a new feature directory unless the capability is independent of every existing feature.
- Use `client/lib/shared/` only for UI or state surfaces reused by more than one feature.
- Use `client/lib/utils/` only for small, stateless, feature-neutral helpers.
- Keep implementation-specific laws in the nearest owning child contract; do not duplicate them here.

## Layer Direction
Dependencies must follow:

`Widget / Screen -> Cubit / Controller -> Repository / Client -> Transport Adapter -> Socket / Platform`

### Presentation
- Render state, collect user intent, and request navigation.
- Do not call `SanadSocketService`, parse raw transport events, or construct transports directly.
- Do not own long-running business workflows or duplicate domain stores.

### Domain
- Own feature models, repository interfaces, durable stores, and state invariants.
- Remain independent of Flutter UI types and transport implementations.

### Data
- Implement repositories, DTO mapping, persistence, and feature-facing transport coordination.
- Preserve one managed client per device through the owning registry; widgets must not construct registries or transport clients.

## Cross-Feature Laws
- The Dart daemon is authoritative for runtime execution, delivery classification, provider state, session recovery, and agent-owned catalogs. The client projects that authority and must not reconstruct it from presentation state.
- Device-targeted operations must carry explicit device identity and use the shared connection/command abstractions rather than forcing a transport.
- Client-originated command correlation uses the shared UUID-backed request-id generator. Never derive request identity from wall-clock precision.
- Feature UI must not read agent-owned files or discover agent-owned catalogs directly when a daemon query surface exists.
- Cross-feature navigation and composition belong to their owning Home/core coordinators; individual feature widgets must not create competing global routing state.
- Tool cancellation projects `EventStatus.cancelled` with terminal precedence; live `tool_result` and history hydration must preserve the same generation, revision, reason, timestamps, and cleanup outcome. Reject older or unversioned late terminal results after an authoritative revision, and let `stopped` defensively close only same-run running tools that missed a terminal packet.

## Client CLI Host Ownership (Plan 102)
- `client/lib/features/client_cli/` owns the local `sanad-client` command surface. It is a Client-owned host, not a second authority: the Client keeps account and device authority, the target Agent keeps runtime and command-execution authority, and the surface relays without persisting command payloads.
- `ClientCliHost` owns at most one HTTP/WebSocket host per active Sanad Home. Record read/write with atomic owner-only permissions, liveness plus authenticated health verification, and deterministic no-owner, disabled, ambiguous, and version-mismatch failures belong to `ClientCliOwnership` and `ClientCliDiscovery` under `data/`; presentation must not read the ownership record or probe endpoints directly.
- CLI home resolution follows the active Sanad Home through `ClientCliHomeResolver`; do not add a second home selector or share a cross-home preference namespace.
- Execution approval is user-owned: requests flow through `ClientCliApprovalCoordinator` and surface in the approval overlay as allow-once, allow-session, or deny. Never auto-approve and never bypass Agent session or tool permission authority.
- The host never evaluates a shell, never reimplements an Agent CLI command, and never logs argv, standard input, or command payloads.
- Design reference: `docs/technical/remote_cli_relay_protocol.md`.
