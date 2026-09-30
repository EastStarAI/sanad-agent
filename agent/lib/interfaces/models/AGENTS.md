# Interface Models Contract

## Scope
This contract applies to `agent/lib/interfaces/models/`.

## Typed Delivery
- Delivery models are transport contracts, not display metadata, and travel on every canonical response envelope.
- `PlatformFamily` is an extensible typed value, not a closed enum requiring `GatewayManager` branches.
- Every platform declares family, transport, and platform-instance identity through `PlatformDescriptor`.
- Delivery policy is producer-owned and validates required family and target fields before routing.
- Missing or invalid delivery metadata fails closed; do not restore legacy broadcast fallback.

## Event and Origin Identity
- Mint `event_id` once for one semantic event and preserve it across local/cloud copies.
- Never derive event identity from content or timestamp alone and never regenerate it per transport.
- Capture origin platform/family/transport at admission so later suspension, recovery, and terminal delivery retain the initiating scope.
- Keep hardware identity distinct from backend device registration identity.

## Model Safety
- Models crossing protocol or persistence boundaries remain typed and JSON-safe.
- Optional fields are omitted when absent where the protocol requires absence semantics; do not emit null as a substitute.
- Device-control command, result, and error models use canonical protocol names. Do not parse UI labels, and do not accept client artifact URLs or checksums as update authority.
- Workspace-control models carry managed-remote admission errors and mutation
  preview payloads. Do not treat a client path as the remote workspace root.
- Extend delivery and origin types without coupling model definitions to concrete platform implementations.
