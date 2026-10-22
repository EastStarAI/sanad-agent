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
- The feature is desktop-only: `domain/client_cli_platform.dart` owns that boundary, `client/lib/core/di/modules/client_cli_module.dart` owns its registration, and the host, settings cubit, ownership record, and Home resolution are never registered, constructed, or resolved on Web or mobile. Home resolution runs inside the host's lazy factory, so dependency registration performs no native read.
- Execution approval is user-owned: requests flow through `ClientCliApprovalCoordinator` and surface in the approval overlay as allow-once, allow-session, or deny. Never auto-approve and never bypass Agent session or tool permission authority.
- Remote relay calls stay bounded by the forwarded command, not by a fixed constant: the caller derives `timeout_seconds` from the command's own `--timeout` plus a bounded grace and forwards standard input only for a command that can consume it. `client/lib/features/client_cli/domain/models/client_cli_relay_policy.dart` is the single owner of both decisions.
- Every relayed request delivers exactly one terminal result to its caller. A device event stream that ends or fails before the Agent reports an outcome is a terminal failure for that request, and a caller that loses its relay without a terminal frame exits non-zero; neither side may report or assume success.
- A hidden wait is a defect: any state where the caller can do nothing while the host waits on the user (a pending Default-mode approval) is announced on the caller's standard error, never on standard output, so machine-readable output stays parseable.
- The host never evaluates a shell, never reimplements an Agent CLI command, and never logs argv, standard input, or command payloads.
- Design reference: `docs/technical/remote_cli_relay_protocol.md`.
