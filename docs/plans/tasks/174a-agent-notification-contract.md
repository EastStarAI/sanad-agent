# 174a — Agent notification contract and delivery policy

**Status:** implemented — G0–G5 closed on `task/174a-agent-contract`; awaiting review
**Owners:** `agent/lib/interfaces/notifications/`, `agent/lib/interfaces/runtime/`, `docs/technical/communication_protocols.md`
**Plan:** [174](../174-client-notifications-and-push-delivery.md)
**Contract:** [docs/technical/communication_protocols.md](../../technical/communication_protocols.md) §7

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

- [x] Inventory every Agent event that can leave a session waiting on a human,
      with its emitting module and its existing envelope fields.
- [x] Confirm how the originating Client instance is identified on both routes
      (local membership and cloud recipient set) and what the Agent can know
      about a target that is currently offline.
- [x] Confirm the existing redaction entry point and its guarantees.
- [x] Confirm the Client registration payload has no locale field today.
- [x] Confirm no notification policy, template table, or timer exists in the
      Agent, and that task 174 is unclaimed in open pull requests.

**Inventory of human-blocking Agent events (G0.1)**

| Event | Emitting module | Existing envelope | Blocks on a human |
|---|---|---|---|
| `tool_permission_request` (ordinary tool approval) | `PlatformRuntimeBridge.requestToolPermission` ← `PermissionManager` | canonical envelope; `delivery = platform_family(sanad_client)` for a Sanad Client origin, `origin`-scoped otherwise; payload `request_id`, `tool_name`, `tool_input`, `workspace_*`, `approval_key`, `tool` | yes — allow/deny decision |
| `tool_permission_request` (`system_ask_user`) | same bridge ← `InteractiveUserInput` ← `ask_user_tool` | same; payload `request_id`, `tool_name`, `questions[]` | yes — free-text answer |
| `tool_permission_request` (`system_request_secret`) | same bridge ← `InteractiveUserInput` ← `secret_tools` | same; payload `request_id`, `tool_name`, `reason`, `fields[]`, `replaces[]` | yes — secret form |
| `tool_permission_resolved` | same bridge, `outcome = resolved \| already_resolved` | same envelope; payload `session_id`, `request_id`, `outcome` | no — it ends the wait |
| `session.runtime_notice` (`waiting`/`blocked`/`fatal`) | `RuntimeRecoveryService` → `GatewayManager._onRuntimeNotice` | canonical envelope; payload status, counters, retry budget | partly — recovery state, but it carries **no** human-response identity, so it cannot be cancelled by a resolution and is out of this task |
| `session.execution_state_changed` (`waiting`/`blocked`) | durable execution-state projection → `GatewayManager._onExecutionStateChanged` | canonical envelope; payload `session_id`, `state`, `revision` | no — a projection, used here as the terminal-state signal |
| `final_answer` / failed terminal notice | runner and recovery paths | canonical envelope | no — terminal result, not a suspension |

The three suspension rows are the ask this task notifies about. The terminal
kinds (`completed`, `failed`, `background_task_done`, `scheduled_result`,
`provider_quota`) are in the model and the copy table, and no emitter is wired
to them here: nothing in this task's gates requires dispatching a finished run,
and wiring completion notifications without a user preference would notify on
every turn.

**Origin identity (G0.2)** The canonical delivery envelope names the *platform
instance* (`origin.platform_instance_id = local-daemon` locally, the cloud
adapter's id remotely), not the Client instance. The Client instance identity
already exists on both routes: the local adapter binds the authenticated
`client.hello` `client_instance_id` per socket, and the Gateway publishes the
cloud recipient set as bounded `cloud_recipient_instance_ids` with a revision and
a lease (`DeliveryPresenceController`). The cloud command envelope also carries a
Gateway-authored `origin_client.client_instance_id`, which was only used for log
tags. Capture is therefore additive: `OriginContext.clientInstanceId` is filled
from `origin_client` (cloud) or the instance id the local adapter stamps on the
command envelope, and it is deliberately not serialized. For an offline target
the Agent knows only that it is in neither set; tokens and the device inventory
stay in the hosted service.

**Redaction (G0.3)** `agent/lib/core/secrets_redactor.dart` → `SecretsRedactor`
is the single owner of secret scrubbing for runtime notices and logs. It
recognizes key prefixes (`sk-`, `nvapi-`, …), `Bearer` tokens, `x-api-key` and
`Authorization` headers, assignments (`token = …`), and JSON credential fields,
and its own contract says it redacts a span rather than leak it. It is reused
unchanged; no second implementation exists.

**Locale (G0.4)** The local `client.hello` carries `protocol`, `version`,
`client_instance_id`, `capabilities`, and `metadata` = `ClientDisplayMetadata`
(`client_kind`, `platform_family`, `os_family`, `browser_family`, `app_version`).
The cloud `app_authenticate` carries the same metadata. Neither has a locale
field today.

**Absence of prior art (G0.5)** `agent/lib` has no notification kind, template
table, escalation timer, or dispatch policy (only unrelated `notification`-shaped
identifiers in process-tree and thinking-selection code). Pull request #430 on
`feat/174-notifications` is the docs-only plan; no implementation is claimed and
`174a` was unstarted.

### G1 — Notification model and copy

- [x] Define the Agent-owned kinds and their default urgency as one model.
- [x] Add a template table covering kinds and action labels for `en` and `ar`,
      and nothing else.
- [x] Add a parity test that fails when the Agent template keys and the Client
      localization keys disagree.
- [x] Register the Client locale at connection time and use it for copy, with a
      defined fallback when it is absent.

**Evidence:** `agent/lib/interfaces/notifications/notification_kind.dart` (typed
kind value object, eight Agent kinds, two declared Client-owned kinds, every kind
`defaultUrgency == high`), `notification_copy.dart` (one template per kind — 8 titles and
8 bodies — plus 5 action labels, each in `en` and `ar`, and the 21-key parity
surface), `client_instance_profiles.dart`
(locale + notifiability registry with the `en` fallback),
`notification_copy_parity_test.dart`, `client_instance_profiles_test.dart`, and
`local_gateway_transport_test.dart` ("an authenticated hello registers the
notification locale and capability", which proves registration and release at the
real socket boundary).

### G2 — Policy and timers

- [x] Resolve the origin Client instance from the existing delivery envelope.
- [x] Implement origin-first dispatch, the 90-second escalation timer keyed by
      `session_id + request_id`, and fan-out on expiry.
- [x] Cancel on resolution and on terminal session state, and withdraw the
      notification from every device that received it.
- [x] Implement the immediate fan-out rule for an unreachable origin and for
      non-notifiable origins such as the CLI and scheduled runs.
- [x] Guarantee one timer per ask, and no notification after resolution.

**Evidence:** `notification_policy.dart` and `notification_dispatcher.dart`, plus
`notification_policy_test.dart` (7-case matrix), `notification_dispatcher_test.dart`
(18 cases: timers, idempotence, cancellation, terminal state, dispose),
`notification_origin_capture_test.dart`, and
`platform_runtime_bridge_notification_test.dart`.

### G3 — Payload and redaction

- [x] Compose `title`, `body`, action labels, `deep_link`, `collapse_key`,
      `expires_at`, and platform hints.
- [x] Route every text field through the existing redaction path and enforce a
      bounded length.
- [x] Prove that no transcript, command text, credential, or tool output enters
      the payload beyond the redacted ask itself.

**Evidence:** `notification_payload.dart` (single composer; `SecretsRedactor`
then bounds 120/280/32), `notification_ask.dart` (the only reader of a suspension
payload; selects the tool name, the permission command, and the question or form
reason only), and `notification_payload_test.dart` (10 cases, including a
payload full of transcript/tool-output/schema/path/credential noise that must not
appear).

### G4 — Wire contract and documentation

- [x] Emit the dispatch instruction with a protocol version and an additive
      field name that does not collide with existing events.
- [x] Update `docs/technical/communication_protocols.md` with the notification
      section, the target semantics, and the relay's content-blind obligation.
- [x] Record the local-only limitation: no relay path means no cross-device
      notification.

**Evidence:** `CanonicalEventTypes.notificationDispatch` /
`notificationWithdraw` (`notification.dispatch` / `notification.withdraw`),
`NotificationWire.protocol = sanad.notification` + `version = 1`, and
`docs/technical/communication_protocols.md` §7 (§7.6 relay obligations, §7.8
local-only limitation).

### G5 — Verification

- [x] Unit tests for the policy matrix: origin reachable, origin unreachable,
      origin not notifiable, resolved before expiry, resolved after fan-out.
- [x] Fake-clock tests for the timer, including cancellation and idempotence.
- [x] Redaction and length tests.
- [x] Template parity test against the Client localization keys.

## Acceptance Criteria

- [x] Given an ask resolved 10 seconds after dispatch, when the 90-second timer
      would fire, then no fan-out occurs and the ask is withdrawn everywhere.
      (`notification_dispatcher_test.dart` — "resolution 10 seconds in prevents
      the fan-out and withdraws"; the withdrawal is account-scoped, which covers
      the origin and every device a step reached.)
- [x] Given an unresolved ask and a reachable origin, when 90 seconds pass, then
      every push-capable device of the account receives one dispatch.
      (`notification_dispatcher_test.dart` — "the 90-second expiry fans out to
      the account exactly once".)
- [x] Given an ask originating from the standalone CLI, when it is created, then
      fan-out happens immediately with no timer.
      (`notification_policy_test.dart`, `notification_dispatcher_test.dart`,
      and the bridge-level "a CLI-originated ask fans out immediately with no
      timer".)
- [x] Given a payload containing a secret-bearing command, when it is composed,
      then the secret is absent from every text field.
      (`notification_payload_test.dart` — redaction group.)
- [x] Given a Client locale of `ar`, when a permission request is dispatched,
      then the copy is Arabic and the session title is unchanged.
      (`notification_dispatcher_test.dart` — "a registered Arabic locale renders
      Arabic with the title untouched".)

## Definition of Done

- [x] `fvm dart analyze` passes in `agent/`.
- [x] Focused Agent tests pass, bounded to the notification module and parity.
- [x] `docs/technical/communication_protocols.md` describes the contract.
- [ ] Graph index refreshed with `graphify update .` — blocked in this
      execution environment: the `graphify` CLI is not installed on the host
      (`python3 -c "import graphify"` fails, no `graphify` binary on `PATH`)
      and the worktree has no `graphify-out/`. No graph artifact was produced
      or committed, and the reviewer may run it where the tool is installed.
- [x] No change to existing event meanings; the diff is additive.

## Verification record

Run from `agent/` with the FVM-managed SDK:

| Command | Result |
|---|---|
| `fvm dart analyze` | `No issues found!` |
| `fvm dart test test/interfaces/notifications test/interfaces/notification_origin_capture_test.dart` | `+69: All tests passed!` |
| `fvm dart test test/interfaces/platforms/sanad_gateway/local_gateway_transport_test.dart` | `+25: All tests passed!` |
| `fvm dart test test/interfaces test/guards test/capabilities/permission_manager_test.dart` | `+1028 ~1 -1`; the single failure is `test/interfaces/local_workspace_runtime_service_test.dart` → `PathAccessException: Directory listing failed, path = '/' (OS Error: Permission denied, errno = 13)` |
| `fvm dart test test/interfaces/local_workspace_runtime_service_test.dart --name "returns system roots when path is empty"` | reproduces alone; the sandbox denies listing `/`, and neither the test nor its subject is touched by this task |
| `fvm dart format --output=none --set-exit-if-changed lib/interfaces/notifications test/interfaces/notifications test/interfaces/notification_origin_capture_test.dart` | clean (new files formatted; the pre-existing non-canonical format of `gateway_manager.dart`, `platform_runtime_bridge.dart`, and `di.dart` was left untouched to avoid unrelated churn) |

## Decisions during implementation

1. **The origin Client instance is captured into `OriginContext` and is not
   serialized.** The canonical origin envelope does not name a Client instance
   today, and adding a wire field to every event would be a needless widening;
   the field is internal routing identity used only by the notification policy.
2. **Locale registration rides an optional `client.hello` field** (`locale`, and
   `notification_capable`), with `metadata.locale` also accepted. No Client
   change is required in this task; `174f` sends the field, and an absent value
   falls back to `en` — which is today's only possible state, so the Agent is
   correct before and after that Client task lands.
3. **Absence of a notifiability declaration means "can notify".** The opposite
   default would turn every first ask into an account-wide fan-out, because no
   Client declares the capability yet. An explicit `notification_capable: false`
   makes the "not push-capable origin" rule real and testable.
4. **`system_request_secret` is a `user_question`, not a `permission_request`.**
   The run is blocked on a user-provided form, and its user-authored `reason` is
   the only safe text; field names and values never enter the payload.
5. **Permission notifications may carry the command text, redacted.** The user
   must be able to judge the ask away from the app, and the acceptance criterion
   for a secret-bearing command presumes that text. Everything else in the
   suspension payload is dropped by construction, not by filtering.
6. **Withdrawal is account-scoped.** The Agent names targets, not tokens, so it
   cannot know which devices the relay reached; a device that never saw the
   notification identity drops the withdrawal. This satisfies "withdraw from
   every device that received it" without inventing a second inventory.
7. **Terminal session state means `idle` or `stopping`.** `blocked` and `waiting`
   are the states in which the ask is still live; cancelling there would withdraw
   the notification the user is meant to act on.
8. **Notification identity is the ask's canonical `event_id`; the instruction
   event keeps its own envelope `event_id`.** Escalation is a second canonical
   event, so dedupe on the envelope id would show two notifications for one ask.
9. **One locale per ask, resolved at creation and reused by every step.** A
   single instruction cannot be per-device localized; per-device locale selection
   belongs to the Client surface tasks.
10. **Expiry is 30 minutes and the Android channel and Apple category are
    per-kind.** A single high channel invites app-wide muting (plan risk), and a
    fixed expiry stops a late escalation from waking a device for a finished ask.
11. **`expires_at` is computed from composition, not from escalation.** The ask's
    lifetime is one deadline; an escalation only re-addresses it.

## Open items

- Terminal kinds (`completed`, `failed`, `background_task_done`,
  `scheduled_result`, `provider_quota`) are modeled and have copy, but no emitter
  is wired; see the G0 inventory for why this task's gates do not require it.
- The cloud route cannot register a locale yet (the Gateway authors
  `origin_client` and forwards no locale), so a cloud-originated ask renders in
  the fallback locale until `174e`/`174f`.
- Per-device locale, quiet hours, and digesting are out of scope of plan 174.
- `client/` is untouched: the 21 Client localization keys are recorded as
  expected-missing in the parity test and are authored by `174f`.
- A suspension restored from a durable checkpoint after a restart is **not**
  re-notified: `PlatformRuntimeBridge.requestToolPermission` is the only emitter
  of `tool_permission_request`, and startup recovery restores the pending
  decision without re-emitting it (the Client hydrates it from the session
  payload). Notifying a restored ask needs a startup hook that this task's gates
  do not name; it should be claimed before the desktop/mobile tasks ship.
- The origin-first step names one Client instance, but the delivery scope is
  still `platform_family`. Until the relay honors `target` (`174e`) and each
  Client ignores an instruction that does not name it (`174b`/`174f`), a second
  Client on the same route can see an origin-targeted instruction.
