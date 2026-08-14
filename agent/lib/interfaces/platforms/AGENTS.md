# Interface Platforms Contract

## Scope
This contract applies to `agent/lib/interfaces/platforms/`.

## Platform Lifecycle
- Every platform implements the common initialize, dispose, event stream, descriptor, and response-delivery boundary.
- Platform adapters remain asynchronous and non-blocking.
- A platform initialization or send failure is isolated from other adapters and the daemon event loop.
- Platform-specific auth, reconnect, framing, and capability advertisement stay in the adapter and do not leak into shared runtime orchestration.

## Gateway Routing
- `GatewayManager` routes exclusively from typed delivery policy and captured origin, never event-name switches or hardcoded platform ids.
- Origin delivery targets one known platform and fails closed when unknown.
- Platform-family delivery reaches every adapter in that family; local and cloud Sanad transports converge through this scope.
- Hardware delivery requires family plus target hardware and never falls back to family broadcast.
- External families remain origin-scoped and never enter Sanad-client synchronization.
- User echoes are runtime-authoritative and delivered only to platform adapters that explicitly accept them.

## Local and Cloud Independence
- The cloud Sanad platform is an outbound adapter responsible for cloud registration, refresh, reconnect, and remote capability advertisement.
- The local daemon platform is an inbound loopback server using a configured dynamic port.
- Keep local and cloud adapters independently startable and disposable.
- Preserve hardware id separately from backend-assigned device id on every cloud event.
- The local adapter tracks all assertion-bound Client instances as a full membership snapshot. The cloud adapter alone owns the monotonic delivery-interest lease and suppresses before response serialization only for a fresh supported zero-recipient lease; missing, invalid, stale, or expired state enables Cloud egress.
- Initial cloud pairing sends the UI-issued pairing token with an
  agent-generated durable device token. Persist the proposed durable token
  before registration, finalize it only after success, and never log either
  credential.
- Echo requested device/hardware identity on local responses so device-scoped client streams remain coherent.

## Suspension Delivery
- Suspension delivery derives from captured run origin and typed policy, not transient session channels.
- The first valid response claims resolution; late or concurrent responses receive an authoritative already-resolved outcome.
- Lost in-memory waiters fall back to persisted suspension recovery rather than dropping replies.
- Platform-owned tools execute through platform call/result contracts and never masquerade as local daemon tools.

## Voice Boundary
- Voice platforms delegate channel/provider/engine implementation to infrastructure owners.
- Voice-generated conversation events retain canonical run, model-step, tool-call, and event identity.
- Voice transport failure remains isolated from text command and delivery paths.
