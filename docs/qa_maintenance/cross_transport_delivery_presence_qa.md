---
title: "Cross-Transport Delivery Presence QA"
description: "Regression matrix for assertion-bound Local presence, Agent Cloud-egress gating, route transitions, and canonical event deduplication."
---

# Cross-Transport Delivery Presence QA

## Acceptance matrix

| Scenario | Expected result |
|---|---|
| No interest lease has been received | Agent emits Cloud; unknown state never suppresses delivery. |
| Fresh supported lease has zero recipients | Local delivery continues and Cloud response translation/serialization is not invoked. |
| Fresh lease has one or more recipients | Agent emits exactly one Cloud copy for Gateway recipient filtering. |
| Lower revision arrives after a newer lease | Lower revision is ignored and cannot restore suppression. |
| Lease is malformed, unsupported, or expires | Agent immediately/finally returns to safe Cloud egress. |
| Two authenticated Local Clients present valid assertions | Full snapshot contains both members; disconnect removes only its owning socket. |
| Local Client has no Gateway assertion | It remains operational but contributes no suppression membership. |
| Agent Cloud connection reconnects | Interest is cleared until a fresh Gateway lease and a renewed full Local snapshot are exchanged. |
| Same canonical event races over Local and Cloud | The first `event_id` copy is applied and the later copy is dropped. |
| Event lacks canonical `event_id` | Both copies remain processable for compatibility; no content-based deduplication is invented. |
| One device takes Local route while another remains remote | Client publishes the complete replace-set interest snapshot, Cloud Socket stays connected, and remote-device routing remains available. |
| Agent registration advertises delivery presence | Runtime `capabilities` remains an object accepted by the Backend schema; `delivery_presence_v1` is negotiated separately in `transport_capabilities`. |

## Security and privacy checks

- Presence assertions remain opaque and never appear in logs or UI state.
- Client instance ids and recipient ids do not appear in Agent metrics/logs.
- Local hello grants no command authority and is accepted only after Local
  Gateway upgrade authentication.
- A failed control-plane update cannot terminate Local delivery or the daemon
  event loop.
- Deduplication uses only canonical `event_id`, never content, timestamps, or
  run ids.
- Debug diagnostics retain bounded event/transport names only. They redact
  Client instance ids, event ids, assertions, origin projections, email/host
  metadata, and command/event content or payloads; Agent adapters never log
  complete protocol envelopes.
- Release review runs both daemon-backed boundaries sequentially with isolated
  Sanad Homes and ports: the Agent Gateway platform E2E and the Client dual-
  connection E2E. Provider fixtures used by the latter must select an auth
  method supported by the authoritative provider template.
