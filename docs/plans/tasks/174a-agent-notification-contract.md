# 174a — Agent notification contract and delivery policy

**Status:** not started — G0 open
**Owners:** `agent/lib/interfaces/platforms/sanad_gateway/protocol/`, new Agent notification module, `docs/technical/communication_protocols.md`
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Contract:** [docs/technical/communication_protocols.md](../../technical/communication_protocols.md)

## Goal

Make the Agent the single owner of notification decisions: decide which session
events notify, render and redact the copy, name the target Client, run the
escalation timer, and cancel it on resolution, so that the hosted relay only has
to move an opaque payload to a named target.

## Locked decisions and scope

1. Notification kinds, urgency, and copy are Agent-owned; the relay receives
   finished text and a target.
2. Redaction and truncation happen before dispatch, using the existing secret
   redaction path rather than a second implementation.
3. Escalation is time-based at 90 seconds and is cancelled only by resolution or
   a terminal session state.
4. Immediate fan-out replaces the timer when the origin Client instance is
   unreachable or the turn originated from a surface that cannot be notified.
5. Every kind defaults to high urgency; no kind is silent by default.
6. Copy covers the Agent kinds and the action labels; the Client registers its
   locale and the Agent never translates a session title.
7. `connection_lost` and `auth_required` are Client-owned and out of this task.
8. The payload is additive to the existing canonical envelope; no existing
   `device_event` field changes meaning.

## Gates

### G0 — Discovery

- [ ] Inventory every Agent event that can leave a session waiting on a human,
      with its emitting module and its existing envelope fields.
- [ ] Confirm how the originating Client instance is identified on both routes
      (local membership and cloud recipient set) and what the Agent can know
      about a target that is currently offline.
- [ ] Confirm the existing redaction entry point and its guarantees.
- [ ] Confirm the Client registration payload has no locale field today.
- [ ] Confirm no notification policy, template table, or timer exists in the
      Agent, and that task 174 is unclaimed in open pull requests.

### G1 — Notification model and copy

- [ ] Define the Agent-owned kinds and their default urgency as one model.
- [ ] Add a template table covering kinds and action labels for `en` and `ar`,
      and nothing else.
- [ ] Add a parity test that fails when the Agent template keys and the Client
      localization keys disagree.
- [ ] Register the Client locale at connection time and use it for copy, with a
      defined fallback when it is absent.

### G2 — Policy and timers

- [ ] Resolve the origin Client instance from the existing delivery envelope.
- [ ] Implement origin-first dispatch, the 90-second escalation timer keyed by
      `session_id + request_id`, and fan-out on expiry.
- [ ] Cancel on resolution and on terminal session state, and withdraw the
      notification from every device that received it.
- [ ] Implement the immediate fan-out rule for an unreachable origin and for
      non-notifiable origins such as the CLI and scheduled runs.
- [ ] Guarantee one timer per ask, and no notification after resolution.

### G3 — Payload and redaction

- [ ] Compose `title`, `body`, action labels, `deep_link`, `collapse_key`,
      `expires_at`, and platform hints.
- [ ] Route every text field through the existing redaction path and enforce a
      bounded length.
- [ ] Prove that no transcript, command text, credential, or tool output enters
      the payload beyond the redacted ask itself.

### G4 — Wire contract and documentation

- [ ] Emit the dispatch instruction with a protocol version and an additive
      field name that does not collide with existing events.
- [ ] Update `docs/technical/communication_protocols.md` with the notification
      section, the target semantics, and the relay's content-blind obligation.
- [ ] Record the local-only limitation: no relay path means no cross-device
      notification.

### G5 — Verification

- [ ] Unit tests for the policy matrix: origin reachable, origin unreachable,
      origin not notifiable, resolved before expiry, resolved after fan-out.
- [ ] Fake-clock tests for the timer, including cancellation and idempotence.
- [ ] Redaction and length tests.
- [ ] Template parity test against the Client localization keys.

## Acceptance Criteria

- [ ] Given an ask resolved 10 seconds after dispatch, when the 90-second timer
      would fire, then no fan-out occurs and the ask is withdrawn everywhere.
- [ ] Given an unresolved ask and a reachable origin, when 90 seconds pass, then
      every push-capable device of the account receives one dispatch.
- [ ] Given an ask originating from the standalone CLI, when it is created, then
      fan-out happens immediately with no timer.
- [ ] Given a payload containing a secret-bearing command, when it is composed,
      then the secret is absent from every text field.
- [ ] Given a Client locale of `ar`, when a permission request is dispatched,
      then the copy is Arabic and the session title is unchanged.

## Definition of Done

- [ ] `fvm dart analyze` passes in `agent/`.
- [ ] Focused Agent tests pass, bounded to the notification module and parity.
- [ ] `docs/technical/communication_protocols.md` describes the contract.
- [ ] Graph index refreshed with `graphify update .`.
- [ ] No change to existing event meanings; the diff is additive.
