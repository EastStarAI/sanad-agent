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
- Tool cancellation projects `EventStatus.cancelled` with terminal precedence; live `tool_result` and history hydration must agree, and `stopped` defensively closes same-run running tools that missed a terminal packet.
